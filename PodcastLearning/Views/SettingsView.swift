import SwiftUI
import SwiftData
import AVFoundation
import PodcastCore
import PodcastAI

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppStore.self) private var store
    @Query(sort: \Transcript.createdAt, order: .reverse) private var transcripts: [Transcript]
    @State private var key = ""
    @State private var keyStatus = ""
    @State private var testStatus = ""
    @State private var testing = false
    @State private var deletingAudio: Transcript?
    @State private var storageRevision = 0
    private var downloaded: [Transcript] { transcripts.filter { AudioStore.localURL($0.id) != nil } }
    private var voices: [AVSpeechSynthesisVoice] { AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en-") }.sorted { $0.name < $1.name } }
    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker(selection: $settings.targetLevel) { ForEach(CEFR.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) } } label: {
                    Label { Text("Target Level") } icon: { SettingsIcon(symbol: "gauge.with.dots.needle.50percent") }
                }.pickerStyle(.navigationLink)
            } header: { Text("Learning") } footer: { Text("Words at or above this level are marked. Each transcript can override it. Changes apply to new imports; use the reader’s level menu for existing transcripts.") }
            Section {
                NavigationLink { providerForm } label: { row("Provider", value: settings.host, symbol: "server.rack", color: .indigo) }
                NavigationLink {
                    Form { TextField("Model", text: $settings.model).textInputAutocapitalization(.never).autocorrectionDisabled() }.navigationTitle("Model")
                } label: { row("Model", value: settings.model, symbol: "cpu", color: .indigo) }
                Picker(selection: $settings.thinking) {
                    ForEach(ThinkingLevel.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                } label: { Label { Text("Thinking Level") } icon: { SettingsIcon(symbol: "brain", color: .indigo) } }.pickerStyle(.navigationLink)
                NavigationLink { apiKeyForm } label: { row("API Key", value: key.isEmpty ? "Not Set" : "In Keychain", symbol: "key", color: .indigo) }
                Button { Task { await testConnection() } } label: {
                    HStack { SettingsIcon(symbol: "cable.connector", color: .cyan); Text("Test Connection"); Spacer(); if testing { ProgressView() } }
                }.disabled(testing)
                if !testStatus.isEmpty { Text(testStatus).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text("AI") } footer: { Text(settings.aiConsent ? "AI is enabled. Transcripts are sent to your provider; charges may apply." : "AI is off. Enable it in Provider to generate explanations and word details.") }
            Section {
                NavigationLink { TranscriptionSettingsView() } label: { row("Audio Transcription", value: settings.transcriptionConsent ? "MAI-Transcribe-2" : "Off", symbol: "waveform.badge.mic", color: .indigo) }
                Toggle("Keep Bilibili Video", isOn: $settings.keepBilibiliVideo)
            } header: { Text("Bilibili Imports") } footer: { Text("Audio only by default. Keep Video saves a local video with sound for new imports; only audio is uploaded for transcription. Video uses more storage and data. Turning this off also skips video when retrying an interrupted transcription.") }
            Section("Speech") {
                Picker(selection: Binding(get: { settings.speechVoice?.identifier ?? settings.voice }, set: { settings.voice = $0 })) {
                    ForEach(voices, id: \.identifier) { voice in Text("\(voice.name) (\(voice.language == "en-GB" ? "UK" : String(voice.language.dropFirst(3))))").tag(voice.identifier) }
                } label: { Label { Text("Voice") } icon: { SettingsIcon(symbol: "waveform", color: .orange) } }.pickerStyle(.navigationLink)
                NavigationLink {
                    Form {
                        Text("Speaking Rate · \(settings.rate / Double(AVSpeechUtteranceDefaultSpeechRate), format: .number.precision(.fractionLength(1)))×")
                        Slider(value: $settings.rate, in: 0.25...0.6, step: 0.025).accessibilityLabel("Speaking Rate")
                    }.navigationTitle("Speaking Rate")
                } label: { row("Speaking Rate", value: String(format: "%.1f×", settings.rate / Double(AVSpeechUtteranceDefaultSpeechRate)), symbol: "speedometer", color: .orange) }
            }
            Section("Storage and About") {
                NavigationLink { audioForm } label: {
                    row("Downloaded Media", value: ByteCountFormatter.string(fromByteCount: downloaded.reduce(0) { $0 + AudioStore.size($1.id) }, countStyle: .file), symbol: "internaldrive", color: .gray)
                }
                NavigationLink { acknowledgments } label: { row("Acknowledgments", value: "", symbol: "book.closed", color: .gray) }
            }.id(storageRevision)
        }.navigationTitle("Settings")
            .onAppear { readKey() }
            .confirmationDialog("Delete downloaded audio, video, and transcription transfer files? The transcript and word progress are kept.", isPresented: Binding(get: { deletingAudio != nil }, set: { if !$0 { deletingAudio = nil } }), titleVisibility: .visible) {
                Button("Delete Media", role: .destructive) {
                    if let transcript = deletingAudio { do { try AudioStore.delete(transcript.id); storageRevision += 1 } catch { store.error = error.localizedDescription } }
                    deletingAudio = nil
                }
                Button("Cancel", role: .cancel) { deletingAudio = nil }
            }
    }
    private func row(_ title: String, value: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) { SettingsIcon(symbol: symbol, color: color); Text(title); Spacer(); Text(value).foregroundStyle(.secondary).lineLimit(1) }
    }
    private var providerForm: some View {
        @Bindable var settings = settings
        return Form {
            Section {
                Toggle("Enable AI Analysis", isOn: $settings.aiConsent)
                Picker("API", selection: $settings.aiAPI) { ForEach(AIProviderAPI.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) } }
                LabeledContent("Hostname") { TextField("api.openai.com", text: $settings.host).multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled() }
                LabeledContent("Base Path") { TextField("/v1", text: $settings.basePath).multilineTextAlignment(.trailing).textInputAutocapitalization(.never).autocorrectionDisabled() }
            } footer: { Text("When enabled, imported transcripts and selected sentences are sent to your configured provider for analysis. Your API key stays in this device’s Keychain. Provider charges may apply. Thinking Level controls reasoning effort, not visible chain-of-thought. Use Provider Default for models without configurable reasoning; supported levels vary and higher levels can cost more or take longer. AI output, including pronunciation, can be inaccurate.") }
        }.navigationTitle("Provider")
    }
    private var apiKeyForm: some View {
        Form {
            SecureField("API Key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
            Button("Save API Key", systemImage: "key") {
                do { let value = key.trimmingCharacters(in: .whitespacesAndNewlines); try APIKey.save(value); key = value; keyStatus = value.isEmpty ? "API key removed" : "Saved in Keychain" }
                catch { keyStatus = error.localizedDescription }
            }
            if !keyStatus.isEmpty { Text(keyStatus).font(.footnote).foregroundStyle(.secondary) }
        }.navigationTitle("API Key")
    }
    private var audioForm: some View {
        Form {
            ForEach(downloaded) { transcript in
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text(transcript.title); Text(ByteCountFormatter.string(fromByteCount: AudioStore.size(transcript.id), countStyle: .file)).font(.footnote).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Delete Media", systemImage: "trash", role: .destructive) { deletingAudio = transcript }.labelStyle(.iconOnly).buttonStyle(.borderless).frame(width: 44, height: 44).disabled(store.transcribing.contains(transcript.id) || store.downloading.contains(transcript.id))
                }
            }
            if downloaded.isEmpty { Text("No media downloaded").foregroundStyle(.secondary) }
        }.id(storageRevision).navigationTitle("Downloaded Media")
    }
    private var acknowledgments: some View {
        Form {
            Text("Vocabulary levels: CEFR-J Wordlist Version 1.6, compiled by Yukio Tono (Tokyo University of Foreign Studies, Tono Lab) and Octanove Vocabulary Profile C1/C2 Version 1.0. Variant spellings merged; duplicate senses retain the lowest level.").font(.footnote)
            Link("CEFR-J Project", destination: URL(string: "https://www.cefr-j.org/")!)
            Link("Octanove Vocabulary Profile · CC BY-SA", destination: URL(string: "https://github.com/openlanguageprofiles/olp-en-cefrj")!)
            Link("CC BY-SA 4.0 License", destination: URL(string: "https://creativecommons.org/licenses/by-sa/4.0/")!)
            Text("Transcripts via PodText and Microsoft MAI-Transcribe-2. Audio and transcripts belong to their respective publishers. Swift AI SDK by teunlao (Apache 2.0) and Alamofire (MIT).").font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("Acknowledgments")
    }
    private func readKey() {
        do { key = try APIKey.read(); keyStatus = key.isEmpty ? "No API key saved" : "In Keychain" }
        catch { keyStatus = error.localizedDescription }
    }
    @MainActor private func testConnection() async {
        testing = true; testStatus = ""; defer { testing = false }
        do { try await AIAnalyzer(settings: settings).test(); testStatus = "Connected successfully" }
        catch { testStatus = error.localizedDescription }
    }
}
