import SwiftUI
import UniformTypeIdentifiers
import PodcastCore

struct ImportView: View {
    @Environment(AppStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let onImported: (Transcript) -> Void
    @State private var mode = 0
    @State private var input = ""
    @State private var title = ""
    @State private var level = "global"
    @State private var filePicker = false
    @State private var confirmFileImport = false
    @State private var busy = false
    @State private var busyMessage = ""
    @State private var generateAudio = false
    @State private var originalText: String?
    @State private var operation: Task<Void, Never>?
    @State private var error: String?
    @State private var preview: Transcript?
    @State private var previewing = false
    @State private var findingAudio = false
    @State private var audioMessage: String?
    @State private var previewRevision = 0
    init(initialText: String, onImported: @escaping (Transcript) -> Void) {
        self.onImported = onImported
        _input = State(initialValue: initialText)
        let link = (try? EpisodeLink(initialText)) != nil || (try? BilibiliLink(initialText)) != nil
        _mode = State(initialValue: initialText.isEmpty || link ? 0 : 1)
    }
    private var isBilibili: Bool { (try? BilibiliLink(input)) != nil }
    private var validLink: Bool { isBilibili || (try? EpisodeLink(input)) != nil }
    var body: some View {
        NavigationStack {
            Form {
                Section { Picker("Input", selection: $mode) { Text("Link").tag(0); Text("Text").tag(1) }.pickerStyle(.segmented).listRowInsets(EdgeInsets()).listRowBackground(Color.clear).disabled(busy) }
                if mode == 0 {
                    Section {
                        HStack {
                            Image(systemName: "link").foregroundStyle(.secondary)
                            TextField("Apple Podcasts or Bilibili URL", text: $input).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            if !input.isEmpty { Button("Clear Link", systemImage: "xmark.circle.fill") { input = "" }.labelStyle(.iconOnly).foregroundStyle(.secondary).buttonStyle(.borderless).frame(minWidth: 44, minHeight: 44) }
                        }
                    } header: { Text("Apple Podcasts or Bilibili") } footer: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Apple Podcasts links retrieve transcripts via PodText. Bilibili audio posts (au) and videos (BV/av, including ?p=; b23.tv share links also work) download audio for Microsoft MAI-Transcribe-2.")
                            if isBilibili { Text("Audio is sent to your configured speech provider; charges may apply. Keep Learn open for transfers. Interrupted imports can be retried without losing downloaded audio.") }
                            if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !validLink {
                                Text("Use an Apple Podcasts episode (?i=…) or a full bilibili.com/audio/au… or /video/BV… link, or a b23.tv share link.").foregroundStyle(.red)
                            }
                        }
                    }
                } else {
                    Section {
                        Button("Import File", systemImage: "doc.badge.plus") {
                            if input.isEmpty && title.isEmpty && originalText == nil { filePicker = true }
                            else { confirmFileImport = true }
                        }.disabled(busy)
                        TextField("Title (Optional)", text: $title).disabled(busy)
                        TextEditor(text: $input).frame(minHeight: 200).accessibilityLabel("Transcript Text")
                            .accessibilityHint("Paste text here, or use Import File.").disabled(busy)
                    } header: { Text("Paste Text or Import a File") } footer: {
                        Text("PDF, DOC, DOCX, TXT, SRT, and VTT. PDF and Word files create a session automatically: extract text on-device → AI cleanup → audio with \(settings.ttsModel). Enable AI and save your AI and TTS keys in Settings first; charges may apply. Text files appear in the editor above. Scanned documents require OCR.")
                    }
                    Section {
                        Button("Clean Text with AI", systemImage: "sparkles") { operation = Task { await cleanText() } }
                            .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if let originalText {
                            Text("AI-cleaned text · Review for missing or changed content before importing.").font(.footnote).foregroundStyle(.secondary)
                            Button("Restore Original Text") { input = originalText; self.originalText = nil }.disabled(busy)
                        }
                    } footer: { Text("Optional for pasted text and text files. This sends text to your configured AI provider and may incur charges. Document extraction stays on-device.") }
                    Section {
                        Toggle("Generate Audio After Import", isOn: $generateAudio).disabled(busy)
                        if generateAudio {
                            Text("\(input.count.formatted()) characters will be sent to OpenRouter using \(settings.ttsModel) · \(settings.ttsVoice). Charges may apply. Review the text above first.").font(.footnote).foregroundStyle(.secondary)
                        }
                        NavigationLink("Generated Audio Settings") { SynthesisSettingsView() }.disabled(busy)
                    } footer: { Text("Generated audio is saved for offline playback and dictation. Keep PodLearn open during generation. Without generated audio, practice uses the offline system voice.") }
                }
                if mode == 0 {
                    if previewing { Section { HStack { ProgressView(); Text("Finding transcript…") } } }
                    if let preview {
                        Section {
                            HStack(spacing: 12) {
                                CoverArt(transcript: preview, size: 52)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(preview.title).font(.headline)
                                    Text([preview.author, preview.duration.map(timestamp)].compactMap { $0 }.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 6)
                            Label(isBilibili ? "Audio ready · Transcript generated after import" : "Transcript found · \(preview.orderedSegments.count) segments", systemImage: "checkmark.circle").foregroundStyle(.green)
                            if isBilibili {
                                Text(settings.keepBilibiliVideo ? "Keep video on · Only audio is uploaded" : "Audio only · No video downloaded").foregroundStyle(.secondary)
                                if !settings.transcriptionConsent { Text("Enable Audio Transcription in Settings first.").foregroundStyle(.red) }
                            }
                            HStack(spacing: 8) {
                                if findingAudio { ProgressView() } else { Image(systemName: preview.remoteAudioURL == nil ? "speaker.wave.2" : "checkmark.circle").foregroundStyle(.secondary) }
                                Text(findingAudio ? "Looking for the episode audio…" : audioMessage ?? "Episode audio found").foregroundStyle(.secondary)
                            }
                            Label("Words at \(level == "global" ? settings.targetLevel : level) and above will be marked", systemImage: "text.badge.checkmark").foregroundStyle(.secondary)
                        }.font(.subheadline)
                    }
                }
                Section("This Transcript") {
                    Picker("Target Level", selection: $level) {
                        Text("Use Global (\(settings.targetLevel))").tag("global")
                        ForEach(CEFR.allCases, id: \.rawValue) { Text($0.rawValue + " and above").tag($0.rawValue) }
                    }
                }
                if isBilibili && mode == 0 {
                    Section { NavigationLink("Audio Transcription Settings") { TranscriptionSettingsView() } }
                }
                if busy { Section { HStack { ProgressView(); Text(busyMessage) }; if operation != nil { Button("Cancel") { operation?.cancel() } } } }
                if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
                Section { Text(settings.aiConsent ? "After import, this transcript is sent to your AI provider for key sentences and Chinese glosses." : "Offline vocabulary marking is ready. Enable AI in Settings for key sentences and Chinese glosses.").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("New Transcript").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { RoundButton(title: "Close", symbol: "xmark") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button(mode != 0 && generateAudio ? "Import & Generate" : "Import") { Task { await importContent() } }.fontWeight(.semibold).buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy || (mode == 0 && preview == nil)) }
            }
            .confirmationDialog("Replace This Draft?", isPresented: $confirmFileImport, titleVisibility: .visible) {
                Button("Import File") { filePicker = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A text file replaces the editor contents. A PDF or Word file starts a new session. Your current draft is not saved.")
            }
            .fileImporter(isPresented: $filePicker, allowedContentTypes: [.pdf, UTType(importedAs: "com.microsoft.word.doc"), UTType(importedAs: "org.openxmlformats.wordprocessingml.document"), .plainText, UTType(filenameExtension: "srt") ?? .plainText, UTType(filenameExtension: "vtt") ?? .plainText]) { result in
                do {
                    let url = try result.get()
                    if DocumentTextImporter.supports(url) {
                        let transcript = try store.importDocument(url, level: level == "global" ? nil : level)
                        dismiss(); onImported(transcript)
                    } else { operation = Task { await loadFile(url) } }
                } catch { self.error = error.localizedDescription }
            }
            .task(id: "\(mode):\(input):\(previewRevision)") { await loadPreview() }
            .interactiveDismissDisabled(busy)
            .overlay(alignment: .bottom) {
                if mode == 0 && !previewing && preview == nil && error != nil {
                    Button("Retry Preview", systemImage: "arrow.clockwise") { previewRevision += 1 }.buttonStyle(.bordered).padding()
                }
            }
        }.presentationDragIndicator(.visible)
    }
    @MainActor private func loadFile(_ url: URL) async {
        busy = true; busyMessage = "Extracting text…"; error = nil
        defer { busy = false; operation = nil }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let extraction = Task.detached(priority: .userInitiated) {
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 5_000_000 else { throw ImportError.tooLarge }
                let data = try Data(contentsOf: url)
                guard data.count <= 5_000_000 else { throw ImportError.tooLarge }
                guard let text = String(data: data, encoding: .utf8) else { throw ImportError.service("Choose a UTF-8 text file.") }
                if ["srt", "vtt"].contains(url.pathExtension.lowercased()) {
                    return try TextImporter.paragraphs(text, fileExtension: url.pathExtension).joined(separator: "\n\n")
                }
                return text
            }
            let text = try await withTaskCancellationHandler { try await extraction.value } onCancel: { extraction.cancel() }
            try Task.checkCancellation()
            input = text; title = url.deletingPathExtension().lastPathComponent
            originalText = nil
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    @MainActor private func cleanText() async {
        busy = true; busyMessage = "Cleaning text…"; error = nil
        defer { busy = false; operation = nil }
        let source = input
        do {
            let cleaned = try await AIAnalyzer(settings: settings).cleanText(source)
            try Task.checkCancellation()
            if originalText == nil { originalText = source }
            input = cleaned.joined(separator: "\n\n")
        } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    @MainActor private func loadPreview() async {
        preview = nil; audioMessage = nil; error = nil; previewing = false; findingAudio = false
        guard mode == 0, validLink else { return }
        do {
            try await Task.sleep(for: .milliseconds(500)); try Task.checkCancellation()
            previewing = true
            let fetched = isBilibili ? try await store.bilibiliPreview(input) : try await store.podcastPreview(input)
            try Task.checkCancellation()
            preview = fetched; previewing = false
            if isBilibili { audioMessage = "Bilibili audio found"; return }
            findingAudio = true
            do {
                let link = try EpisodeLink(input)
                let audio = try await AudioResolver.resolve(link, title: fetched.title)
                try Task.checkCancellation()
                fetched.remoteAudioURL = audio?.url.absoluteString; fetched.audioDuration = audio?.duration
                audioMessage = audio == nil ? "Audio unavailable · Text to speech is ready" : "Episode audio found"
            } catch {
                if Task.isCancelled { return }
                audioMessage = "Audio lookup can be retried in the reader."
            }
            findingAudio = false
        } catch {
            guard !Task.isCancelled else { return }
            previewing = false; self.error = error.localizedDescription
        }
    }
    @MainActor private func importContent() async {
        busy = true; busyMessage = mode == 0 ? "Fetching transcript…" : "Marking vocabulary…"; store.importing = true; error = nil
        defer { busy = false; store.importing = false }
        do {
            let transcript: Transcript
            if mode == 0 && isBilibili { transcript = try await store.importBilibili(input, level: level == "global" ? nil : level, preview: preview) }
            else if mode == 0 { transcript = try await store.importPodcast(input, level: level == "global" ? nil : level, preview: preview) }
            else { transcript = try store.importText(input, title: title, level: level == "global" ? nil : level, generateAudio: generateAudio) }
            dismiss(); onImported(transcript)
        } catch { self.error = error.localizedDescription }
    }
}
