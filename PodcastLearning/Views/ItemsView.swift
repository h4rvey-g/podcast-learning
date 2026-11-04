import SwiftUI
import SwiftData
import PodcastCore

struct ItemsView: View {
    @Environment(\.accentTheme) private var theme
    let transcript: Transcript
    var focusedItemID: UUID? = nil
    let select: (DictationItem) -> Void
    @Environment(AppStore.self) private var store
    @Query private var memories: [WordMemory]
    @State private var source = "all"
    @State private var level = "all"
    private var filtered: [DictationItem] { (transcript.items ?? []).filter { (source == "all" || $0.source == source) && (level == "all" || $0.level == level) }.sorted { ($0.sentence?.index ?? 0) < ($1.sentence?.index ?? 0) } }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    sourceChip("all", title: "All", symbol: nil)
                    ForEach(ItemSource.allCases, id: \.rawValue) { sourceChip($0.rawValue, title: $0.label, symbol: $0.symbol) }
                    Menu { Picker("Level", selection: $level) { Text("All Levels").tag("all"); ForEach(CEFR.allCases, id: \.rawValue) { Text($0.rawValue).tag($0.rawValue) } } } label: {
                        Image(systemName: "line.3.horizontal.decrease").frame(width: 36, height: 36).background(Palette.cell, in: Circle())
                    }.accessibilityLabel("Filter by CEFR Level")
                }.padding(.horizontal, 16).padding(.vertical, 6)
            }
            ScrollViewReader { proxy in
                List {
                    Section("\(filtered.filter { !$0.isRemoved }.count) Items · Swipe to Remove") {
                        ForEach(filtered.filter { !$0.isRemoved }) { item in itemRow(item).id(item.id) }
                    }
                    let removed = filtered.filter(\.isRemoved)
                    if !removed.isEmpty { Section("Removed") { ForEach(removed) { item in itemRow(item).id(item.id) } } }
                    if filtered.isEmpty { ContentUnavailableView("No Items", systemImage: "text.badge.plus", description: Text("Tap a word in the transcript to add it, or change the filters.")) }
                }.listStyle(.insetGrouped).scrollContentBackground(.hidden)
                    .task(id: focusedItemID) {
                        guard let id = focusedItemID else { return }
                        source = "all"; level = "all"
                        await Task.yield()
                        proxy.scrollTo(id, anchor: .center)
                    }
            }
        }
    }
    private func sourceChip(_ value: String, title: String, symbol: String?) -> some View {
        let count = transcript.activeItems.filter { value == "all" || $0.source == value }.count
        return Button { source = value } label: {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).foregroundStyle(source == value ? Palette.cell : Palette.source(ItemSource(rawValue: value) ?? .list)) }
                Text("\(title) \(count)")
            }.font(.subheadline.weight(.semibold)).padding(.horizontal, 12).frame(minHeight: 36)
                .foregroundStyle(source == value ? Palette.cell : .primary)
                .background(source == value ? Color.primary : Palette.cell, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(source == value ? .isSelected : [])
    }
    private func itemRow(_ item: DictationItem) -> some View {
        HStack(spacing: 8) {
            Button { select(item) } label: { ItemSummaryRow(item: item, memory: memories.first { $0.key == item.key }) }.buttonStyle(.plain)
            if item.isRemoved {
                Button("Restore") { item.isRemoved = false; store.save() }.font(.footnote.weight(.semibold))
                    .padding(.horizontal, 12).frame(minHeight: 36).background(theme.color.opacity(0.08), in: Capsule()).buttonStyle(.borderless)
            }
        }.opacity(item.isRemoved ? 0.65 : 1)
            .listRowBackground(focusedItemID == item.id ? theme.color.opacity(0.08) : Palette.cell)
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button(item.isRemoved ? "Restore" : "Remove", systemImage: item.isRemoved ? "arrow.uturn.backward" : "minus.circle") { item.isRemoved.toggle(); store.save() }
                    .tint(item.isRemoved ? theme.color : .red)
            }
            .contextMenu {
                Menu("Change Example Sentence") {
                    ForEach(transcript.sentences.filter { TextMatch.range(of: item.text, in: $0.text) != nil }) { sentence in Button(sentence.text) { item.sentence = sentence; store.save() } }
                }
                Button(item.isRemoved ? "Restore Item" : "Remove Item") { item.isRemoved.toggle(); store.save() }
            }
            .accessibilityAction(named: item.isRemoved ? "Restore" : "Remove") { item.isRemoved.toggle(); store.save() }
    }
}
