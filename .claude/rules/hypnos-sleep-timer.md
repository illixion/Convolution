---
paths:
  - "Hypnos/Hypnos/Services/SleepTimer/**"
  - "Hypnos/Hypnos/Views/SleepTimer/**"
  - "Hypnos/Hypnos/Support/IdleTimerHold.swift"
  - "Hypnos/HypnosUITests/SleepTimerUITests.swift"
  - "Configuration/Hypnos.xcconfig"
  - "Hypnos/Hypnos/HypnosHomeKit.entitlements"
  - "Hypnos/Hypnos/HypnosTV.entitlements"
---

# Hypnos: sleep timer

A timer that ends playback and, optionally, sets accessories (an HDMI display's smart plug, the
lights) through **RAVESDK's `RAVEHome`**, which was extracted from Spatial Home on 2026-11-10 so both
apps drive Home Assistant and HomeKit the same way. visionOS, iOS/iPadOS, tvOS and macOS; **not Quest**
(a headset has no HDMI output to put to sleep, and the port builds only with the Swift Android SDK).

## What ends, in order

`SleepTimer.finish()` (`Services/SleepTimer/SleepTimer.swift`): 1. every registered player is asked to
pause; 2. on iOS and tvOS `IdleTimerHold.releaseAll()` lets the device lock, which is the point for an
HDMI-mirrored iPad (a playing player holds `isIdleTimerDisabled`, so without this the screen stays lit
all night; a player that plays again simply holds again); 3. the saved `HomeActionTarget`s run through
`HomeActionRunner` (waits for each backend, retries once, records an outcome per action for the
settings page). Pausing comes first so the picture never glitches under a plug being cut.

The deadline runs on the **continuous clock**: a device that slept through it ends the timer when the
app next runs. An app suspended in the background does not tick (music keeps it alive through the
`audio` background mode).

## Players register, they are not enumerated

`SleepTimer.register(owner) { pause-if-playing -> Bool }`, held weakly. Registered: `VideoWindowModel`
(`start()`/`cleanup()`; `pauseForSleepTimer()` pauses whichever renderer draws it), `FilmSession`,
`JellyfinMusicSession`, the slideshow wrapper `SlideshowEngine` (`start()`/`stop()`), and the tvOS
`AVPlayerViewController`'s player. **A new player must register or the timer will leave it playing.**
The control is `SleepTimerMenu` (a `PlayerChoiceMenu`: the moon, a countdown badge while it runs) next
to the speed menu in the video bar and the film bar; tvOS gets `SleepTimerTVMenu` in the transport bar.

## The homes (`SleepHome`)

`SleepHome.shared` owns one `HAConnection` and one `HomeKitConnection`. **Nothing connects until asked**:
no HomeKit permission prompt until the person turns HomeKit on, no socket to an unconfigured server.
The HA address is in `HypnosDefaults`, the **token in the Keychain** (`KeychainStore.Key.homeAssistantToken`).
Arming the timer calls `prepare(for:)` so the connections are up when it ends; the runner still waits up to
20 s for each. Not in Device Setup's payload and not in a settings backup (secrets stay out of backups).

## HomeKit and signing: read before changing

- **Native macOS has no HomeKit module.** `HomeKitConnection` is a stub there that reports "unavailable";
  Home Assistant works on the Mac.
- **The shared sideload wildcard profile (iOS, visionOS) has no HomeKit capability**, and the legacy
  VisionVNC profile that has it breaks Now Playing on those platforms. So the `com.apple.developer.homekit`
  entitlement is **opt-in**: `HOMEKIT_ENTITLEMENTS` in `Configuration/Hypnos.xcconfig` is empty, and a build
  whose App ID and profile carry the capability sets it to `Hypnos/HypnosHomeKit.entitlements`. Without it
  HomeKit is simply silent (checked on the visionOS simulator: the app keeps running, the manager never
  answers) and the settings page says "HomeKit isn't responding. This build may be signed without the HomeKit
  capability" via `HomeKitConnection.isSilent`.
- **tvOS has it already**: `HypnosTV.entitlements` carries the key and the tvOS dev profile
  (`atv-dev.mobileprovision`) has HomeKit, so Apple TV works with no extra step.
- A personal-team Xcode build cannot add the capability: that is why it is not in the default settings.

## Tests

`RAVEHomeTests` (in RAVESDK) cover the states, the saved target and its icon, and the runner with a mock
backend. `SleepTimerUITests` can only open the page and check HomeKit-without-capability leaves the app
running: on the visionOS simulator a tap on a form row doesn't register, swipes are refused, text fields get
no keyboard focus and an unsigned build has no Keychain. The timer ending, the pause hooks, the real HomeKit
and Home Assistant writes need a device (see the open-threads ledger).
