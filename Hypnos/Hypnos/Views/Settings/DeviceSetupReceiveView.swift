/*
 Hypnos - receive server settings from another device (every platform)

 Settings → Device Setup → Show Setup Code (on tvOS, the Device Setup page
 itself). Shows RAVEDeviceSetup's QR code for as long as the view is open
 and applies the first payload sealed to it (see `DeviceSetup`). The
 receiver lives in `DeviceSetup` so a tab-bar rebuild doesn't lose it; on
 tvOS leaving the page is told by `TVSettingsState`'s path, elsewhere by
 this view disappearing.
 */

import RAVEDeviceSetup
import SwiftUI

struct DeviceSetupReceiveView: View {
    /// Where Done goes once the settings have arrived; back, by default.
    var onDone: (() -> Void)?
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    private var setup: DeviceSetup { .shared }

    var body: some View {
        content
            .onAppear {
                setup.beginReceiving { [appModel] payload in payload.apply(to: appModel) }
            }
            #if !os(tvOS)
            .onDisappear { setup.endReceiving() }
            .navigationTitle("Set Up This Device")
            #endif
    }

    @ViewBuilder
    private var content: some View {
        #if os(tvOS)
        HStack(alignment: .center, spacing: 80) {
            code.frame(width: 560, height: 560)
            instructions.frame(maxWidth: 820, alignment: .leading)
        }
        .padding(60)
        #else
        ScrollView {
            VStack(spacing: 32) {
                code.frame(maxWidth: 320, maxHeight: 320)
                instructions.frame(maxWidth: 560, alignment: .leading)
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
        #endif
    }

    @ViewBuilder
    private var code: some View {
        if setup.received == nil, let code = setup.receiver?.code {
            RAVESetupQRCodeView(code: code)
                .padding(24)
                .background(.white, in: .rect(cornerRadius: 24))
        } else {
            Image(systemName: setup.received == nil ? "qrcode" : "checkmark.circle.fill")
                .resizable()
                .scaledToFit()
                .padding(40)
                .foregroundStyle(setup.received == nil ? Color.secondary : Color.green)
        }
    }

    @ViewBuilder
    private var instructions: some View {
        VStack(alignment: .leading, spacing: 28) {
            if let received = setup.received {
                Text("Set Up").font(.title2.bold())
                ForEach(received.summary, id: \.self) { line in
                    Label(line, systemImage: "checkmark")
                }
                Text("You can change these any time in Settings.")
                    .foregroundStyle(.secondary)
                Button("Done") { if let onDone { onDone() } else { dismiss() } }
            } else {
                Text("Send Settings from Another Device").font(.title2.bold())
                step(1, "On an iPhone or iPad, point the Camera at this code and open it in Convolution.")
                step(2, "Or on any device, take a photo of the code, then in Convolution go to Settings → Device Setup → Scan a Photo of the Code.")
                step(3, "Choose which servers to send. Their addresses, sign-ins and keys are encrypted to this code.")
                statusLine
            }
        }
    }

    private static var localNetworkSetting: String {
        #if os(tvOS)
        "Settings → Apps → Convolution"
        #elseif os(macOS)
        "System Settings → Privacy & Security → Local Network"
        #else
        "Settings → Privacy & Security → Local Network"
        #endif
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text("\(number)").font(.headline).foregroundStyle(.secondary)
            Text(text)
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch setup.receiver?.status {
        case .failed(let reason):
            Label("Convolution can't use the local network (\(reason)). Allow it in \(Self.localNetworkSetting).",
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
