/*
 Hypnos - Apple TV setup, the app's half

 RAVESDK's `RAVEDeviceSetup` does the transfer (see `RAVESetupCode` for the
 protocol); Hypnos supplies what travels (`DeviceSetupPayload`) and the two
 screens:

 - Apple TV: Settings → Set Up from Another Device (`TVDeviceSetupView`)
   shows the QR code and applies what arrives.
 - Everything else: pointing an iPhone's Camera at the code opens
   `hypnos://setup?...`, or Settings → Apple TV reads it from a photo
   (`DeviceSetupSendSection`). Either way `pending` gets the code and the
   window root presents `DeviceSetupSendSheet` to confirm.

 `_hypnos-setup._tcp` is listed under NSBonjourServices in Info.plist.
 */

import Observation
import RAVEDeviceSetup

@MainActor
@Observable
final class DeviceSetup {
    static let shared = DeviceSetup()
    static let service = RAVESetupService(urlScheme: "hypnos", bonjourType: "_hypnos-setup._tcp")

    /// A scanned setup code waiting for the user to confirm sending.
    var pending: RAVESetupCode?

    private init() {}
}
