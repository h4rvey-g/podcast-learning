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
            }
        }.navigationTitle("Audio Transcription")
            .onAppear {
                do { speechKey = try APIKey.read(account: "azureSpeech") }
                catch { speechKeyStatus = error.localizedDescription }
            }
    }
}
