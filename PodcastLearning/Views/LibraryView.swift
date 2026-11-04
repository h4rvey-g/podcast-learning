import SwiftUI
import SwiftData
import PodcastCore

struct LibraryView: View {
    @Environment(\.accentTheme) private var theme
    @Environment(AppStore.self) private var store
    @Environment(ClipPlayer.self) private var player
    @Environment(\.scenePhase) private var scenePhase
    @Query(sort: \Transcript.createdAt, order: .reverse) private var transcripts: [Transcript]
    @Query private var memories: [WordMemory]
    @State private var search = ""
    @State private var showImport = false
    @State private var sharedText: String?
    @State private var showSettings = false
    @State private var path: [Transcript] = []
    @State private var pendingRemoval: Transcript?
    private var filtered: [Transcript] { transcripts.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.author.localizedCaseInsensitiveContains(search) } }
    var body: some View {
        NavigationStack(path: $path) {
            List {
                Group {
                    Text("Library").font(.largeTitle.bold()).padding(.bottom, 20).accessibilityAddTraits(.isHeader)
                    if filtered.isEmpty {
                        ContentUnavailableView(search.isEmpty ? "Your Listening, Your Learning" : "No Matching Transcripts", systemImage: search.isEmpty ? "headphones" : "magnifyingglass",
                            description: Text(search.isEmpty ? "Paste text, import a PDF or Word document, or add a podcast or Bilibili link." : "Try another title or show name."))
                        if search.isEmpty { PrimaryButton(title: "New Transcript", symbol: "plus") { showImport = true } }
                    }
                    ForEach(filtered) { transcript in
                        NavigationLink(value: transcript) { libraryCard(transcript) }.buttonStyle(.plain)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button("Remove", systemImage: "trash") { pendingRemoval = transcript }.tint(.red)
                            }
                            .contextMenu {
                                Button("Remove from Library", systemImage: "trash", role: .destructive) { pendingRemoval = transcript }
                            }
                            .accessibilityAction(named: "Remove from Library") { pendingRemoval = transcript }
                    }
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }.listStyle(.plain).listRowSpacing(14).contentMargins(.vertical, 16, for: .scrollContent)
                .scrollContentBackground(.hidden).background(Palette.background)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Settings", systemImage: "gearshape") { showSettings = true }.labelStyle(.iconOnly) } }
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 10) {
                        HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search", text: $search).submitLabel(.search)
                            if !search.isEmpty { Button("Clear Search", systemImage: "xmark.circle.fill") { search = "" }.labelStyle(.iconOnly) }
                        }.padding(15).background(.regularMaterial, in: Capsule())
                        Button { showImport = true } label: { Image(systemName: "plus").font(.title2).frame(width: 48, height: 48) }
                            .foregroundStyle(Palette.onAccent).background(theme.color, in: Circle()).accessibilityLabel("New Transcript")
                    }.padding(.horizontal, 16).padding(.bottom, 8)
                }
                .navigationDestination(for: Transcript.self) { ReaderView(transcript: $0) }
                .sheet(isPresented: $showImport) { ImportView(initialText: sharedText ?? "") { path.append($0); sharedText = nil } }
                .navigationDestination(isPresented: $showSettings) { SettingsView() }
        }
        .confirmationDialog("Remove from Library?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible, presenting: pendingRemoval) { transcript in
            Button("Remove", role: .destructive) { remove(transcript) }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { transcript in
            Text("“\(transcript.title)” and its downloaded media will be deleted. Your global word-review history will be kept. Work already sent to a provider may still be billed.")
        }
        .alert("Something Went Wrong", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) { Button("Close", role: .cancel) { store.error = nil } } message: { Text(store.error ?? "") }
        .task { await store.consumeSharedImports() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await store.consumeSharedImports() } } }
        .onOpenURL { url in
            if url.isFileURL {
                do {
                    if DocumentTextImporter.supports(url) {
                        path.append(try store.importDocument(url))
                        return
                    }
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 5_000_000 else { throw ImportError.tooLarge }
                    let data = try Data(contentsOf: url)
                    guard data.count <= 5_000_000 else { throw ImportError.tooLarge }
                    guard let text = String(data: data, encoding: .utf8) else { throw ImportError.invalidResponse }
                    let transcript = try store.importText(text, title: url.deletingPathExtension().lastPathComponent, fileExtension: url.pathExtension)
                    path.append(transcript)
                } catch { store.error = error.localizedDescription }
            } else if url.host == "podcasts.apple.com" || (try? BilibiliLink(url.absoluteString)) != nil { sharedText = url.absoluteString; showImport = true }
        }
    }
    private func remove(_ transcript: Transcript) {
        let id = transcript.id
        pendingRemoval = nil
        do {
            try store.removeTranscript(transcript)
            if player.transcriptID == id { player.stop() }
        } catch { store.error = "Could not remove this transcript: \(error.localizedDescription)" }
    }
    private func libraryCard(_ transcript: Transcript) -> some View {
        let mastered = transcript.activeItems.filter { item in memories.contains { $0.key == item.key && $0.box == 5 } }.count
        return HStack(spacing: 12) {
            CoverArt(transcript: transcript, size: 64)
            VStack(alignment: .leading, spacing: 5) {
                Text(transcript.title).font(.headline).lineLimit(2)
                Text("\(transcript.author) · " + (transcript.analysisState == "pending" ? "\(transcript.orderedSegments.count) segments" : "\(transcript.activeItems.count) words")).font(.footnote).foregroundStyle(.secondary)
                HStack {
                    if transcript.transcriptionState == "pending" { Label("Transcribing audio…", systemImage: "waveform").foregroundStyle(.secondary) }
                else if transcript.transcriptionState == "failed" { Label("Transcription interrupted · Retry", systemImage: "arrow.clockwise").foregroundStyle(.red) }
                else if transcript.synthesisState == "preparing" { Label("Preparing document…", systemImage: "sparkles").foregroundStyle(.secondary) }
                else if transcript.synthesisState == "preparationFailed" { Label("Document processing interrupted · Retry", systemImage: "arrow.clockwise").foregroundStyle(.red) }
                else if transcript.synthesisState == "pending" { Label("Generating audio…", systemImage: "waveform").foregroundStyle(.secondary) }
                else if transcript.synthesisState == "failed" { Label("Audio generation interrupted · Retry", systemImage: "arrow.clockwise").foregroundStyle(.red) }
                else if transcript.analysisState == "pending" { Label("Finding key sentences…", systemImage: "sparkles").foregroundStyle(Palette.ai) }
                    else if transcript.analysisState == "aiFailed" { Label("AI analysis failed · Retry", systemImage: "arrow.clockwise").foregroundStyle(.red) }
                    else { Label(transcript.activeItems.isEmpty ? "Ready to read" : mastered == transcript.activeItems.count ? "All mastered" : "\(transcript.activeItems.count - mastered) to practice", systemImage: mastered == transcript.activeItems.count && mastered > 0 ? "checkmark.circle" : "pencil")
                        .foregroundStyle(mastered > 0 && mastered == transcript.activeItems.count ? .green : .secondary)
                    }
                    Spacer(minLength: 0)
                    if transcript.analysisState != "pending" && !transcript.activeItems.isEmpty { ProgressView(value: Double(mastered), total: Double(transcript.activeItems.count)).tint(.secondary).frame(width: 64) }
                }.font(.footnote)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(12).background(Palette.cell, in: RoundedRectangle(cornerRadius: 22))
    }
}
