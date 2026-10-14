---
paths:
  - "Hypnos/HypnosUITests/**"
  - "Hypnos/Shared/AccessibilityIdentifiers.swift"
  - "Hypnos/Hypnos/Support/UITestingConfiguration.swift"
  - "scripts/run-ui-tests.sh"
---

# Hypnos: XCUITest suite

Moved out of `CLAUDE.md` (the `run-ui-tests.sh` commands stayed there).

`HypnosUITests` is the app's only test target and exists because **XCUITest is
the only way to drive a visionOS app's UI**: `simctl` has no tap/swipe/scroll
subcommand of any kind, so the alternative is coordinate math against a screenshot
through `macos-control`, one Touch ID prompt per session, and gestures the simulator
handles badly. XCUITest is accessibility-driven, needs no coordinates, and runs
headless. The script exists mainly to keep `-collect-test-diagnostics never` on every
invocation — without it a *passing* run hangs for exactly 600 s afterwards (see
`~/Projects/CLAUDE.md`).

Three pieces make it work:

- **`Shared/AccessibilityIdentifiers.swift` is a member of both targets.** It is the
  one file in the project referenced explicitly in `project.pbxproj` rather than
  picked up by the synchronized folder group, and that is the point: a test target
  shares no module with the app, so identifiers otherwise get written twice and the
  copy in the test target rots. Shared-component identifiers come from RAVEUI's
  `RAVEA11y` instead, which both targets link — a tab is `rave.tab.<enum case name>`,
  deliberately the case name rather than the display title, which is mid-rename.
- **`Support/UITestingConfiguration.swift`** applies `-UITestDefault key=value` launch
  arguments to UserDefaults before `AppModel.init` reads them (hence
  `HypnosApp.init` being written out rather than using a property default —
  a default value expression would run first). DEBUG-only, so a release build has no
  launch arguments that rewrite settings.
- **`AppLauncher.baseline` states the flags every test reads.** Resetting the defaults
  domain is not sufficient on the simulator: `cfprefsd` serves values that survive
  both `removeObject(forKey:)` and `removePersistentDomain(forName:)` — measured with
  `persistentDomain` returning empty, no plist on the device containing the key, and
  `bool(forKey:)` still returning `true` on the next line. Any new test that depends
  on a persisted flag must declare it via `defaults:` rather than assume a wipe.

Two things worth knowing before writing more:

- **Identify containers with `.accessibilityElement(children: .contain)`.** SwiftUI
  only puts a group in the accessibility tree when asked, so a bare
  `.accessibilityIdentifier` on a `VStack` attaches to nothing and the test cannot see
  it. `app.anyElement(id)` then avoids also having to guess which element *type* the
  view mapped onto.
- **Spatial 3D generation is device-only.** In the simulator it fails with
  `Spatial3DImageError error 9`, so the welcome sample's conversion test asserts the
  designed fallback (back to the flat photo, Convert offered again) rather than
  success. Anything else touching `ImagePresentationComponent` needs the same shape.

`VideoWindowUITests` opens a dev-Stash video (see "Testing against Stash"; it skips
when `scripts/dev-stash.sh up` isn't running) and checks the player ornament's
geometry, with `autoHideDelay=0` so the chrome can't vanish mid-query. XCUITest's
own `XCUIScreen` screenshot is black on visionOS; capture with `simctl io` instead.

Not yet covered: any window actually *listed* in the Windows tab, which needs a
pop-out, which needs media. Seeding that is `simctl addmedia` plus
`simctl privacy grant photos` from outside the test process — harness work for
`run-ui-tests.sh`, not a gap in the app.
