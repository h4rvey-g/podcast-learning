import SwiftUI
import SwiftData
import AVFoundation
import PodcastCore

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Transcript.createdAt, order: .reverse) private var transcripts: [Transcript]
    @State private var key = ""
    @State private var keyStatus = ""
    @State private var testStatus = ""
    @State private var testing = false
    @State private var deletingAudio: Transcript?
    @State private var storageRevision = 0
    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker(selection: $settings.targetLevel) { ForEach(CEFR.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) } } label: { Label("Target Level", systemImage: "gauge.with.dots.needle.50percent") }
            } header: { Text("Learning") } footer: { Text("Words at or above this level are marked. Each transcript can override it. Changing this setting applies to new imports; use the reader’s level menu to update an existing transcript.") }
            Section {
                Toggle("Enable AI Analysis", isOn: $settings.aiConsent)
                LabeledContent("Provider") { TextField("api.openai.com", text: $settings.host).multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled() }
                LabeledContent("Base Path") { TextField("/v1", text: $settings.basePath).multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled() }
                LabeledContent("Model") { TextField("gpt-4.1", text: $settings.model).multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled() }
                SecureField("API Key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save API Key", systemImage: "key") {
                    do { try APIKey.save(key.trimmingCharacters(in: .whitespacesAndNewlines)); keyStatus = key.isEmpty ? "API key removed" : "Saved in Keychain" }
                    catch { keyStatus = error.localizedDescription }
                }
                if !keyStatus.isEmpty { Text(keyStatus).font(.footnote).foregroundStyle(.secondary) }
                Button { Task { await testConnection() } } label: { HStack { Label("Test Connection", systemImage: "network"); if testing { Spacer(); ProgressView() } } }.disabled(testing)
                if !testStatus.isEmpty { Text(testStatus).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text("AI") } footer: { Text("When enabled, imported transcripts and selected sentences are sent to your configured provider for analysis. Your API key stays in this device’s Keychain. Provider charges may apply. AI output can be inaccurate.") }
            Section("Speech") {
                Picker("Voice", selection: $settings.voice) { Text("English (US)").tag("en-US"); Text("English (UK)").tag("en-GB") }
                VStack(alignment: .leading) { Text("Speaking Rate · \(settings.rate / Double(AVSpeechUtteranceDefaultSpeechRate), format: .number.precision(.fractionLength(1)))×"); Slider(value: $settings.rate, in: 0.25...0.6, step: 0.025).accessibilityLabel("Speaking Rate") }
            }
            Section("Downloaded Audio") {
                ForEach(transcripts.filter { AudioStore.localURL($0.id) != nil }) { transcript in
                    HStack { VStack(alignment: .leading, spacing: 4) { Text(transcript.title); Text(ByteCountFormatter.string(fromByteCount: AudioStore.size(transcript.id), countStyle: .file)).font(.footnote).foregroundStyle(.secondary) }; Spacer(); Button("Delete Audio", systemImage: "trash", role: .destructive) { deletingAudio = transcript }.labelStyle(.iconOnly).buttonStyle(.borderless).frame(width: 44, height: 44) }
                }
                if transcripts.allSatisfy({ AudioStore.localURL($0.id) == nil }) { Text("No audio downloaded").foregroundStyle(.secondary) }
            }.id(storageRevision)
            Section("Acknowledgments") {
                Text("Vocabulary levels: CEFR-J Wordlist Version 1.6, compiled by Yukio Tono (Tokyo University of Foreign Studies, Tono Lab) and Octanove Vocabulary Profile C1/C2 Version 1.0. Variant spellings merged; duplicate senses retain the lowest level.").font(.footnote)
                Link("CEFR-J Project", destination: URL(string: "https://www.cefr-j.org/")!)
                Link("Octanove Vocabulary Profile · CC BY-SA", destination: URL(string: "https://github.com/openlanguageprofiles/olp-en-cefrj")!)
                Link("CC BY-SA 4.0 License", destination: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!)
                Text("Transcripts via PodText. Audio and transcripts belong to their respective publishers. OpenAI Swift SDK by MacPaw (MIT).").font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { do { key = try APIKey.read(); keyStatus = key.isEmpty ? "No API key saved" : "In Keychain" } catch { keyStatus = error.localizedDescription } }
            .confirmationDialog("Delete downloaded audio? The transcript and word progress are kept.", isPresented: Binding(get: { deletingAudio != nil }, set: { if !$0 { deletingAudio = nil } }), titleVisibility: .visible) {
                Button("Delete Audio", role: .destructive) { if let transcript = deletingAudio { do { try AudioStore.delete(transcript.id); storageRevision += 1 } catch { store.error = error.localizedDescription } }; deletingAudio = nil }
                Button("Cancel", role: .cancel) { deletingAudio = nil }
            }
    }
    @MainActor private func testConnection() async {
        testing = true; testStatus = ""; defer { testing = false }
        do { try await AIAnalyzer(settings: settings).test(); testStatus = "Connected successfully" }
        catch { testStatus = error.localizedDescription }
    }
}
