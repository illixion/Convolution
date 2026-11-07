package com.illixion.convolution

import android.content.Context
import android.opengl.GLES30
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * AI 3D's depth-displaced mesh warp on GLES (assets/smooth-motion/depth_warp.*,
 * the port of Vergence's Metal `StereoMeshWarp` and `videoStereoMesh*`): one
 * eye of a 2D frame from an `ai-3d-depth` map, nearer geometry occluding
 * farther under the depth test, uncovered strips filled from beside them.
 *
 * Not wired into playback yet: the Quest port has no AI 3D presentation (the
 * roadmap's step 6 holds 2D-to-3D), so nothing asks the coordinator for
 * `ai-3d-depth` today. When it does, a 2D title's SBS output is two
 * [drawEye] calls, left half then right, into a target with a depth buffer,
 * shown through the same stereo composition packed titles use. Create and
 * use on a GL thread with a current ES 3 context.
 */
class DepthWarpPass(context: Context) {
    /** Vergence's defaults: Convolution's Subtle strength and convergence, the studio budget. */
    var depthStrength = 0.008f
    var convergence = 1.0f
    var budgetLow = 0.08f
    var budgetHigh = 0.7f
    var edgeFill = true

    private val program: Int
    private val locations = HashMap<String, Int>()
    private val indexBuffer: Int
    private val vertexArray: Int
    private val indexCount: Int
    private val depthTexture: Int
    private var depthSize = 0 to 0

    init {
        program = SmoothMotionRenderer.buildProgram(context, "depth_warp.vert", "depth_warp.frag")
            ?: throw IllegalStateException("the depth warp didn't compile")
        val indices = meshGridIndices(COLUMNS, ROWS)
        indexCount = indices.size
        val names = IntArray(1)
        GLES30.glGenVertexArrays(1, names, 0); vertexArray = names[0]
        GLES30.glBindVertexArray(vertexArray)
        GLES30.glGenBuffers(1, names, 0); indexBuffer = names[0]
        GLES30.glBindBuffer(GLES30.GL_ELEMENT_ARRAY_BUFFER, indexBuffer)
        val data = ByteBuffer.allocateDirect(indices.size * 4).order(ByteOrder.nativeOrder()).asIntBuffer().put(indices).rewind()
        GLES30.glBufferData(GLES30.GL_ELEMENT_ARRAY_BUFFER, indices.size * 4, data, GLES30.GL_STATIC_DRAW)
        GLES30.glBindVertexArray(0)
        GLES30.glGenTextures(1, names, 0); depthTexture = names[0]
    }

    private fun at(name: String) = locations.getOrPut(name) { GLES30.glGetUniformLocation(program, name) }

    /** Uploads a frame's depth map (the track's bytes as they are). */
    fun setDepth(depth: AnalysisTrackStream.Depth) {
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, depthTexture)
        GLES30.glPixelStorei(GLES30.GL_UNPACK_ALIGNMENT, 1)
        if (depthSize != depth.width to depth.height) {
            GLES30.glTexImage2D(GLES30.GL_TEXTURE_2D, 0, GLES30.GL_R8, depth.width, depth.height, 0, GLES30.GL_RED, GLES30.GL_UNSIGNED_BYTE, null)
            for ((parameter, value) in listOf(GLES30.GL_TEXTURE_MIN_FILTER to GLES30.GL_LINEAR, GLES30.GL_TEXTURE_MAG_FILTER to GLES30.GL_LINEAR,
                    GLES30.GL_TEXTURE_WRAP_S to GLES30.GL_CLAMP_TO_EDGE, GLES30.GL_TEXTURE_WRAP_T to GLES30.GL_CLAMP_TO_EDGE)) {
                GLES30.glTexParameteri(GLES30.GL_TEXTURE_2D, parameter, value)
            }
            depthSize = depth.width to depth.height
        }
        GLES30.glTexSubImage2D(GLES30.GL_TEXTURE_2D, 0, 0, 0, depth.width, depth.height, GLES30.GL_RED, GLES30.GL_UNSIGNED_BYTE, depth.bytes)
        GLES30.glPixelStorei(GLES30.GL_UNPACK_ALIGNMENT, 4)
        valueScale = depth.scale * 255f
        valueBias = depth.offset
    }
    private var valueScale = 1f
    private var valueBias = 0f

    /**
     * Draws one eye of [frame] (an upright RGBA texture) into the bound
     * framebuffer's viewport ([x], [y], [width], [height]), which must have a
     * depth attachment; the caller clears colour and depth first.
     */
    fun drawEye(frame: Int, left: Boolean, x: Int, y: Int, width: Int, height: Int) {
        GLES30.glViewport(x, y, width, height)
        GLES30.glEnable(GLES30.GL_DEPTH_TEST)
        GLES30.glDepthFunc(GLES30.GL_LESS)
        GLES30.glUseProgram(program)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, frame)
        GLES30.glUniform1i(at("frame"), 0)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE1)
        GLES30.glBindTexture(GLES30.GL_TEXTURE_2D, depthTexture)
        GLES30.glUniform1i(at("depthMap"), 1)
        GLES30.glUniform2f(at("gridSize"), COLUMNS.toFloat(), ROWS.toFloat())
        GLES30.glUniform1f(at("depthStrength"), depthStrength)
        GLES30.glUniform1f(at("convergence"), convergence)
        GLES30.glUniform1f(at("eyeSign"), if (left) 1f else -1f)
        GLES30.glUniform1f(at("depthValueScale"), valueScale)
        GLES30.glUniform1f(at("depthValueBias"), valueBias)
        GLES30.glUniform2f(at("depthBudget"), budgetLow, budgetHigh)
        GLES30.glUniform1f(at("edgeFill"), if (edgeFill) 1f else 0f)
        GLES30.glBindVertexArray(vertexArray)
        GLES30.glDrawElements(GLES30.GL_TRIANGLES, indexCount, GLES30.GL_UNSIGNED_INT, 0)
        GLES30.glBindVertexArray(0)
        GLES30.glDisable(GLES30.GL_DEPTH_TEST)
        GLES30.glActiveTexture(GLES30.GL_TEXTURE0)
    }

    fun release() {
        GLES30.glDeleteProgram(program)
        GLES30.glDeleteBuffers(1, intArrayOf(indexBuffer), 0)
        GLES30.glDeleteVertexArrays(1, intArrayOf(vertexArray), 0)
        GLES30.glDeleteTextures(1, intArrayOf(depthTexture), 0)
    }

    companion object {
        /** VergenceApple's dense grid, for edge-aware (track or cached) depth. */
        const val COLUMNS = 769
        const val ROWS = 433
    }
}
