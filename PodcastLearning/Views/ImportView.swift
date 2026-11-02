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
    var body: some View {
        NavigationStack {
            Form {
                Section { Picker("Input", selection: $mode) { Text("Podcast Link").tag(0); Text("Text").tag(1); Text("File").tag(2) }.pickerStyle(.segmented).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                if mode == 0 {
                    Section {
                        TextField("https://podcasts.apple.com/…?i=…", text: $input).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    } header: { Text("Apple Podcasts Episode") } footer: { Text("In Podcasts, tap Share › Learn to import without copying the link. The episode link is sent to PodText to retrieve its transcript.") }
                } else {
                    Section {
                        TextField("Title (Optional)", text: $title)
                        if mode == 2 { Button("Choose TXT, SRT, or VTT File", systemImage: "doc") { filePicker = true } }
                        TextEditor(text: $input).frame(minHeight: 200).accessibilityLabel("Transcript Text")
                    } header: { Text(mode == 1 ? "English Transcript" : "Transcript File") }
                    Text("Without podcast audio, dictation uses your selected English voice.").font(.footnote).foregroundStyle(.secondary)
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
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Import") { Task { await importContent() } }.fontWeight(.semibold).disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy) }
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
            .interactiveDismissDisabled(busy)
        }.presentationDragIndicator(.visible)
    }
    @MainActor private func importContent() async {
        busy = true; store.importing = true; error = nil
        defer { busy = false; store.importing = false }
        do {
            let transcript: Transcript
            if mode == 0 { transcript = try await store.importPodcast(input, level: level == "global" ? nil : level) }
            else { transcript = try store.importText(input, title: title, fileExtension: mode == 2 ? fileExtension : "txt", level: level == "global" ? nil : level) }
            dismiss(); onImported(transcript)
        } catch { self.error = error.localizedDescription }
    }
}
