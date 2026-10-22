package com.illixion.convolution

import android.content.Intent
import android.os.Bundle
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.delay
import metavr.view.SurfaceControlExt
import metavr.view.SurfaceViewExt
import metavrx.os.MetaVrOsSdkVersion
import org.json.JSONObject

/** Kept behind the version guard so OS classes are never loaded on older Horizon. */
object WindowStereo {
    fun supported() = MetaVrOsSdkVersion.isAtOrAbove(207)
    fun apply(view: SurfaceView, packing: Int) {
        if (!supported()) return
        SurfaceViewExt.setStereoComposition(view, when (packing) {
            1, 2 -> SurfaceControlExt.STEREO_COMPOSITION_SIDE_BY_SIDE
            3, 4 -> SurfaceControlExt.STEREO_COMPOSITION_TOP_BOTTOM
            else -> SurfaceControlExt.STEREO_COMPOSITION_MONO
        })
    }
}

/** The speeds every Convolution player offers (the Apple players' list). */
val PLAYBACK_SPEEDS = listOf(0.5f, 0.75f, 1f, 1.25f, 1.5f, 1.75f, 2f)

/** "1×", "1.25×", "0.5×". */
fun speedLabel(speed: Float): String = (if (speed % 1f == 0f) speed.toInt().toString() else speed.toString()) + "×"

@Composable
fun PlayerControls(session: PlaybackSession, spatial: Boolean, switchMode: () -> Unit, leave: () -> Unit) {
    var position by remember { mutableDoubleStateOf(session.position()) }
    var duration by remember { mutableDoubleStateOf(session.duration()) }
    var paused by remember { mutableStateOf(session.paused()) }
    var scrub by remember { mutableStateOf<Float?>(null) }
    var skip by remember { mutableStateOf<org.json.JSONObject?>(session.skipSuggestion()) }
    var speed by remember { mutableFloatStateOf(session.speed()) }
    var choosingSpeed by remember { mutableStateOf(false) }
    LaunchedEffect(session) {
        while (true) { position = session.position(); duration = session.duration(); paused = session.paused(); skip=session.skipSuggestion(); speed = session.speed(); delay(200) }
    }
    Surface(color = MaterialTheme.colorScheme.surface, shape = MaterialTheme.shapes.large) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(session.title(), style = MaterialTheme.typography.titleLarge)
            if (duration > 0) Slider(
                value = scrub ?: position.toFloat().coerceIn(0f,duration.toFloat()),
                onValueChange = { scrub = it }, valueRange = 0f..duration.toFloat(),
                onValueChangeFinished = { scrub?.let { session.seekTo(it.toDouble()) }; scrub = null })
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                Button(onClick = { session.seekVideo(-10) }) { Text("−10s") }
                Button(onClick = { session.toggleVideo() }) { Text(if (paused) "Play" else "Pause") }
                Button(onClick = { session.seekVideo(10) }) { Text("+10s") }
                skip?.let { suggestion -> Button(onClick={session.skipSegment()}) {Text(suggestion.optString("title","Skip segment"))} }
                Box {
                    OutlinedButton(onClick = { choosingSpeed = true }) { Text(speedLabel(speed)) }
                    DropdownMenu(expanded = choosingSpeed, onDismissRequest = { choosingSpeed = false }) {
                        PLAYBACK_SPEEDS.forEach { choice ->
                            DropdownMenuItem(
                                text = { Text(if (choice == 1f) "Normal (1×)" else speedLabel(choice)) },
                                leadingIcon = { if (choice == speed) Text("✓") },
                                onClick = { choosingSpeed = false; session.setSpeed(choice); speed = choice })
                        }
                    }
                }
                OutlinedButton(onClick = switchMode, enabled = !spatial || session.packing() == 0 || WindowStereo.supported()) { Text(if (spatial) "Window" else "Spatial view") }
                OutlinedButton(onClick = leave) { Text("Library") }
            }
            Text("${position.toInt()/60}:${(position.toInt()%60).toString().padStart(2,'0')} / ${duration.toInt()/60}:${(duration.toInt()%60).toString().padStart(2,'0')}")
        }
    }
}

class HomePlayerActivity : ComponentActivity(), PlaybackSession.Host {
    private lateinit var session: PlaybackSession
    private var surface: SurfaceView? = null
    private var aspect by mutableFloatStateOf(16f/9f)
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val plan = intent.getStringExtra("plan")
        val existing = if (plan == null) PlaybackSession.current() else PlaybackSession.open(this,JSONObject(plan))
        if (existing == null) { finish(); return }; session = existing
        // Older systems can still browse in Home; stereo falls back to the spatial presentation.
        if (session.packing() != 0 && !WindowStereo.supported()) { switchToSpatial(); return }
        setContent {
            MaterialTheme {
                Column(Modifier.fillMaxSize().padding(12.dp)) {
                    Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                      Box(Modifier.aspectRatio(aspect)) {
                        AndroidView(modifier = Modifier.fillMaxSize(), factory = { context ->
                            SurfaceView(context).also { view ->
                                surface = view; WindowStereo.apply(view,session.packing())
                                view.holder.setFixedSize(session.videoWidth(),session.videoHeight())
                                view.holder.addCallback(object : SurfaceHolder.Callback {
                                    override fun surfaceCreated(holder: SurfaceHolder) {
                                        session.attach(this@HomePlayerActivity,holder.surface,null); session.resumeVideo()
                                        android.util.Log.i("ConvolutionPanels","home_surface_ready stereo="+(session.packing()!=0))
                                    }
                                    override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) { }
                                    override fun surfaceDestroyed(holder: SurfaceHolder) { session.detach(this@HomePlayerActivity) }
                                })
                            }
                        })
                        var caption by remember { mutableStateOf("") }; var top by remember { mutableStateOf("") }
                        LaunchedEffect(session) { while (true) { caption = session.bottomCaption(); top = session.topCaption(); delay(50) } }
                        if (caption.isNotEmpty()) Surface(Modifier.align(Alignment.BottomCenter).padding(24.dp), color = MaterialTheme.colorScheme.surface.copy(alpha=.85f)) { Text(caption,Modifier.padding(8.dp),style=MaterialTheme.typography.titleLarge) }
                        if (top.isNotEmpty()) Surface(Modifier.align(Alignment.TopCenter).padding(24.dp), color = MaterialTheme.colorScheme.surface.copy(alpha=.85f)) { Text(top,Modifier.padding(8.dp),style=MaterialTheme.typography.titleLarge) }
                      }
                    }
                    PlayerControls(session,false,::switchToSpatial) { session.detach(this@HomePlayerActivity); finish() }
                }
            }
        }
    }
    private fun switchToSpatial() {
        session.detach(this)
        startActivity(Intent(this,SpatialPlayerActivity::class.java).setAction(Intent.ACTION_MAIN).addCategory("com.oculus.intent.category.VR"))
        finish()
    }
    override fun picture(aspect: Float, layout: Int, ready: Boolean, width: Int, height: Int) { this.aspect = aspect }
    override fun failed() { finish() }
    override fun onPause() { if (::session.isInitialized) session.detach(this); super.onPause() }
    override fun onResume() {
        super.onResume()
        if (::session.isInitialized) surface?.holder?.takeIf { it.surface.isValid }?.let { session.attach(this,it.surface,null); session.resumeVideo() }
    }
    override fun onDestroy() { if (::session.isInitialized) session.detach(this); super.onDestroy() }
}
