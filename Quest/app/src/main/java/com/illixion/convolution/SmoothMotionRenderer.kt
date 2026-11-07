package com.illixion.convolution

import android.content.Context
import android.graphics.SurfaceTexture
import android.hardware.display.DisplayManager
import android.media.MediaFormat
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES30
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import android.view.Choreographer
import android.view.Display
import android.view.Surface
import androidx.media3.common.Format
import androidx.media3.exoplayer.video.VideoFrameMetadataListener
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

private const val TAG = "ConvolutionSmooth"

/**
 * Smooth Motion for 3D Library titles on Quest: the decoder writes into a
 * SurfaceTexture here instead of straight into the presentation's surface,
 * and this GLES thread draws that surface at the display's rate, with
 * in-between frames made by the shared-field pass (assets/smooth-motion/
 * shared_field.frag, the port of Vergence's Metal `SharedFieldInterpolator`)
 * from the fields an analysis coordinator prepared. No network runs here;
 * where a pair has no fields yet the real frames show as they are.
 *
 * Timing: Media3 releases each frame to a SurfaceTexture up to 50 ms before
 * its display time, stamped with that time ([SurfaceTexture.getTimestamp] is
 * the release time it gives MediaCodec), and tells [onVideoFrameAboutToBeRendered]
 * the frame's media time first. So at 24 fps the next real frame is usually
 * here before the current one's interval starts, and every display refresh
 * between them gets the frame at its own fraction t.
 *
 * GLES 3.0, not Vulkan: the passes are a few texture reads per pixel, the
 * surfaces are Android ones (Home's SurfaceView, Spatial SDK's video panel),
 * and EGL renders into either directly. See question 6 in
 * docs/plans/analysis-workers.md.
 */
