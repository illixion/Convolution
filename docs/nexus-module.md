# Hypnos (Convolution) as a Nexus module

Nexus (`~/Projects/Nexus`) runs several apps as modules of one process, so their content can share
one immersive space: visionOS shows only the space-owning app's windows while a space is open, and
one app can't open another's scenes. This is its second real module (2026-11-09), after
spatial-ai-character, whose `docs/nexus-module.md` describes the same pattern.

## How it is built

Nexus compiles `Hypnos/Hypnos/` a second time, as a framework target (`HypnosModule` in Nexus's
`project.yml`), with `NEXUS_MODULE` and `HYPNOS_YOUTUBE` defined and `HypnosApp.swift`,
`HypnosAppIntents.swift`, the Info.plist and the asset catalog left out. Nothing moves out of this
repo, and this app's own build is unchanged: everything below is either shared by both builds or
inside `#if NEXUS_MODULE`.

- **`HypnosScenes.swift`**: the visionOS windows as one `Scene` (`HypnosWindows`), declared by
  `HypnosApp` and by Nexus. The immersive spaces stay in `HypnosApp`.
- **`HypnosSceneID`**: every scene id. Bare names standalone (visionOS restores windows by them), prefixed
  `hypnos.` in Nexus. No `openWindow(id:)`, `pushWindow`, `dismissWindow` or scene declaration takes a
  string literal.
- **`HypnosDefaults.store`**: every setting. `.standard` standalone, the suite `com.illixion.nexus.hypnos` in
  Nexus. `@AppStorage` always names it (`store: HypnosDefaults.store`). Nothing reads
  `UserDefaults.standard` directly (`UITestingConfiguration` aside, which is standalone only).
- **`HypnosBundle.resources`**: where scripts, models, the Metal library and the asset catalog are
  looked up. `Bundle.main` is the host's in Nexus.
- **`CinemaSpace`** (`Views/Cinema/`): what the cinema's immersive space holds and does: the screen,
  the HUD, the subtitles, the film's sound stage (`FilmStage`, RAVEFilm), the per-frame placement and
  the gestures. `CinemaSpaceView` is this app's own space around it; Nexus mounts the same root.
- **`Cinema.spaceHost`** (`CinemaSpaceHosting`): set by Nexus. `Cinema` then joins and leaves the host's
  space instead of calling SwiftUI's open/dismiss, whose bare `dismissImmersiveSpace()` would close every
  module's space.
- **`NexusHypnosModule.swift`** (`NEXUS_MODULE` only): `HypnosSpaceModule`, the `RAVESpaceModule`. It asks
  for a mixed space with the `.systemDark` surroundings behind Big Screen and keeps that current.

## Rules for changes here

- New scene ids go through `HypnosSceneID.id(_:)`; new settings through `HypnosDefaults.store`; new bundled
  resources through `HypnosBundle.resources`.
- Open or close the cinema's space only through `Cinema` (`setMode`, `release`).
- Put new cinema content under `CinemaSpace.root`, and new cinema gestures in `CinemaSpace` (the module
  forwards them), not on `CinemaSpaceView`.
- New Info.plist usage strings need a copy in Nexus's `project.yml`.
- Build all four platforms with and without `HYPNOS_YOUTUBE` before committing, as ever.

## Not done yet

- The Spatial 3D photo space (`Spatial3DImmersiveSpace`) is still this app's own and doesn't work in Nexus:
  it needs the same split into a mount.
- Debug endpoints are not namespaced (`hypnos.`); Now Playing and the audio session are not behind arbiters.
- The headset. In the simulator `cinemaMode` (debug command) puts the film in a mode while a host owns the space.
