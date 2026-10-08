package com.illixion.convolution

import android.app.PendingIntent
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.view.Surface
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.meta.spatial.compose.ComposeFeature
import com.meta.spatial.compose.composePanel
import com.meta.spatial.core.*
import com.meta.spatial.isdk.IsdkGrabbable
import com.meta.spatial.isdk.IsdkPanelGrabHandle
import com.meta.spatial.isdk.IsdkPanelDimensions
import com.meta.spatial.isdk.createIsdkComponents
import com.meta.spatial.isdk.updateIsdkComponentProperties
import com.meta.spatial.runtime.ReferenceSpace
import com.meta.spatial.runtime.LayerConfig
import com.meta.spatial.runtime.StereoMode
import com.meta.spatial.toolkit.*
import com.meta.spatial.vr.VRFeature
import kotlinx.coroutines.delay

/** Passthrough viewing mode. This owns panel placement, never playback. */
class SpatialPlayerActivity : AppSystemActivity(), PlaybackSession.Host {
    private lateinit var playback: PlaybackSession
    private var videoEntity: Entity? = null
    private var decoderSurface: Surface? = null
    private var poseReported = false
    private var placed = false
    override fun registerFeatures(): List<SpatialFeature> = listOf(VRFeature(this),ComposeFeature())
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        val session = PlaybackSession.current()
        if (session == null) { finish(); return }; playback = session
    }
    override fun registerPanels(): List<PanelRegistration> {
        val session = PlaybackSession.current() ?: return emptyList()
        val aspect = packedAspect(session)
        return listOf(
            VideoSurfacePanelRegistration(R.id.quest_video,
                surfaceConsumer = { _, surface -> runOnUiThread {
                    decoderSurface = surface; session.attach(this,surface,null); session.resumeVideo()
                    Log.i("ConvolutionPanels","spatial_video_surface_ready")
                } },
                settingsCreator = {
                    MediaPanelSettings(
                        shape = QuadShapeOptions(2.4f,2.4f/aspect),
                        display = PixelDisplayOptions(session.videoWidth(),session.videoHeight()),
                        rendering = MediaPanelRenderOptions(stereoMode = when(session.packing()) {
                            1,2 -> StereoMode.LeftRight
                            3,4 -> StereoMode.UpDown
                            else -> StereoMode.None
                        }),
                        style = PanelStyleOptions(R.style.QuestPanelTransparent))
                },
                panelSetup = { panel, entity ->
                    // Bind interaction after the direct surface's SceneObject exists,
                    // so a component change before asynchronous creation is not lost.
                    entity.setComponent(Hittable())
                    panel.createIsdkComponents(entity)
                    panel.updateIsdkComponentProperties(entity)
                }),
            PanelRegistration(R.id.quest_controls) {
                config {
                    width = 1.6f; height = .432f
                    layoutWidthInDp = 1000f; layoutHeightInDp = 270f; layoutDpi = 320
                    layerConfig = LayerConfig(zIndex = 2)
                    includeGlass = false; themeResourceId = R.style.QuestPanelTransparent
                }
                composePanel { setContent { MaterialTheme {
                    PlayerControls(session,true,{ returnHome(false) },{ returnHome(true) })
                } } }
            },
            PanelRegistration(R.id.quest_captions) {
                config {
                    width = 2.39f; height = 2.39f/aspect
                    layoutWidthInDp = 1280f; layoutHeightInDp = 1280f/aspect; layoutDpi = 320
                    layerConfig = LayerConfig(zIndex = 1)
                    enableTransparent = true; includeGlass = false; themeResourceId = R.style.QuestPanelTransparent
                }
                composePanel { setContent {
                    var bottom by remember { mutableStateOf("") }; var top by remember { mutableStateOf("") }
                    LaunchedEffect(session) { while(true) { bottom=session.bottomCaption(); top=session.topCaption(); delay(50) } }
                    MaterialTheme { Box(Modifier.fillMaxSize().padding(32.dp)) {
                        if(bottom.isNotEmpty()) Caption(bottom,Modifier.align(Alignment.BottomCenter))
                        if(top.isNotEmpty()) Caption(top,Modifier.align(Alignment.TopCenter))
                    } }
                } }
            })
    }
    override fun onSceneReady() {
        super.onSceneReady()
        scene.setReferenceSpace(ReferenceSpace.LOCAL_FLOOR)
        scene.enablePassthrough(true)
        scene.setViewOrigin(0f,0f,0f,0f)
        Log.i("ConvolutionPanels","passthrough_scene_ready")
        val screen = Entity.create(
            Panel(R.id.quest_video),PanelDimensions(Vector2(2.4f,2.4f/packedAspect(playback))),
            IsdkPanelDimensions(Vector2(2.4f,2.4f/packedAspect(playback))),Hittable(),Transform(),
            Grabbable(type=GrabbableType.PIVOT_Y),IsdkGrabbable(),IsdkPanelGrabHandle())
        videoEntity = screen
        val controls = Entity.create(Panel(R.id.quest_controls),IsdkPanelDimensions(Vector2(1.6f,.432f)),Hittable(),Transform(),
            Grabbable(type=GrabbableType.PIVOT_Y),IsdkGrabbable(),IsdkPanelGrabHandle())
        Entity.create(Panel(R.id.quest_captions),Hittable(MeshCollision.NoCollision),TransformParent(screen),Transform(Pose(Vector3(0f,0f,-.015f))))
        systemManager.registerSystem(object : SystemBase() {
            private var previousPicture: Pose? = null
            private var grabbed = false
            override fun execute() {
                val head = Query.where { has(AvatarAttachment.id) }.filter { isLocal() and by(AvatarAttachment.typeData).isEqualTo("head") }.eval().firstOrNull() ?: return
                val listener = head.getComponent<Transform>().transform
                if (!placed && listener.t.y != 0f) {
                    val yaw = listener.q.removePitchAndRoll()
                    screen.setComponent(Transform(Pose(listener.t + yaw * Vector3(0f,.15f,2f),yaw)))
                    controls.setComponent(Transform(Pose(listener.t + yaw * Vector3(0f,-.75f,1.8f),yaw)))
                    previousPicture = screen.getComponent<Transform>().transform.copy()
                    placed = true
                    Log.i("ConvolutionPanels","panels_placed_at_eye_level")
                }
                val picture = screen.getComponent<Transform>().transform
                previousPicture?.let { previous ->
                    if (!picture.isApproximatelyEqual(previous,.0001f,.0001f) && !controls.getComponent<Grabbable>().isGrabbed) {
                        val delta = picture * previous.inverse()
                        controls.setComponent(Transform(delta * controls.getComponent<Transform>().transform))
                    }
                }
                previousPicture = picture.copy()
                val grabbing = screen.getComponent<Grabbable>().isGrabbed
                if (grabbing != grabbed) { grabbed = grabbing; Log.i("ConvolutionPanels","video_grabbed=$grabbing") }
                if (!poseReported) { poseReported = true; Log.i("ConvolutionPanels","spatial_pose_stream_ready") }
                // Both poses belong to this reference space. Audio integration can
                // consume them without deriving screen placement from UI pixels.
                playback.spatialPose(System.nanoTime(),
                    floatArrayOf(listener.t.x,listener.t.y,listener.t.z,listener.q.x,listener.q.y,listener.q.z,listener.q.w),
                    floatArrayOf(picture.t.x,picture.t.y,picture.t.z,picture.q.x,picture.q.y,picture.q.z,picture.q.w))
            }
        })
    }
    override fun picture(aspect: Float, layout: Int, ready: Boolean, width: Int, height: Int) {
        videoEntity?.setComponent(PanelDimensions(Vector2(2.4f,2.4f/aspect)))
        videoEntity?.setComponent(IsdkPanelDimensions(Vector2(2.4f,2.4f/aspect)))
    }
    override fun failed() { returnHome(true) }
    private fun returnHome(library: Boolean) {
        playback.detach(this)
        val panel = Intent(this,if(library) MainActivity::class.java else HomePlayerActivity::class.java).setAction(Intent.ACTION_MAIN).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        val pending = PendingIntent.getActivity(this,0,panel,PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        startActivity(Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_HOME).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("extra_launch_in_home_pending_intent",pending))
        finish()
    }
    override fun onPause() { if(::playback.isInitialized) playback.detach(this); super.onPause() }
    override fun onResume() { super.onResume(); if(::playback.isInitialized) decoderSurface?.takeIf { it.isValid }?.let { playback.attach(this,it,null); playback.resumeVideo() } }
    override fun onDestroy() { if(::playback.isInitialized) playback.detach(this); super.onDestroy() }
    private fun packedAspect(session: PlaybackSession): Float {
        val ratio = session.videoWidth().toFloat()/session.videoHeight()
        return when(session.packing()) { 2 -> ratio/2; 4 -> ratio*2; else -> ratio }
    }
}

@Composable
private fun Caption(text: String, modifier: Modifier) {
    Surface(modifier, color = androidx.compose.ui.graphics.Color.Black.copy(alpha = .8f), shape = MaterialTheme.shapes.small) {
        Text(text,Modifier.padding(horizontal=16.dp,vertical=8.dp),color=androidx.compose.ui.graphics.Color.White,
            style=MaterialTheme.typography.headlineMedium,textAlign=androidx.compose.ui.text.style.TextAlign.Center)
    }
}
