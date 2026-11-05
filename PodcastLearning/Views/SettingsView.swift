import SwiftUI
import SwiftData
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
    private var downloaded: [Transcript] { transcripts.filter { AudioStore.size($0.id) > 0 } }
    var body: some View {
        @Bindable var settings = settings
        Form {
            Section("Appearance") {
                Picker(selection: $settings.accentTheme) {
                    ForEach(AccentTheme.allCases, id: \.self) { theme in
                        Label { Text(theme.label) } icon: { Image(systemName: "circle.fill").foregroundStyle(theme.color) }.tag(theme)
                    }
                } label: {
                    Label { Text("Accent Theme") } icon: { SettingsIcon(symbol: "paintpalette", color: settings.accentTheme.color) }
                }.pickerStyle(.navigationLink)
            }
            Section {
                Picker(selection: $settings.targetLevel) { ForEach(CEFR.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) } } label: {
                    Label { Text("Target Level") } icon: { SettingsIcon(symbol: "gauge.with.dots.needle.50percent") }
                }.pickerStyle(.navigationLink)
            } header: { Text("Learning") }
            Section {
                NavigationLink { providerForm } label: { row("Provider", value: settings.baseURL, symbol: "server.rack", color: .indigo) }
                NavigationLink { ModelSettingsView() } label: { row("Model", value: settings.model, symbol: "cpu", color: .indigo) }
                Picker(selection: $settings.thinking) {
                    ForEach(ThinkingLevel.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) }
                } label: { Label { Text("Thinking Level") } icon: { SettingsIcon(symbol: "brain", color: .indigo) } }.pickerStyle(.navigationLink)
                Button { Task { await testConnection() } } label: {
                    HStack { SettingsIcon(symbol: "cable.connector", color: .cyan); Text("Test Connection"); Spacer(); if testing { ProgressView() } }
                }.disabled(testing)
                if !testStatus.isEmpty { Text(testStatus).font(.footnote).foregroundStyle(.secondary) }
            } header: { Text("AI") }
            Section {
                NavigationLink { TranscriptionSettingsView() } label: { row("Audio Transcription", value: settings.transcriptionConsent ? "MAI-Transcribe-2" : "Off", symbol: "waveform.badge.mic", color: .indigo) }
                Toggle("Keep Bilibili Video", isOn: $settings.keepBilibiliVideo)
            } header: { Text("Bilibili Imports") }
            Section {
                NavigationLink { SynthesisSettingsView() } label: { row("Speech", value: settings.speechService.label, symbol: "waveform", color: .orange) }
            }
            Section("Storage and About") {
                NavigationLink { audioForm } label: {
                    row("Downloaded Media", value: ByteCountFormatter.string(fromByteCount: downloaded.reduce(0) { $0 + AudioStore.size($1.id) }, countStyle: .file), symbol: "internaldrive", color: .gray)
                }
                NavigationLink { acknowledgments } label: { row("Acknowledgments", value: "", symbol: "book.closed", color: .gray) }
            }.id(storageRevision)
        }.navigationTitle("Settings")
            .onAppear { readKey() }
            .confirmationDialog("Delete downloaded media and document processing files? Saved text and word progress are kept. Unfinished document sessions will need the original file imported again.", isPresented: Binding(get: { deletingAudio != nil }, set: { if !$0 { deletingAudio = nil } }), titleVisibility: .visible) {
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
                VStack(alignment: .leading) {
                    Text("Base URL")
                    TextField("https://api.openai.com/v1", text: $settings.baseURL)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityLabel("Base URL")
                }
                SecureField("API Key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save API Key", systemImage: "key") {
                    do { let value = key.trimmingCharacters(in: .whitespacesAndNewlines); try APIKey.save(value); key = value; keyStatus = value.isEmpty ? "API key removed" : "Saved in Keychain" }
                    catch { keyStatus = error.localizedDescription }
                }
                if !keyStatus.isEmpty { Text(keyStatus).font(.footnote).foregroundStyle(.secondary) }
            }
        }.navigationTitle("Provider")
    }
    private var audioForm: some View {
        Form {
            ForEach(downloaded) { transcript in
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text(transcript.title); Text(ByteCountFormatter.string(fromByteCount: AudioStore.size(transcript.id), countStyle: .file)).font(.footnote).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Delete Media", systemImage: "trash", role: .destructive) { deletingAudio = transcript }.labelStyle(.iconOnly).buttonStyle(.borderless).frame(width: 44, height: 44).disabled(store.transcribing.contains(transcript.id) || store.downloading.contains(transcript.id) || store.synthesizing.contains(transcript.id))
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
            Text("Transcripts via PodText and Microsoft MAI-Transcribe-2. Audio and transcripts belong to their respective publishers. Swift AI SDK by teunlao (Apache 2.0), Alamofire (MIT), and ZIPFoundation (MIT).").font(.footnote).foregroundStyle(.secondary)
            NavigationLink("ZIPFoundation · MIT License") {
                ScrollView {
                    Text("""
                        MIT License

                        Copyright (c) 2017-2025 Thomas Zoechling (https://www.peakstep.com)

                        Permission is hereby granted, free of charge, to any person obtaining a copy
                        of this software and associated documentation files (the "Software"), to deal
                        in the Software without restriction, including without limitation the rights
                        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
                        copies of the Software, and to permit persons to whom the Software is
                        furnished to do so, subject to the following conditions:

                        The above copyright notice and this permission notice shall be included in all
                        copies or substantial portions of the Software.

                        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
                        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
                        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
                        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
                        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
                        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
                        SOFTWARE.
                        """).font(.footnote).textSelection(.enabled).padding()
                }.navigationTitle("ZIPFoundation")
            }
        }.navigationTitle("Acknowledgments")
    }
    private func readKey() {
        do { key = try APIKey.read(); keyStatus = key.isEmpty ? "No API key saved" : "In Keychain" }
        catch { keyStatus = error.localizedDescription }
    }
    @MainActor private func testConnection() async {
        testing = true; testStatus = ""; defer { testing = false }
        do { try await AIAnalyzer(settings: settings).test(); testStatus = "Connected successfully. Model access checked with provider-default thinking (15-second limit); your selected thinking level is not tested." }
        catch { testStatus = error.localizedDescription }
    }
}

