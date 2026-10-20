/*
 Hypnos - Device Setup, the app's half

 Moves server addresses and sign-ins from one device to another, any
 platform to any other: Settings → Device Setup on every platform. RAVESDK's
 `RAVEDeviceSetup` does the transfer (see `RAVESetupCode` for the protocol);
 Hypnos supplies what travels (`DeviceSetupPayload`) and the screens:

 - The device being set up shows a QR code (`DeviceSetupReceiveView`) and
   applies what arrives. It listens only while the code is on screen
   (`beginReceiving`/`endReceiving`); leaving discards the key, so a photo of
   an old code is useless.
 - The device sending: pointing an iPhone's Camera at the code opens
   `hypnos://setup?...`, or Settings → Device Setup reads it from a photo
   (`DeviceSetupSettingsPage`). Either way `pending` gets the code and the
   window root presents `DeviceSetupSendSheet` to confirm. tvOS can't send:
   it has no way to read a code.

 `_hypnos-setup._tcp` is listed under NSBonjourServices in Info.plist; the
 macOS sandbox needs `network.server` to listen.
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

    /// While this device shows its own code: the listener, and what it
    /// received. Kept here rather than in the view, because applying a
    /// payload can add a tab (Library, once Jellyfin is set up), which
    /// rebuilds tvOS's Settings and would take view state with it.
    private(set) var receiver: RAVESetupReceiver<DeviceSetupPayload>?
    private(set) var received: DeviceSetupPayload?

    private init() {}

    /// Starts listening unless a receiver is already up or has finished.
    func beginReceiving(applying apply: @escaping @MainActor (DeviceSetupPayload) -> Void) {
        guard receiver == nil, received == nil else { return }
        let receiver = RAVESetupReceiver<DeviceSetupPayload>(service: Self.service) { [weak self] payload in
            apply(payload)
            self?.received = payload
        }
        receiver.start()
        self.receiver = receiver
    }

    /// Stops listening and forgets the key and the result.
    func endReceiving() {
        receiver?.stop()
        receiver = nil
        received = nil
    }
}
