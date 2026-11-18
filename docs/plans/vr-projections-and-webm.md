# VR projections (180°/360°, fisheye) and WebM decoding

Investigation, 2026-11-18. Nothing here is built yet except the thumbnail fix (`c9f15ae`).

## What exists today

- **Stereo is flat-only.** `StereoscopicFormat` / `PackedStereoLayout` (Vergence) know SBS/OU, full or
  half, eyes reversed. The stereo pump crops two eyes and shows them on a flat `VideoPlayerComponent`
  screen (tagged stereo buffers through `AVSampleBufferVideoRenderer`). There is no notion of a
  projection: a 180° or 360° file plays as a warped flat 3D rectangle. `SpatialCameraMetadata.Projection`
  has only `.rectilinear`; `SphericalMetadata` writes `st3d` but nothing reads `sv3d`/`proj`.
- **Detection** is Stash tags (`StereoscopicFormat.detect`) and, in `vergence make` only, the file name
  and the picture (`StereoLayoutDetector`). Local files get no stereo info at all
  (`LocalMediaSource` sets `isStereoscopic: false`), so local 3D never plays as 3D without the 3D sheet.
- **Photos** have AI 3D (depth) and Apple's Spatial 3D only. A frame-packed SBS/OU photo shows as one
  wide picture. `RAVEStereoPhotoView` already renders a tagged-eye stereo pair for AI 3D, so a packed
  photo needs only its two eyes cut out.
- **WebM.** `MatroskaRemux` remuxes H.264/HEVC/VP9/AV1 Matroska to fMP4 HLS on the device, so VP9 WebM
  already plays natively (the VP9 supplemental decoder is registered at launch; measured working on
  the Mac, and YouTube VP9 plays natively on the Vision Pro). It **declines VP8 and Vorbis-only audio**;
  those fall to WebKit, which loses the native player, AI 3D, the cinema, subtitles and spatial audio.
  The visionOS simulator has no VP9 decoder (`-11869`), so VP9 can only be checked on the Mac or device.
- **FFmpeg** is already in the sideload edition: `HypnosFFmpeg.framework` (FFmpeg 9.0.2, LGPL, dlopened,
  `HYPNOS_FFMPEG`), built by `scripts/build-ffmpeg-decoders.sh` with only `dca,truehd,mlp` decoders and the
  `dovi_rpu` bsf. The remux already has the hook it needs: `RemuxAudioDecoding` (DTS/TrueHD → ALAC).

## Formats to cover