private struct ModelSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var models: [String] = []
    @State private var loading = false
    @State private var error = ""
    @State private var customModel = ""
    @State private var refresh = 0
    private var customID: String { customModel.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        Form {
            Section("Selected Model") { Text(settings.model).textSelection(.enabled) }
            Section {
                TextField("Model ID", text: $customModel)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Custom Model ID")
                Button("Add Custom Model") {
                    let id = customID
                    if !settings.customModels.contains(id) { settings.customModels.append(id) }
                    settings.model = id; customModel = ""
                }.disabled(customID.isEmpty)
            } header: { Text("Custom Model") }
            if !settings.customModels.isEmpty {
                Section("Custom Models") {
                    ForEach(settings.customModels, id: \.self) { model in modelRow(model) }
                }
            }
            Section {
                if loading { ProgressView("Loading Models…") }
                if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(.secondary) }
                if !loading && error.isEmpty && models.isEmpty { Text("No models returned. You can still add a custom model.").foregroundStyle(.secondary) }
                ForEach(models, id: \.self) { model in modelRow(model) }
                Button("Refresh Models", systemImage: "arrow.clockwise") { refresh += 1 }.disabled(loading)
            } header: { Text("Available Models") }
        }.navigationTitle("Model")
            .task(id: "\(settings.aiAPI)|\(settings.baseURL)|\(refresh)") { await loadModels() }
    }
    private func modelRow(_ model: String) -> some View {
        Button { settings.model = model } label: {
            HStack {
                Text(model).foregroundStyle(.primary)
                Spacer()
                if settings.model == model { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
        }.accessibilityAddTraits(settings.model == model ? .isSelected : [])
    }
    @MainActor private func loadModels() async {
        loading = true; error = ""; models = []; defer { loading = false }
        do {
            let available = try await AIAnalyzer(settings: settings).availableModels()
            try Task.checkCancellation()
            models = available
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
