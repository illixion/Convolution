import SwiftUI

/// Settings for a Vergence analysis server (`AnalysisCoordinator`): its
/// address and the token `vergenced token add NAME --grants play` printed.
struct AnalysisServerSection: View {
    @AppStorage(AnalysisCoordinator.urlKey) private var address = ""
    @State private var token = KeychainStore.string(for: .analysisCoordinatorToken) ?? ""

    var body: some View {
        Section {
            TextField("Server (http://host:8420)", text: $address)
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
                    KeychainStore.set(value.trimmingCharacters(in: .whitespacesAndNewlines), for: .analysisCoordinatorToken)
                }
        } header: {
            Text("Analysis Server")
        } footer: {
            Text("A Vergence analysis server lets other computers prepare a 3D Library title's Smooth Motion while it plays, starting where you are watching. Leave it empty to use only what the Jellyfin plugin prepared overnight.")
        }
    }
}
