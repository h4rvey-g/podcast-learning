import SwiftUI
import PodcastCore

struct SynthesisSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var key = ""
    @State private var status = ""
    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                TextField("TTS Model", text: $settings.ttsModel)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Voice Name or ID", text: $settings.ttsVoice)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Link("Supported Models and Voices", destination: URL(string: "https://openrouter.ai")!.appendingPathComponent(settings.ttsModel))
            } header: { Text("OpenRouter Text to Speech") } footer: {
                Text("Defaults: elevenlabs/eleven-v4-turbo with george. Use a voice supported by your model and MP3 output. The offline practice voice and speaking rate are separate.")
            }
            Section {
                SecureField("OpenRouter API Key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save TTS Key") {
                    do {
                        try APIKey.save(key.trimmingCharacters(in: .whitespacesAndNewlines), account: "openRouterTTS")
                        key = ""; readStatus()
                    } catch { status = error.localizedDescription }
                }
                Text(status).font(.footnote).foregroundStyle(.secondary)
            } header: { Text("API Key") } footer: {
                Text("Stored only in this device’s Keychain, separately from AI and transcription keys. Enter an empty key and save to remove it. Adding a PDF or Word document automatically sends cleaned text to OpenRouter for speech generation; charges may apply.")
            }
            Section {
                Text("Adding a PDF or Word document creates a session and automatically extracts text, cleans it with your configured AI provider, and generates audio in parallel. Cleanup uses one whole-document JSON-schema request; choose an AI model with enough context and output capacity. Enable AI in Settings → Provider first. Pasted text and other text files keep their manual cleanup and generation controls. Keep PodLearn open until generation finishes. Completed parts are kept for retry; changing the model or voice generates new parts.")
                Text("A lost response may be charged again on retry. AI-generated speech can contain mistakes. Downloaded Media can delete generated audio without removing your transcript.")
            }.font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("Generated Audio")
            .onAppear { readStatus() }
    }
    private func readStatus() {
        do { status = try APIKey.read(account: "openRouterTTS").isEmpty ? "No TTS key saved" : "TTS key saved in Keychain" }
        catch { status = error.localizedDescription }
    }
}
