import SwiftUI
import UniformTypeIdentifiers
import PodcastCore

struct ImportView: View {
    private enum TextSource: String, CaseIterable {
        case paste = "Paste Text", file = "Import File"
        var symbol: String { self == .paste ? "text.cursor" : "doc.badge.arrow.up" }
    }
    private struct SelectedFile {
        let url: URL
        let size: Int
        let accessing: Bool
        func release() { if accessing { url.stopAccessingSecurityScopedResource() } }
    }
    @Environment(\.accentTheme) private var theme
    @Environment(AppStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let onImported: (Transcript) -> Void
    @State private var mode = 0
    @State private var link = ""
    @State private var text = ""
    @State private var title = ""
    @State private var textSource = TextSource.paste
    @State private var selectedFile: SelectedFile?
    @State private var level = "global"
    @State private var filePicker = false
    @State private var busy = false
    @State private var error: String?
    @State private var preview: Transcript?
    @State private var previewing = false
    @State private var findingAudio = false
    @State private var audioMessage: String?
    @State private var previewRevision = 0
    init(initialText: String, onImported: @escaping (Transcript) -> Void) {
        self.onImported = onImported
        let isLink = (try? EpisodeLink(initialText)) != nil || (try? BilibiliLink(initialText)) != nil
        _link = State(initialValue: isLink ? initialText : "")
        _text = State(initialValue: isLink ? "" : initialText)
        _mode = State(initialValue: initialText.isEmpty || isLink ? 0 : 1)
    }
    private var isBilibili: Bool { (try? BilibiliLink(link)) != nil }
    private var usesSTT: Bool { isBilibili || settings.podcastTranscription == .stt }
    private var validLink: Bool { isBilibili || (try? EpisodeLink(link)) != nil }
    private var canImport: Bool {
        guard !busy else { return false }
        if mode == 0 { return validLink && preview != nil }
        return textSource == .file ? selectedFile != nil : !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        NavigationStack {
            Form {
                Section { Picker("Input", selection: $mode) { Text("Link").tag(0); Text("Text").tag(1) }.pickerStyle(.segmented).listRowInsets(EdgeInsets()).listRowBackground(Color.clear).disabled(busy) }
                if mode == 0 {
                    Section {
                        HStack {
                            Image(systemName: "link").foregroundStyle(.secondary)
                            TextField("Apple Podcasts or Bilibili URL", text: $link).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            if !link.isEmpty { Button("Clear Link", systemImage: "xmark.circle.fill") { link = "" }.labelStyle(.iconOnly).foregroundStyle(.secondary).buttonStyle(.borderless).frame(minWidth: 44, minHeight: 44) }
                        }.disabled(busy)
                    } header: { Text("Apple Podcasts or Bilibili") } footer: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(settings.podcastTranscription == .podText
                                 ? "Apple Podcasts links retrieve transcripts via PodText. Bilibili links download audio for speech to text."
                                 : "Apple Podcasts and Bilibili links download audio for speech to text.")
                            if usesSTT { Text("Audio is sent to your configured speech provider; charges may apply. Keep PodLearn open for transfers. Interrupted imports can be retried without losing downloaded audio.") }
                            if !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !validLink {
                                Text("Use an Apple Podcasts episode (?i=…) or a full bilibili.com/audio/au… or /video/BV… link, or a b23.tv share link.").foregroundStyle(.red)
                            }
                        }
                    }
                } else {
                    Section("Choose One Source") {
                        HStack(spacing: 10) {
                            ForEach(TextSource.allCases, id: \.self) { source in sourceButton(source) }
                        }
                        .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    }
                    if textSource == .paste {
                        Section("Paste Text") {
                            TextField("Title (Optional)", text: $title).disabled(busy)
                            TextEditor(text: $text).frame(minHeight: 200).accessibilityLabel("Transcript Text")
                                .accessibilityHint("Paste the text you want to import.").disabled(busy)
                        }
                    } else {
                        Section(selectedFile == nil ? "Import File" : "Selected File") {
                            if let selectedFile {
                                HStack(spacing: 12) {
                                    Image(systemName: "doc.text").font(.title2).foregroundStyle(theme.color)
                                        .frame(width: 44, height: 52).background(theme.color.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(selectedFile.url.lastPathComponent).font(.headline)
                                        Text("\(selectedFile.url.pathExtension.uppercased()) document · \(ByteCountFormatter.string(fromByteCount: Int64(selectedFile.size), countStyle: .file))")
                                            .font(.footnote).foregroundStyle(.secondary)
                                    }
                                }.padding(.vertical, 4).accessibilityElement(children: .combine)
                            }
                            Button(selectedFile == nil ? "Choose File" : "Change File", systemImage: "folder") { filePicker = true }.disabled(busy)
                        }
                    }
                }
                if mode == 0 {
                    if previewing { Section { HStack { ProgressView(); Text(usesSTT ? "Finding episode audio…" : "Finding transcript…") } } }
                    if let preview {
                        Section {
                            HStack(spacing: 12) {
                                CoverArt(transcript: preview, size: 52)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(preview.title).font(.headline)
                                    Text([preview.author, preview.duration.map(timestamp)].compactMap { $0 }.joined(separator: " · ")).font(.footnote).foregroundStyle(.secondary)
                                }
                            }.padding(.vertical, 6)
                            Label(usesSTT ? "Audio ready · Transcript generated after import" : "Transcript found · \(preview.orderedSegments.count) segments", systemImage: "checkmark.circle").foregroundStyle(.green)
                            if isBilibili {
                                Text(settings.keepBilibiliVideo ? "Keep video on · Only audio is uploaded" : "Audio only · No video downloaded").foregroundStyle(.secondary)
                            }
                            if usesSTT && !settings.transcriptionConsent { Text("Enable Audio Transcription in Settings first.").foregroundStyle(.red) }
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
                    }.disabled(busy)
                }
                if usesSTT && mode == 0 {
                    Section { NavigationLink("Audio Transcription Settings") { TranscriptionSettingsView() } }
                }
                if busy { Section { HStack { ProgressView(); Text("Importing transcript…") } } }
                if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
                Section {
                    Text(settings.aiConsent ? "After import, this transcript is sent to your AI provider for key sentences and Chinese glosses." : mode == 0 ? "Offline vocabulary marking is ready. Enable AI in Settings for key sentences and Chinese glosses." : "Enable AI in Settings for automatic text cleanup, key sentences, and Chinese glosses.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New Transcript").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { RoundButton(title: "Close", symbol: "xmark") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Import") { Task { await importContent() } }.fontWeight(.semibold).buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(!canImport) }
            }
            .fileImporter(isPresented: $filePicker, allowedContentTypes: [.pdf, UTType(importedAs: "com.microsoft.word.doc"), UTType(importedAs: "org.openxmlformats.wordprocessingml.document"), .plainText, UTType(filenameExtension: "srt") ?? .plainText, UTType(filenameExtension: "vtt") ?? .plainText]) { result in
                switch result {
                case .success(let url): selectFile(url)
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { self.error = error.localizedDescription }
                }
            }
            .task(id: "\(mode):\(link):\(settings.podcastTranscription.rawValue):\(previewRevision)") { await loadPreview() }
            .onChange(of: textSource) { _, _ in error = nil }
            .interactiveDismissDisabled(busy)
            .overlay(alignment: .bottom) {
                if mode == 0 && !previewing && preview == nil && error != nil {
                    Button("Retry Preview", systemImage: "arrow.clockwise") { previewRevision += 1 }.buttonStyle(.bordered).padding()
                }
            }
        }.presentationDragIndicator(.visible)
            .onDisappear { selectedFile?.release(); selectedFile = nil }
    }
    private func sourceButton(_ source: TextSource) -> some View {
        let selected = textSource == source
        return Button { textSource = source } label: {
            HStack(spacing: 8) {
                Image(systemName: source.symbol)
                Text(source.rawValue).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle" : "circle")
            }
            .foregroundStyle(selected ? theme.color : .primary)
            .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 60)
            .background(selected ? theme.color.opacity(0.1) : Palette.cell, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? theme.color : Color(uiColor: .separator), lineWidth: selected ? 1.5 : 0.5))
        }.buttonStyle(.plain).disabled(busy)
            .accessibilityElement(children: .ignore).accessibilityLabel(source.rawValue)
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
    private func selectFile(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        do {
            guard DocumentTextImporter.supports(url) else { throw ImportError.service("Choose a PDF, DOC, DOCX, TXT, SRT, or VTT file.") }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { throw ImportError.service("Choose a file, not a folder.") }
            guard (values.fileSize ?? 0) <= 5_000_000 else { throw ImportError.tooLarge }
            selectedFile?.release()
            // Keep provider access until Import stages a local copy or this sheet closes.
            selectedFile = SelectedFile(url: url, size: values.fileSize ?? 0, accessing: access)
            error = nil
        } catch {
            if access { url.stopAccessingSecurityScopedResource() }
            self.error = error.localizedDescription
        }
    }
    @MainActor private func loadPreview() async {
        preview = nil; audioMessage = nil; error = nil; previewing = false; findingAudio = false
        guard mode == 0, validLink else { return }
        do {
            try await Task.sleep(for: .milliseconds(500)); try Task.checkCancellation()
            previewing = true
            let fetched = isBilibili ? try await store.bilibiliPreview(link) : try await store.podcastPreview(link)
            try Task.checkCancellation()
            preview = fetched; previewing = false
            if usesSTT { audioMessage = isBilibili ? "Bilibili audio found" : "Episode audio found"; return }
            findingAudio = true
            do {
                let episode = try EpisodeLink(link)
                let audio = try await AudioResolver.resolve(episode, title: fetched.title)
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
        guard canImport else { return }
        busy = true; store.importing = true; error = nil
        defer { busy = false; store.importing = false }
        do {
            let transcript: Transcript
            let target = level == "global" ? nil : level
            if mode == 0 && isBilibili { transcript = try await store.importBilibili(link, level: target, preview: preview) }
            else if mode == 0 { transcript = try await store.importPodcast(link, level: target, preview: preview) }
            else if textSource == .file, let selectedFile { transcript = try store.importDocument(selectedFile.url, level: target) }
            else { transcript = try store.importText(text, title: title, level: target) }
            dismiss(); onImported(transcript)
        } catch { self.error = error.localizedDescription }
    }
}