class SmoothMotionRenderer private constructor(
    private val context: Context,
    private val output: Surface,
    private val packing: Int,
) : VideoFrameMetadataListener {
    /** Where the decoder writes. Valid once [create] returned this renderer. */
    lateinit var input: Surface
        private set
    @Volatile var track: AnalysisTrackStream? = null

    private val thread = HandlerThread("smooth-motion").apply { start() }
    private val handler = Handler(thread.looper)
    private var display: EGLDisplay = EGL14.EGL_NO_DISPLAY
    private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
    private var window: EGLSurface = EGL14.EGL_NO_SURFACE
    private lateinit var surfaceTexture: SurfaceTexture
    private var oesTexture = 0
    private var vertexArray = 0
    private var width = 0
    private var height = 0
    private lateinit var copy: Program
    private lateinit var present: Program
    private lateinit var interpolate: Program
    private val fieldTextures = IntArray(4)  // flow, mask, disparity0, disparity1
    private var fieldPair: Pair<Long, Long>? = null
    private var missedPair: Pair<Long, Long>? = null
    private val transform = FloatArray(16)
    private var running = false
    private var vsyncNanos = 1_000_000_000L / 72

    private class Slot(val texture: Int, val framebuffer: Int) {
        var releaseNanos = Long.MIN_VALUE
        var mediaMicros = Long.MIN_VALUE
        var serial = 0L
    }
    private val slots = ArrayList<Slot>()
    private var serial = 0L
    /** Release time -> media time, from the metadata listener (playback thread). */
    private val mediaTimes = ConcurrentHashMap<Long, Long>()

    // What's on screen, to skip redrawing it.
    private var shownSerial = -1L
    private var shownT = -1f
    // Frame-time telemetry, logged every 5 s.
    private var statsSince = 0L
    private var interpolated = 0
    private var passedThrough = 0
    private var drawNanos = 0L
    private var gpuQuery = 0
    private var gpuQueryPending = false
    private var gpuNanos = 0L
    private var gpuSamples = 0
    private var timerQueries = false

    private class Program(val id: Int) {
        private val locations = HashMap<String, Int>()
        fun at(name: String) = locations.getOrPut(name) { GLES30.glGetUniformLocation(id, name) }
    }

    // MARK: Media3

    override fun onVideoFrameAboutToBeRendered(presentationTimeUs: Long, releaseTimeNs: Long, format: Format, mediaFormat: MediaFormat?) {
        mediaTimes[releaseTimeNs] = presentationTimeUs
        if (mediaTimes.size > 64) {
            val cutoff = releaseTimeNs - 2_000_000_000L
            mediaTimes.keys.removeAll { it < cutoff }
        }
    }

    // MARK: GL thread

    private fun setUp(): Boolean {
        display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
        val version = IntArray(2)
        if (!EGL14.eglInitialize(display, version, 0, version, 1)) return false
        val configs = arrayOfNulls<EGLConfig>(1)
        val count = IntArray(1)
        val attributes = intArrayOf(
            EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8, EGL14.EGL_ALPHA_SIZE, 8,
            EGL14.EGL_RENDERABLE_TYPE, 0x40 /* EGL_OPENGL_ES3_BIT_KHR */, EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT,
            EGL14.EGL_NONE)
        if (!EGL14.eglChooseConfig(display, attributes, 0, configs, 0, 1, count, 0) || count[0] == 0) return false
        eglContext = EGL14.eglCreateContext(display, configs[0], EGL14.EGL_NO_CONTEXT,
            intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE), 0)
        if (eglContext == EGL14.EGL_NO_CONTEXT) return false
        window = EGL14.eglCreateWindowSurface(display, configs[0], output, intArrayOf(EGL14.EGL_NONE), 0)
        if (window == EGL14.EGL_NO_SURFACE || !EGL14.eglMakeCurrent(display, window, window, eglContext)) return false
        // Never block the GL thread on the compositor: a refresh it misses just shows the last one.
        EGL14.eglSwapInterval(display, 0)
        val size = IntArray(1)
        EGL14.eglQuerySurface(display, window, EGL14.EGL_WIDTH, size, 0); width = size[0]
        EGL14.eglQuerySurface(display, window, EGL14.EGL_HEIGHT, size, 0); height = size[0]
        if (width <= 0 || height <= 0) return false

        copy = Program(program("fullscreen.vert", "copy_oes.frag") ?: return false)
        present = Program(program("fullscreen.vert", "present.frag") ?: return false)
        interpolate = Program(program("fullscreen.vert", "shared_field.frag") ?: return false)
        val names = IntArray(1)
        GLES30.glGenVertexArrays(1, names, 0); vertexArray = names[0]

        GLES30.glGenTextures(1, names, 0); oesTexture = names[0]
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTexture)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)

        // Four frames: the one showing, the next, and room for the decoder's early ones.
        repeat(4) {
            val texture = texture2D(GLES30.GL_RGBA8, width, height, GLES30.GL_RGBA, GLES30.GL_UNSIGNED_BYTE)
            GLES30.glGenFramebuffers(1, names, 0)
            GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, names[0])
            GLES30.glFramebufferTexture2D(GLES30.GL_FRAMEBUFFER, GLES30.GL_COLOR_ATTACHMENT0, GLES30.GL_TEXTURE_2D, texture, 0)
            if (GLES30.glCheckFramebufferStatus(GLES30.GL_FRAMEBUFFER) != GLES30.GL_FRAMEBUFFER_COMPLETE) return false
            slots.add(Slot(texture, names[0]))
        }
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
        GLES30.glGenTextures(4, fieldTextures, 0)

        timerQueries = GLES30.glGetString(GLES30.GL_EXTENSIONS)?.contains("GL_EXT_disjoint_timer_query") == true
        if (timerQueries) { GLES30.glGenQueries(1, names, 0); gpuQuery = names[0] }

        surfaceTexture = SurfaceTexture(oesTexture)
        surfaceTexture.setOnFrameAvailableListener({ frameArrived() }, handler)
        input = Surface(surfaceTexture)
        context.getSystemService(DisplayManager::class.java)?.getDisplay(Display.DEFAULT_DISPLAY)?.refreshRate
            ?.takeIf { it > 0 }?.let { vsyncNanos = (1e9 / it).toLong() }
        Log.i(TAG, "renderer_ready size=${width}x$height packing=$packing vsync_ms=${"%.2f".format(vsyncNanos / 1e6)} timer_queries=$timerQueries")
        return GLES30.glGetError() == GLES30.GL_NO_ERROR
    }

    private fun texture2D(internal: Int, w: Int, h: Int, format: Int, type: Int, name: Int = 0): Int {
        val texture = if (name != 0) name else IntArray(1).also { GLES30.glGenTextures(1, it, 0) }[0]
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, texture)
        GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, internal, w, h, 0, format, type, null)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MIN_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_MAG_FILTER, GLES30.GL_LINEAR)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_S, GLES30.GL_CLAMP_TO_EDGE)
        GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, GLES30.GL_TEXTURE_WRAP_T, GLES30.GL_CLAMP_TO_EDGE)
        return texture
    }

    private fun program(vertex: String, fragment: String): Int? {
        fun shader(type: Int, name: String): Int? {
            val source = context.assets.open("smooth-motion/$name").use { String(it.readBytes(), Charsets.UTF_8) }
            val id = GLES30.glCreateShader(type)
            GLES30.glShaderSource(id, source)
            GLES30.glCompileShader(id)
            val ok = IntArray(1)
            GLES30.glGetShaderiv(id, GLES30.GL_COMPILE_STATUS, ok, 0)
            if (ok[0] == 0) { Log.e(TAG, "shader_failed name=$name log=${GLES30.glGetShaderInfoLog(id)}"); return null }
            return id
        }
        val v = shader(GLES30.GL_VERTEX_SHADER, vertex) ?: return null
        val f = shader(GLES30.GL_FRAGMENT_SHADER, fragment) ?: return null
        val id = GLES30.glCreateProgram()
        GLES30.glAttachShader(id, v); GLES30.glAttachShader(id, f)
        GLES30.glLinkProgram(id)
        GLES30.glDeleteShader(v); GLES30.glDeleteShader(f)
        val ok = IntArray(1)
        GLES30.glGetProgramiv(id, GLES30.GL_LINK_STATUS, ok, 0)
        if (ok[0] == 0) { Log.e(TAG, "program_failed name=$fragment log=${GLES30.glGetProgramInfoLog(id)}"); return null }
        return id
    }

    /** A decoded frame is waiting: copy it into the oldest slot, keyed by its release and media times. */
    private fun frameArrived() {
        if (!running) return
        surfaceTexture.updateTexImage()
        surfaceTexture.getTransformMatrix(transform)
        val release = surfaceTexture.timestamp
        val slot = slots.minByOrNull { it.serial }!!
        slot.releaseNanos = release
        slot.mediaMicros = mediaTimes.remove(release) ?: Long.MIN_VALUE
        slot.serial = ++serial
        if (serial == 1L) {
            // Whether the decoder's timestamps matched Media3's frame times; without them no pair is ever looked up.
            Log.i(TAG, "first_frame media_time_known=${slot.mediaMicros != Long.MIN_VALUE} media_ms=${if (slot.mediaMicros == Long.MIN_VALUE) "n/a" else (slot.mediaMicros / 1000).toString()}" +
                " release_in_ms=${(release - System.nanoTime()) / 1_000_000}")
        }
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, slot.framebuffer)
        GLES30.glViewport(0, 0, width, height)
        GLES30.glUseProgram(copy.id)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTexture)
        GLES30.glUniform1i(copy.at("frame"), 0)
        GLES30.glUniformMatrix4fv(copy.at("textureTransform"), 1, false, transform, 0)
        GLES30.glBindVertexArray(vertexArray)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3)
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
        if (slot.mediaMicros != Long.MIN_VALUE) track?.noteDemand(slot.mediaMicros / 1e6)
    }

    private val frameCallback = object : Choreographer.FrameCallback {
        override fun doFrame(frameTimeNanos: Long) {
            if (!running) return
            // What this refresh shows lands on the next vsync.
            draw(frameTimeNanos + vsyncNanos)
            Choreographer.getInstance().postFrameCallback(this)
        }
    }

    private fun draw(displayNanos: Long) {
        val ordered = slots.filter { it.serial > 0 }.sortedBy { it.releaseNanos }
        val a = ordered.lastOrNull { it.releaseNanos <= displayNanos } ?: return
        val b = ordered.firstOrNull { it.releaseNanos > a.releaseNanos }
        var t = 0f
        val stream = track
        if (b != null && stream != null && a.mediaMicros != Long.MIN_VALUE && b.mediaMicros != Long.MIN_VALUE &&
            b.mediaMicros - a.mediaMicros in 1..100_000) {
            val at = ((displayNanos - a.releaseNanos).toDouble() / (b.releaseNanos - a.releaseNanos)).toFloat()
            // A refresh within a few percent of a real frame shows that frame.
            if (at > 0.04f && at < 0.96f) {
                val pair = a.mediaMicros to b.mediaMicros
                // Asked once per pair: a pair whose fields aren't here plays as real frames.
                if (fieldPair != pair && missedPair != pair) {
                    val fields = stream.fields(a.mediaMicros / 1e6, b.mediaMicros / 1e6)
                    if (fields != null) { upload(fields); fieldPair = pair } else missedPair = pair
                }
                if (fieldPair == pair) t = at
            }
        }
        if (a.serial == shownSerial && t == shownT) return
        val started = SystemClock.elapsedRealtimeNanos()
        GLES30.glBindFramebuffer(GLES30.GL_FRAMEBUFFER, 0)
        GLES30.glViewport(0, 0, width, height)
        GLES30.glBindVertexArray(vertexArray)
        if (t > 0f && b != null) {
            val query = timerQueries && !gpuQueryPending
            if (query) GLES30.glBeginQuery(0x88BF /* GL_TIME_ELAPSED_EXT */, gpuQuery)
            drawInterpolated(a, b, t)
            if (query) { GLES30.glEndQuery(0x88BF); gpuQueryPending = true }
            interpolated++
        } else {
            GLES30.glUseProgram(present.id)
            GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, a.texture)
            GLES30.glUniform1i(present.at("frame"), 0)
            GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3)
            passedThrough++
        }
        EGL14.eglSwapBuffers(display, window)
        shownSerial = a.serial; shownT = t
        drawNanos += SystemClock.elapsedRealtimeNanos() - started
        collectGpuTime()
        logStats()
    }

    private fun upload(fields: AnalysisTrackStream.Fields) {
        GLES30.glPixelStorei(GLES30.GL_UNPACK_ALIGNMENT, 2)
        texture2D(GLES30.GL_RGBA16F, fields.flowWidth, fields.flowHeight, GLES30.GL_RGBA, GLES30.GL_HALF_FLOAT, fieldTextures[0])
        GLES30.glTexSubImage2D(GLES30.GL_TEXTURE_2D, 0, 0, 0, fields.flowWidth, fields.flowHeight, GLES30.GL_RGBA, GLES30.GL_HALF_FLOAT, fields.flow)
        texture2D(GLES30.GL_R16F, fields.flowWidth, fields.flowHeight, GLES30.GL_RED, GLES30.GL_HALF_FLOAT, fieldTextures[1])
        GLES30.glTexSubImage2D(GLES30.GL_TEXTURE_2D, 0, 0, 0, fields.flowWidth, fields.flowHeight, GLES30.GL_RED, GLES30.GL_HALF_FLOAT, fields.mask)
        for ((i, values) in listOf(fields.disparity0, fields.disparity1).withIndex()) {
            texture2D(GLES30.GL_R16F, fields.disparityWidth, fields.disparityHeight, GLES30.GL_RED, GLES30.GL_HALF_FLOAT, fieldTextures[2 + i])
            GLES30.glTexSubImage2D(GLES30.GL_TEXTURE_2D, 0, 0, 0, fields.disparityWidth, fields.disparityHeight, GLES30.GL_RED, GLES30.GL_HALF_FLOAT, values)
        }
        GLES30.glPixelStorei(GLES30.GL_UNPACK_ALIGNMENT, 4)
        uploadedSizes = intArrayOf(fields.flowWidth, fields.flowHeight, fields.disparityWidth, fields.disparityHeight)
    }
    private var uploadedSizes = IntArray(4)

    private fun drawInterpolated(a: Slot, b: Slot, t: Float) {
        val p = interpolate
        GLES30.glUseProgram(p.id)
        val textures = intArrayOf(a.texture, b.texture, fieldTextures[0], fieldTextures[1], fieldTextures[2], fieldTextures[3])
        val names = arrayOf("previousFrame", "currentFrame", "flow", "mask", "disparity0", "disparity1")
        for (i in textures.indices) {
            GLES30.glActiveTexture(GLES30.GL_TEXTURE0 + i)
            GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, textures[i])
            GLES30.glUniform1i(p.at(names[i]), i)
        }
        val sideBySide = packing == 1 || packing == 2
        val eyeW = if (sideBySide) width / 2f else width.toFloat()
        val eyeH = if (sideBySide) height.toFloat() else height / 2f
        GLES30.glUniform2f(p.at("frameSize"), width.toFloat(), height.toFloat())
        GLES30.glUniform2f(p.at("eyeSize"), eyeW, eyeH)
        GLES30.glUniform2f(p.at("eyeOffset"), if (sideBySide) eyeW else 0f, if (sideBySide) 0f else eyeH)
        GLES30.glUniform2f(p.at("flowScale"), eyeW / uploadedSizes[0], eyeH / uploadedSizes[1])
        GLES30.glUniform1f(p.at("disparityScale"), eyeW / uploadedSizes[2])
        GLES30.glUniform1f(p.at("t"), t)
        GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
    }

    private fun collectGpuTime() {
        if (!gpuQueryPending) return
        val value = IntArray(1)
        GLES30.glGetQueryObjectuiv(gpuQuery, GLES30.GL_QUERY_RESULT_AVAILABLE, value, 0)
        if (value[0] == 0) return
        GLES30.glGetQueryObjectuiv(gpuQuery, GLES30.GL_QUERY_RESULT, value, 0)
        gpuQueryPending = false
        // GL_GPU_DISJOINT_EXT: a frequency change or preemption spoils the sample.
        val disjoint = IntArray(1)
        GLES30.glGetIntegerv(0x8FBB, disjoint, 0)
        if (disjoint[0] == 0) { gpuNanos += value[0].toLong() and 0xFFFFFFFFL; gpuSamples++ }
    }

    private fun logStats() {
        val now = SystemClock.elapsedRealtime()
        if (statsSince == 0L) statsSince = now
        if (now - statsSince < 5000) return
        val draws = interpolated + passedThrough
        // Code-defined counts and times only: nothing about the title.
        Log.i(TAG, "smooth_motion interpolated=$interpolated real=$passedThrough draw_cpu_ms=${"%.2f".format(if (draws > 0) drawNanos / 1e6 / draws else 0.0)}" +
            " pass_gpu_ms=${if (gpuSamples > 0) "%.2f".format(gpuNanos / 1e6 / gpuSamples) else "n/a"} over_s=${(now - statsSince) / 1000}")
        statsSince = now; interpolated = 0; passedThrough = 0; drawNanos = 0; gpuNanos = 0; gpuSamples = 0
    }

    private fun tearDown() {
        running = false
        Choreographer.getInstance().removeFrameCallback(frameCallback)
        if (::surfaceTexture.isInitialized) { surfaceTexture.setOnFrameAvailableListener(null); surfaceTexture.release() }
        if (::input.isInitialized) input.release()
        if (display != EGL14.EGL_NO_DISPLAY) {
            EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
            if (window != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, window)
            if (eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(display, eglContext)
            EGL14.eglReleaseThread()
        }
        window = EGL14.EGL_NO_SURFACE; eglContext = EGL14.EGL_NO_CONTEXT; display = EGL14.EGL_NO_DISPLAY
    }

    /** Stops drawing and lets go of the output surface; blocks until the GL thread has (at most 2 s). */
    fun release() {
        val done = CountDownLatch(1)
        handler.post { try { tearDown() } finally { done.countDown() } }
        done.await(2, TimeUnit.SECONDS)
        thread.quitSafely()
    }

    companion object {
        /**
         * A renderer drawing into [output] (packed stereo [packing], 1–4 as
         * PlaybackSession numbers it), or null if GLES couldn't be set up
         * there; the caller then gives the decoder [output] itself.
         */
        fun create(context: Context, output: Surface, packing: Int): SmoothMotionRenderer? {
            val renderer = SmoothMotionRenderer(context.applicationContext, output, packing)
            val ready = CountDownLatch(1)
            var ok = false
            renderer.handler.post {
                ok = try { renderer.setUp() } catch (e: Exception) { Log.e(TAG, "renderer_failed error=${e.javaClass.simpleName}"); false }
                if (ok) { renderer.running = true; Choreographer.getInstance().postFrameCallback(renderer.frameCallback) }
                else renderer.tearDown()
                ready.countDown()
            }
            if (!ready.await(3, TimeUnit.SECONDS) || !ok) {
                Log.w(TAG, "renderer_unavailable")
                renderer.release()
                return null
            }
            return renderer
        }
    }
}