| Name | Packing | Projection per eye |
|---|---|---|
| 180° SBS / OU (VR180, DeoVR `_180_LR`, `_180_TB`) | full SBS or OU | half-equirectangular |
| 360° SBS / OU (`_360_LR`, `_360_TB`) | full SBS or OU (OU is the common one) | equirectangular |
| 360° mono | none | equirectangular |
| Fisheye OU, two equal circles (the user's) | OU | circular fisheye, ~180-200° |
| Fisheye FSBS, two tall ovals (the user's; DeoVR `_FISHEYE190`, `_MKX200`, `_MKX220`, `_RF52`, `_VRCA220`) | full SBS | fisheye with anamorphic x/y radii |
| Frame-packed photos (JPEG/PNG/HEIC, SBS/OU, flat, 180° or 360°) | as above | as above |

A fisheye eye is fully described by an ellipse (centre, x radius, y radius, in eye UV) plus a field of
view and a lens model (equidistant `r = f·θ` covers MKX/RF52 well enough to start). A circle is the
`rx == ry` case, so the OU circles and the SBS ovals are one model.

## Proposed design

### 1. One description: `VRProjection` (VergenceCore, portable, unit-tested)

```swift
public enum VRProjection: Codable, Hashable, Sendable {
    case rectilinear                       // today's flat 3D
    case equirectangular(degrees: Double)  // 360, or 180 = half-equirect
    case fisheye(fieldOfView: Double, ellipse: EyeEllipse, lens: FisheyeLens)
}
```

Carried next to `PackedStereoLayout` in `Video3DSettings` (and a photo equivalent), and in the 3D sheet as
a Projection picker with FOV and an "Fit circle" ellipse editor for fisheye.

Detection, strongest first, extending `StereoLayoutDetector`:
1. Container: MP4 `sv3d`/`st3d` and Apple APMP extensions; Matroska `StereoMode` (1 = SBS, 3 = TB…) and
   `Projection`/`ProjectionType` (1 = equirectangular), which `MatroskaHeader` already walks past.
2. Stash tags: add `180`, `360`, `vr180`, `vr360`, `fisheye`, `mkx200`, `mkx220`, `rf52`, `fisheye190`.
3. File name: the DeoVR/HereSphere tokens above.
4. Picture: black corners outside an inscribed circle or ellipse ⇒ fisheye, and the ellipse fitted
   from where the black ends (one luma frame, cheap). Also fills the ellipse for a tag that says only
   "fisheye".
5. Local files start using 2-4, so local 3D plays as 3D.

### 2. Rendering: let visionOS do it where it can

visionOS 26 plays **Apple Projected Media Profile** natively: `VideoPlayerComponent` has
portal / progressive / full immersive modes, and the format description extensions
`ProjectionKind` (`equirectangular`, `halfEquirectangular`) plus `ViewPackingKind` (`sideBySide`,
`overUnder`) describe exactly the 180/360 SBS/OU files, frame-packed, with no re-encode.

- **Remuxed files (WebM/MKV):** `MatroskaRemux` writes the init segment, so it can add the APMP sample-entry
  boxes; AVPlayer and `VideoPlayerComponent` then present it as immersive. Zero per-frame cost.
- **Everything else:** the stereo pump already feeds `VideoPlayerComponent(videoRenderer:)`; set the
  projection/packing extensions on the format descriptions it enqueues.
- **Fisheye:** APMP has no fisheye kind (`parametricImmersive` needs real lens calibration). Remap each eye
  fisheye → half-equirectangular in the pump (one Metal pass, a lookup per pixel, next to the existing eye
  crop) and present the result as half-equirect APMP. The same pass handles anamorphic ovals.

**Spike first (the open question):** does `VideoPlayerComponent(videoRenderer:)` honour projection
extensions on enqueued buffers, and is the immersive mode available from a window's RealityView or only in
an `ImmersiveSpace` (Hypnos has `CinemaSpace`)? If the renderer route refuses, the fallback is our own
sphere / hemisphere mesh in `CinemaSpace` with a per-eye ShaderGraph material (`CameraIndexSwitch`)
sampling a `LowLevelTexture` the pump writes. That route also does fisheye in the shader with no remap
pass, at the cost of losing Apple's comfort mitigation and progressive mode.

### 3. Photos

- **Flat SBS/OU photos:** cut the eyes with `PackedStereoLayout.eyeRegion` and show them in
  `RAVEStereoPhotoView` (no depth model). A new photo viewing mode next to AI 3D, chosen automatically
  when the file name or tags say SBS/OU, with an eyes-reversed toggle.
- **180°/360° photos:** the same immersive presentation as video. Simplest uniform path is a one-frame
  stream through the same renderer with APMP tags; else the sphere-mesh route above. Fisheye photos get
  the same remap.

### 4. WebM decoding: VP8 and Vorbis

VP9 needs nothing new except a measurement: 8K60 VR VP9 on the Vision Pro's decoder. If it can't keep up,
that is a separate problem (server transcode or a resolution cap), not one FFmpeg fixes.

For VP8 (and Vorbis), extend the existing sideload-only FFmpeg framework rather than adding a second player:

1. `build-ffmpeg-decoders.sh`: add `--enable-decoder=vp8,vorbis` (FFmpeg's own LGPL decoders, no libvpx;
   arm64 NEON assembly is on by default).
2. **Vorbis:** a `RemuxAudioDecoding` entry, exactly like DTS/TrueHD → ALAC. Small.
3. **VP8:** a video transcode stage inside the remux. Each segment's VP8 frames are decoded with FFmpeg
   into `CVPixelBuffer`s and re-encoded with a hardware `VTCompressionSession` (HEVC, high bitrate, same
   GOP as the source's keyframes so segment boundaries don't move), then muxed as today. AVPlayer plays it,
   so AI 3D, the cinema, subtitles, speed and the APMP route above all work unchanged. Cost is one decode
   and one hardware encode per segment, paid ahead of the playhead; a seek costs one segment.
4. **Thumbnails:** `VideoStill` decodes the one keyframe with FFmpeg into a `CGImage` when the codec is
   VP8, so WebKit's capture can be deleted.

**Decision for the user:** the FFmpeg framework is sideload-only by construction (`HYPNOS_FFMPEG`, kept
for the Dolby/DTS rule). VP8 has no such rule. Options for the App Store edition: keep WebKit for VP8, or
vendor libvpx (BSD) as a small separately built framework for every edition.

## Order

1. APMP spike on device (renderer + format description extensions, window vs immersive space).
2. `VRProjection` + detection (container, tags, names, picture) + local-file detection + 3D sheet.
3. 180/360 SBS/OU playback through APMP, remux init-segment boxes.
4. Fisheye remap pass (circle and oval).
5. Stereo photos: flat SBS/OU in `RAVEStereoPhotoView`, then 180/360/fisheye photos.
6. FFmpeg Vorbis decoder, then VP8 transcode stage and VP8 thumbnails.

Steps 2 and 4's maths belong in VergenceCore (portable, tested on Linux, usable by the Quest port);
the Metal pass in VergenceApple's `Stereo/`.
