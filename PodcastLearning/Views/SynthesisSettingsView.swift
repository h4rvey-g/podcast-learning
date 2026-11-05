import SwiftUI
import AVFoundation
import PodcastCore

struct SynthesisSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(ClipPlayer.self) private var clipPlayer
    @State private var key = ""
    @State private var confirmOpenRouter = false
    @State private var status = ""
    @State private var models: [SpeechCatalog.Model] = []
    @State private var voices: [SpeechCatalog.Voice] = []
    @State private var loading = false
    @State private var catalogError = ""
    @State private var refresh = 0
    @State private var preview = AVPlayer()
    @State private var previewing: String?
    @State private var previewError = ""
    @State private var previewObservation: NSKeyValueObservation?
    private var appleVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en-") }.sorted { $0.name < $1.name }
    }
    private var selectedModel: SpeechCatalog.Model? { models.first { $0.id == settings.ttsModel } }
    private var supportedVoices: [String] { Array(Set(selectedModel?.supportedVoices ?? [])).sorted() }
    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Picker("Service", selection: Binding(get: { settings.speechService }, set: { service in
                    if service == .openRouter { confirmOpenRouter = true } else { settings.speechService = service }
                })) {
                    ForEach(SpeechService.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            }
            if settings.speechService == .apple {
                Section {
                    Picker("Voice", selection: Binding(get: { settings.speechVoice?.identifier ?? settings.voice }, set: { settings.voice = $0 })) {
                        ForEach(appleVoices, id: \.identifier) { Text("\($0.name) (\($0.language))").tag($0.identifier) }
                    }.pickerStyle(.navigationLink)
                    Text("Speaking Rate · \(settings.rate / Double(AVSpeechUtteranceDefaultSpeechRate), format: .number.precision(.fractionLength(1)))×")
                    Slider(value: $settings.rate, in: 0.25...0.6, step: 0.025).accessibilityLabel("Speaking Rate")
                    Button("Play Sample", systemImage: "play.fill") {
                        clipPlayer.play(text: "Welcome to PodLearn. Listen, learn, and practice at your own pace.", settings: settings)
                    }
                }
            } else {
                Section("API Key") {
                    SecureField("OpenRouter API Key", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Save API Key") {
                        do {
                            try APIKey.save(key.trimmingCharacters(in: .whitespacesAndNewlines), account: "openRouterTTS")
                            key = ""; readStatus()
                        } catch { status = error.localizedDescription }
                    }
                    if !status.isEmpty { Text(status).foregroundStyle(.secondary) }
                }
                Section("ElevenLabs") {
                    Picker("Model", selection: $settings.ttsModel) {
                        if selectedModel == nil { Text(settings.ttsModel).tag(settings.ttsModel) }
                        ForEach(models) { Text($0.name).tag($0.id) }
                    }.pickerStyle(.navigationLink)
                    NavigationLink {
                        voiceList
                    } label: {
                        LabeledContent("Voice", value: voiceName(settings.ttsVoice))
                    }
                    Button("Refresh Models and Voices", systemImage: "arrow.clockwise") { refresh += 1 }.disabled(loading)
                    if loading { ProgressView("Loading Models and Voices…") }
                    if !catalogError.isEmpty { Text(catalogError).foregroundStyle(.secondary) }
                }
            }
        }.navigationTitle("Speech")
            .confirmationDialog("Use OpenRouter Speech?", isPresented: $confirmOpenRouter, titleVisibility: .visible) {
                Button("Use OpenRouter") { settings.speechService = .openRouter }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Text you play or import is sent to OpenRouter and ElevenLabs for speech generation. Charges may apply. Voice samples use public recordings and are free to preview.")
            }
            .onAppear { clipPlayer.stop(); readStatus() }
            .task(id: "\(settings.speechService.rawValue)|\(refresh)") {
                if settings.speechService == .openRouter { await loadCatalog() }
            }
            .onChange(of: settings.speechService) { _, _ in stopPreview(); clipPlayer.stop() }
            .onChange(of: settings.ttsModel) { _, _ in
                stopPreview()
                // Only an explicit model change replaces an unsupported voice; refresh preserves saved IDs.
                if let first = supportedVoices.first, !supportedVoices.contains(settings.ttsVoice) { settings.ttsVoice = first }
            }
            .onDisappear { stopPreview(); clipPlayer.stop() }
    }
    private var voiceList: some View {
        List {
            if !supportedVoices.contains(settings.ttsVoice) {
                LabeledContent("Saved Voice", value: settings.ttsVoice)
            }
            if supportedVoices.isEmpty { Text("No supported voices loaded. Refresh Models and Voices in Speech.").foregroundStyle(.secondary) }
            if !previewError.isEmpty { Text(previewError).foregroundStyle(.secondary) }
            ForEach(supportedVoices, id: \.self) { voice in
                HStack {
                    Button { settings.ttsVoice = voice } label: {
                        HStack {
                            Text(voiceName(voice)).foregroundStyle(.primary)
                            Spacer()
                            if settings.ttsVoice == voice { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }.contentShape(Rectangle())
                    }.buttonStyle(.borderless).accessibilityAddTraits(settings.ttsVoice == voice ? .isSelected : [])
                    Button {
                        playSample(voice)
                    } label: {
                        Image(systemName: previewing == voice ? "stop.fill" : "play.fill").frame(width: 44, height: 44)
                    }.buttonStyle(.borderless)
                        .disabled(sampleURL(voice) == nil)
                        .accessibilityLabel("\(previewing == voice ? "Stop" : "Play") \(voiceName(voice)) Sample")
                        .accessibilityHint(sampleURL(voice) == nil ? "Sample unavailable. Refresh Models and Voices to try again." : "")
                }
            }
        }.navigationTitle("Voice")
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { note in
                if let item = note.object as? AVPlayerItem, item === preview.currentItem { stopPreview() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemFailedToPlayToEndTime)) { note in
                if let item = note.object as? AVPlayerItem, item === preview.currentItem {
                    stopPreview(); previewError = "Could not play this sample. Refresh Models and Voices, then try again."
                }
            }
            .onDisappear { stopPreview() }
    }
    private func voiceName(_ voice: String) -> String { voices.first { $0.matches(voice) }?.name ?? voice.capitalized }
    private func sampleURL(_ voice: String) -> URL? { voices.first { $0.matches(voice) }?.sampleURL }
    private func stopPreview() { previewObservation = nil; preview.pause(); preview.replaceCurrentItem(with: nil); previewing = nil }
    private func playSample(_ voice: String) {
        if previewing == voice { stopPreview(); return }
        stopPreview(); previewError = ""
        guard let url = sampleURL(voice) else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let item = AVPlayerItem(url: url)
            previewObservation = item.observe(\.status, options: [.new]) { item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor in
                    guard preview.currentItem === item else { return }
                    stopPreview(); previewError = "Could not play this sample. Refresh Models and Voices, then try again."
                }
            }
            preview.replaceCurrentItem(with: item); previewing = voice; preview.play()
        } catch { previewError = error.localizedDescription }
    }
    @MainActor private func loadCatalog() async {
        loading = true; catalogError = ""; defer { loading = false }
        do {
            let available = try await SpeechCatalog.models()
            try Task.checkCancellation()
            models = available
            if available.isEmpty { catalogError = "No ElevenLabs speech models returned. Refresh to try again." }
        } catch { if !Task.isCancelled { catalogError = "Could not load speech models. Refresh to try again." } }
        guard !Task.isCancelled else { return }
        do {
            let available = try await SpeechCatalog.voices()
            try Task.checkCancellation()
            voices = available
        } catch { if !Task.isCancelled { catalogError += (catalogError.isEmpty ? "" : "\n") + "Could not load voice samples. Refresh to try again." } }
    }
    private func readStatus() {
        do { status = try APIKey.read(account: "openRouterTTS").isEmpty ? "No API key saved" : "API key saved" }
        catch { status = error.localizedDescription }
    }
}
