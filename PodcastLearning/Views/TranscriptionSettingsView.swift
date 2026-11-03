import SwiftUI
import PodcastCore

struct TranscriptionSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var speechKey = ""
    @State private var speechKeyStatus = ""
    var body: some View {
        @Bindable var settings = settings
        return Form {
            Section {
                Toggle("Enable Audio Transcription", isOn: $settings.transcriptionConsent)
                TextField("Azure resource URL or https://openrouter.ai/api/v1", text: $settings.speechEndpoint)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Speech Provider Base URL")
                TextField("Speech Model", text: $settings.speechModel).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Speech Provider Key", text: $speechKey).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save Speech Key") {
                    do {
                        let value = speechKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        try APIKey.save(value, account: "azureSpeech"); speechKey = value
                        speechKeyStatus = value.isEmpty ? "Speech key removed" : "Saved in Keychain"
                    } catch { speechKeyStatus = error.localizedDescription }
                }
                if !speechKeyStatus.isEmpty { Text(speechKeyStatus).font(.footnote).foregroundStyle(.secondary) }
            } footer: { Text("Bilibili audio is sent to the configured Azure Speech resource or OpenRouter. Use microsoft/mai-transcribe-2 on OpenRouter; direct Azure uses MAI-Transcribe-2. Provider charges and preview availability apply. The Speech key is separate from your AI key and stays in this device’s Keychain. Recordings must be shorter than two hours. OpenRouter uploads are split into five-minute audio parts below its 25 MB multipart limit; completed parts are kept for retry. Speech recognition can make mistakes.") }
            Section("Network Recovery") {
                Text("Keep Learn open while transferring. Uploads and responses wait for connectivity and retry temporary failures up to five times. Downloaded audio and completed results are kept for retry after interruption.")
                Text("A lost response may require uploading the audio again and may incur another charge. This API cannot resume uploads or retrieve a lost result by job ID.")
            }.font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("Audio Transcription")
            .onAppear {
                do { speechKey = try APIKey.read(account: "azureSpeech") }
                catch { speechKeyStatus = error.localizedDescription }
            }
    }
}
