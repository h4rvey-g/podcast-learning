import SwiftUI
import SwiftData
import PodcastCore

struct ItemsView: View {
    let transcript: Transcript
    let select: (DictationItem) -> Void
    @Environment(AppStore.self) private var store
    @Query private var memories: [WordMemory]
    @State private var source = "all"
    @State private var level = "all"
    private var filtered: [DictationItem] { (transcript.items ?? []).filter { (source == "all" || $0.source == source) && (level == "all" || $0.level == level) }.sorted { ($0.sentence?.index ?? 0) < ($1.sentence?.index ?? 0) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Source", selection: $source) { Text("All Sources").tag("all"); ForEach(ItemSource.allCases, id: \.rawValue) { Text($0.label).tag($0.rawValue) } }
                Spacer()
                Picker("Level", selection: $level) { Text("All Levels").tag("all"); ForEach(CEFR.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) } }
            }.padding(.horizontal)
            List {
                Section("\(filtered.filter { !$0.isRemoved }.count) Words and Phrases") {
                    ForEach(filtered.filter { !$0.isRemoved }) { item in itemRow(item) }
                }
                let removed = filtered.filter(\.isRemoved)
                if !removed.isEmpty { Section("Removed") { ForEach(removed) { item in itemRow(item) } } }
                if filtered.isEmpty { ContentUnavailableView("No Items", systemImage: "text.badge.plus", description: Text("Tap a word in the transcript to add it, or change the filters.")) }
            }.listStyle(.insetGrouped).scrollContentBackground(.hidden)
        }
    }
    private func itemRow(_ item: DictationItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.itemSource.symbol).foregroundStyle(Palette.source(item.itemSource))
            Button { select(item) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(item.text).font(.headline); if let level = item.level { LevelBadge(level: level) } }
                    if let gloss = item.glossZh { Text(gloss).font(.subheadline).foregroundStyle(.secondary) }
                    Text("\(item.itemSource.label) · Box \(memories.first(where: { $0.key == item.key })?.box ?? 1)").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            Button(item.isRemoved ? "Restore" : "Remove", systemImage: item.isRemoved ? "arrow.uturn.backward" : "minus.circle") {
                item.isRemoved.toggle(); store.save()
            }.labelStyle(.iconOnly).buttonStyle(.borderless).frame(minWidth: 44, minHeight: 44)
        }.opacity(item.isRemoved ? 0.65 : 1)
            .contextMenu {
                Menu("Change Example Sentence") {
                    ForEach(transcript.sentences.filter { TextMatch.range(of: item.text, in: $0.text) != nil }) { sentence in
                        Button(sentence.text) { item.sentence = sentence; store.save() }
                    }
                }
                Button(item.isRemoved ? "Restore Item" : "Remove Item") { item.isRemoved.toggle(); store.save() }
            }
    }
}
