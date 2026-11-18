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
    @State private var message: String?
    @State private var checking = false

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
            TextField("Engine (default \(Gen3DConfig.defaultEngine))", text: $engine)
                .textFieldTapTarget()
                .autocorrectionDisabled()
                #if !os(macOS)
                .textInputAutocapitalization(.never)
                #endif
            Button(checking ? "Checking…" : "Check Connection") { check() }
                .disabled(checking || address.isEmpty)
            Button("Clear Generated Models", role: .destructive) { Gen3DAssetCache.shared.clear() }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Generated 3D")
        } footer: {
            Text("A private server that turns a picture into a model you can walk around (the photo viewer's 3D menu, on a headset). Experimental and not part of any submission build.")
        }
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
