/*
 Hypnos - tvOS: receive server settings from another device

 Settings → Set Up from Another Device. Shows RAVEDeviceSetup's QR code for
 as long as the page is open and applies the first payload sealed to it
 (see `DeviceSetup`). Leaving the page stops listening and discards the key,
 so a photo of an old code is useless. The receiver lives in
 `TVSettingsState` so a tab-bar rebuild doesn't lose it.
 */

#if os(tvOS)

import RAVEDeviceSetup
import SwiftUI

struct TVDeviceSetupView: View {
    @Environment(AppModel.self) private var appModel
    // In `TVSettingsState`, not `@State`: applying the payload can add the
    // Library tab, which rebuilds this view.
    private var state: TVSettingsState { .shared }
    private var receiver: RAVESetupReceiver<DeviceSetupPayload>? { state.setupReceiver }
    private var received: DeviceSetupPayload? { state.setupReceived }

    var body: some View {
        HStack(alignment: .center, spacing: 80) {
            Group {
                if received == nil, let code = receiver?.code {
                    RAVESetupQRCodeView(code: code)
                        .padding(24)
                        .background(.white, in: .rect(cornerRadius: 24))
                } else {
                    Image(systemName: received == nil ? "qrcode" : "checkmark.circle.fill")
                        .font(.system(size: 240))
                        .foregroundStyle(received == nil ? Color.secondary : Color.green)
                }
            }
            .frame(width: 560, height: 560)

            VStack(alignment: .leading, spacing: 28) {
                if let received {
                    Text("Set Up").font(.title2.bold())
                    ForEach(received.summary, id: \.self) { line in
                        Label(line, systemImage: "checkmark")
                    }
                    Text("You can change these any time in Settings.")
                        .foregroundStyle(.secondary)
                    Button("Done") { state.path.removeAll() }
                } else {
                    Text("Send Settings from Another Device").font(.title2.bold())
                    step(1, "On your iPhone or iPad, point the Camera at this code and open it in Hypnos.")
                    step(2, "Or on any device, take a photo of the code, then in Hypnos go to Settings → Apple TV → Scan a Photo of the Code.")
                    step(3, "Choose which servers to send. Their addresses, sign-ins and keys are encrypted to this code.")
                    statusLine
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
        }
        .padding(60)
        .onAppear {
            // Leaving the page (it drops out of the path) stops listening.
            state.beginDeviceSetup { [appModel] payload in payload.apply(to: appModel) }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text("\(number)").font(.headline).foregroundStyle(.secondary)
            Text(text)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch receiver?.status {
        case .failed(let reason):
            Label("Hypnos can't use the local network (\(reason)). Allow it in Settings → Apps → Hypnos.",
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .starting, nil:
            Label("Getting ready…", systemImage: "hourglass").foregroundStyle(.secondary)
        default:
            Label("Waiting for your other device…", systemImage: "antenna.radiowaves.left.and.right")
                .foregroundStyle(.secondary)
        }
    }
}

#endif
