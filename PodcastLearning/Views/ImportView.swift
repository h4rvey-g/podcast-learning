import SwiftUI
import UniformTypeIdentifiers
import PodcastCore

struct ImportView: View {
    @Environment(AppStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(\.dismiss) private var dismiss
    let initialText: String
    let onImported: (Transcript) -> Void
    @State private var mode = 0
    @State private var input = ""
    @State private var title = ""
    @State private var level = "global"
    @State private var fileExtension = "txt"
    @State private var filePicker = false
    @State private var busy = false
    @State private var error: String?
    @State private var preview: Transcript?
    @State private var previewing = false
    @State private var findingAudio = false
    @State private var audioMessage: String?
    @State private var previewRevision = 0
    var body: some View {
        NavigationStack {
            Form {
                Section { Picker("Input", selection: $mode) { Text("Podcast Link").tag(0); Text("Text").tag(1); Text("File").tag(2) }.pickerStyle(.segmented).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                if mode == 0 {
                    Section {
                        HStack {
                            Image(systemName: "link").foregroundStyle(.secondary)
                            TextField("https://podcasts.apple.com/…?i=…", text: $input).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            if !input.isEmpty { Button("Clear Link", systemImage: "xmark.circle.fill") { input = "" }.labelStyle(.iconOnly).foregroundStyle(.secondary).buttonStyle(.borderless).frame(minWidth: 44, minHeight: 44) }
                        }
                    } header: { Text("Apple Podcasts Episode") } footer: {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("In Podcasts, tap Share › Learn to import without copying the link. The episode link is sent to PodText to retrieve its transcript.")
                            if !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (try? EpisodeLink(input)) == nil {
                                Text("Use an Apple Podcasts episode link containing ?i=…, not a show link.").foregroundStyle(.red)
                            }
                        }
                    }
                } else {
                    Section {
                        TextField("Title (Optional)", text: $title)
                        if mode == 2 { Button("Choose TXT, SRT, or VTT File", systemImage: "doc") { filePicker = true } }
                        TextEditor(text: $input).frame(minHeight: 200).accessibilityLabel("Transcript Text")
                    } header: { Text(mode == 1 ? "English Transcript" : "Transcript File") }
                    Text("Without podcast audio, dictation uses your selected English voice.").font(.footnote).foregroundStyle(.secondary)
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
                            Label("Transcript found · \(preview.orderedSegments.count) segments", systemImage: "checkmark.circle").foregroundStyle(.green)
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
                if busy { Section { HStack { ProgressView(); Text(mode == 0 ? "Fetching transcript…" : "Marking vocabulary…") } } }
                if let error { Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
                Section { Text(settings.aiConsent ? "After import, this transcript is sent to your AI provider for key sentences and Chinese glosses." : "Offline vocabulary marking is ready. Enable AI in Settings for key sentences and Chinese glosses.").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle("New Transcript").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { RoundButton(title: "Close", symbol: "xmark") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Import") { Task { await importContent() } }.fontWeight(.semibold).buttonStyle(.borderedProminent).buttonBorderShape(.capsule).disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy || (mode == 0 && preview == nil)) }
            }
            .fileImporter(isPresented: $filePicker, allowedContentTypes: [.plainText, UTType(filenameExtension: "srt") ?? .plainText, UTType(filenameExtension: "vtt") ?? .plainText]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 5_000_000 else { throw ImportError.tooLarge }
                    let data = try Data(contentsOf: url)
                    guard data.count <= 5_000_000 else { throw ImportError.tooLarge }
                    guard let text = String(data: data, encoding: .utf8) else { throw ImportError.service("Choose a UTF-8 text file.") }
                    input = text; title = url.deletingPathExtension().lastPathComponent; fileExtension = url.pathExtension
                } catch { self.error = error.localizedDescription }
            }
            .onAppear { if !initialText.isEmpty { input = initialText } }
            .task(id: "\(mode):\(input):\(previewRevision)") { await loadPreview() }
            .interactiveDismissDisabled(busy)
            .overlay(alignment: .bottom) {
                if mode == 0 && !previewing && preview == nil && error != nil {
                    Button("Retry Preview", systemImage: "arrow.clockwise") { previewRevision += 1 }.buttonStyle(.bordered).padding()
                }
            }
        }.presentationDragIndicator(.visible)
    }
    @MainActor private func loadPreview() async {
        preview = nil; audioMessage = nil; error = nil; previewing = false; findingAudio = false
        guard mode == 0, (try? EpisodeLink(input)) != nil else { return }
        do {
            try await Task.sleep(for: .milliseconds(500)); try Task.checkCancellation()
            previewing = true
            let fetched = try await store.podcastPreview(input)
            try Task.checkCancellation()
            preview = fetched; previewing = false; findingAudio = true
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
        busy = true; store.importing = true; error = nil
        defer { busy = false; store.importing = false }
        do {
            let transcript: Transcript
            if mode == 0 { transcript = try await store.importPodcast(input, level: level == "global" ? nil : level, preview: preview) }
            else { transcript = try store.importText(input, title: title, fileExtension: mode == 2 ? fileExtension : "txt", level: level == "global" ? nil : level) }
            dismiss(); onImported(transcript)
        } catch { self.error = error.localizedDescription }
    }
}
