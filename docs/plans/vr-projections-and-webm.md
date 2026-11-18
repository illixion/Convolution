# VR projections (180°/360°, fisheye), stereo photos and WebM decoding

Started 2026-11-18. The user's library has 180° OU with two fisheye circles, 180° FSBS fisheye with
two tall ovals, 360° SBS/OU, packed SBS/OU photos, and VP8/VP9 WebM. Decision (the user, same day):
**render it ourselves, don't rely on Apple's projected-media support (APMP).**

## Built

| Piece | Where | Commit |
|---|---|---|
| Local WebM thumbnails from the native still first (WebKit's capture never produced a frame on visionOS), left eye for 3D | Hypnos | c9f15ae |
| `VRProjection`, `VRFormat`, `VRSphereMesh`, `VRFormatDetector`, `FisheyeEllipseFit` (+ tests) | vergence | 22a8eb1 |
| `RAVEVRSphere`: our sphere renderer (per-eye Shader Graph, `LowLevelTexture` video, photos) | RAVESDK | ad15916 |
| Fisheye ellipse fitted from the first frame | RAVESDK | 18f2219 |
| Cinema VR mode, `GalleryVideo.vrFormat`, detection for Stash and local files, `VRFormatOverrides` | Hypnos | 8bd5936 |
| 3D settings sheet: VR section (projection, lens FOV, mono) | Hypnos | 50e7481 |
| VP8 and Vorbis through the sideload FFmpeg framework (VP8 re-encoded to HEVC per segment), VP8 thumbnails | Hypnos | 41353e1 |
| `RAVEPackedStereoPhotoView` | RAVESDK | 6c5e503 |
| Packed stereo photos in the window (auto by name), VR photos in `VRPhotoSpace`, 3D menu items | Hypnos | 650853a |

| VP9 level ≤ 5.1 in the remux playlist (visionOS refused 5.2+), VP9 thumbnails via VideoToolbox, Repeat switch | Hypnos | 517046b, 0e92978, d4ecbfb |
| VR sphere black until a frame, no-frame diagnostics | RAVESDK | f98da02 |
| `VideoFormatAnalyzer`: packing, eye order, projection from the picture | vergence | cf27552 |
| Automatic format, VR as the View Mode, the live 3D panel, compare bar, Blender priors | Hypnos, RAVESDK, vergence | (this change) |

How it works is in `.claude/rules/hypnos-video-window.md` → "VR videos". Checked in the visionOS
simulator (left eye only there): 180° SBS, 190° fisheye OU, 360° OU and squeezed fisheye ovals on black
all render the same test scene upright and unmirrored; the oval fit came out 0.421 × 0.469 against a true
0.420 × 0.469; an SBS JPEG opened as one eye in a 4:3 window; a 360° OU JPEG showed around the viewer.

## Not done yet

1. **Device check** on the Vision Pro: both eyes (the simulator shows one), comfort and sphere radius
   (12 m), 8K frame-copy cost per frame, real VR files.
2. **Device check of the automatic path**: detection on real files, VR opening by itself, the compare bar and the
   panel's live preview on the headset.
3. **Container metadata**: Matroska `StereoMode` (0x53B8) and `Projection`/`ProjectionType`
   (0x7670/0x7671), MP4 `st3d`/`sv3d`. Pass them as `declared` to `VRFormatDetector.detect`.
3. **HDR on the sphere**: the texture is 8-bit sRGB (the decoder tone maps). A half-float
   `LowLevelTexture` with a YUV→RGB compute pass would keep PQ/HLG.
4. **In VR**: subtitles on the sphere, tap to show the window's controls, a recentre gesture.
5. **Jellyfin Library** items aren't detected (only Stash and local videos are).
6. **8K VP9 speed** on the Vision Pro's VP9 decoder: measure.
7. **VP8 in the App Store edition** (open decision): keep WebKit, or vendor libvpx (BSD) for every edition.
