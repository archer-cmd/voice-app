import SwiftUI

/// A little pop-up that asks for the user's own Anthropic API key. The key is
/// saved to the Keychain by `KeychainStore`. The user can also skip it and use
/// plain transcription with no AI cleanup. ContentView shows this sheet when
/// the "Add API Key" button is pressed.
struct APIKeyPromptView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var saveFailed = false

    var onSaved: () -> Void = {}
    var onSkip: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add your Anthropic API key")
                .font(.title2.bold())

            Text("This app can use Claude to tidy up your words (fix “um”s, punctuation, and so on). Paste your own key below — it stays in your Mac's Keychain and is never shared. You can also skip and use plain transcription.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("sk-ant-…", text: $key)
                .textFieldStyle(.roundedBorder)

            if saveFailed {
                Text("Couldn't save that. Please try again.")
                    .foregroundStyle(.red).font(.caption)
            }

            HStack {
                Button("Skip (plain mode)") { onSkip(); dismiss() }
                Spacer()
                Button("Save") {
                    if KeychainStore.saveAPIKey(key) { onSaved(); dismiss() }
                    else { saveFailed = true }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Link("Get a key at console.anthropic.com",
                 destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                .font(.caption)
        }
        .padding(24)
        .frame(width: 440)
    }
}
