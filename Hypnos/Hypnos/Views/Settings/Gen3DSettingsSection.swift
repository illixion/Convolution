//
//  Gen3DSettingsSection.swift
//  Hypnos
//
//  Sideload/dev-only (HYPNOS_GEN3D): Settings → Developer → Generated 3D. The
//  address of Gen3DServer and its token; the token lives in the Keychain.
//

#if HYPNOS_GEN3D

import SwiftUI

struct Gen3DSettingsSection: View {
    @AppStorage(Gen3DConfig.urlKey, store: HypnosDefaults.store) private var address = ""
    @AppStorage(Gen3DConfig.engineKey, store: HypnosDefaults.store) private var engine = ""
    @State private var token = KeychainStore.string(for: .gen3dToken) ?? ""
    @AppStorage(Gen3DConfig.decorKey, store: HypnosDefaults.store) private var decor = false
    @State private var engines: [String] = []
    @State private var message: String?
    @State private var checking = false
    @OpenWindowProxy private var openWindow

    var body: some View {
        Section {
            TextField("Server (http://100.x.y.z:8787)", text: $address)
                .textFieldTapTarget()
                .textContentType(.URL)
                #if !os(macOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            SecureField("Token", text: $token)
                .textFieldTapTarget()
                .onChange(of: token) { _, value in
                    KeychainStore.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: .gen3dToken)
                }
            Picker("Engine", selection: $engine) {
                Text("Default (\(Gen3DConfig.defaultEngine))").tag("")
                ForEach(engines, id: \.self) { Text($0).tag($0) }
                // A stored engine the server no longer lists stays selectable.
                if !engine.isEmpty, !engines.contains(engine) { Text(engine).tag(engine) }
            }
            Toggle("Hide Controls in the Volume", isOn: $decor)
            Button(checking ? "Checking…" : "Check Connection") { check() }
                .disabled(checking || address.isEmpty)
            #if os(visionOS)
            Button("Open the Model Library") { openWindow(id: HypnosSceneID.gen3dLibrary) }
            #endif
            Button("Clear Generated Models", role: .destructive) {
                Gen3DAssetCache.shared.clear()
                #if os(visionOS)
                Gen3DLibrary.shared.refresh()
                #endif
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Generated 3D")
        } footer: {
            Text("A private server that turns a picture into a model you can walk around (the photo viewer's 3D menu, on a headset). Experimental and not part of any submission build.")
        }
        .task(id: address) { await loadEngines() }
    }

    private func loadEngines() async {
        guard let client = try? Gen3DClient() else { return }
        var request = URLRequest(url: client.base.appendingPathComponent("v1/engines"))
        request.setValue("Bearer " + client.token, forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let keys = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?.keys else { return }
        engines = keys.sorted()
    }

    private func check() {
        checking = true
        message = nil
        Task {
            defer { checking = false }
            do {
                let client = try Gen3DClient()
                var request = URLRequest(url: client.base.appendingPathComponent("v1/engines"))
                request.setValue("Bearer " + client.token, forHTTPHeaderField: "Authorization")
                request.timeoutInterval = 10
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { message = "No response."; return }
                if http.statusCode == 200 {
                    let names = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?.keys.sorted() ?? []
                    engines = names
                    message = "Connected. Engines: \(names.joined(separator: ", "))."
                } else {
                    message = Gen3DError.http(http.statusCode, "").localizedDescription
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

#endif
