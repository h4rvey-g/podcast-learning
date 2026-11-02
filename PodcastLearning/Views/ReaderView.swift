import SwiftUI
import NaturalLanguage
import PodcastCore

private enum ReaderSelection: Identifiable {
    case word(String, Sentence), sentence(Sentence)
    var id: String { switch self { case .word(let word, let sentence): return sentence.id.uuidString + word; case .sentence(let sentence): return sentence.id.uuidString } }
}

struct ReaderView: View {
    @Bindable var transcript: Transcript
    @Environment(AppStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(ClipPlayer.self) private var player
    @State private var tab = 0
    @State private var selection: ReaderSelection?
    @State private var practice = false
    @State private var includeMastered = false
    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                CoverArt(transcript: transcript, size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(transcript.title).font(.headline).lineLimit(2)
                    Text("\(transcript.author) · \(transcript.activeItems.count) words").font(.footnote).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 16)
            Picker("Content", selection: $tab) { Text("Transcript").tag(0); Text("Items").tag(1) }.pickerStyle(.segmented).padding(.horizontal, 16)
            if tab == 0 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(ItemSource.allCases, id: \.rawValue) { SourceLabel(source: $0) }
                        Label("Key sentence", systemImage: "rectangle.leadinghalf.filled").font(.footnote).foregroundStyle(.secondary)
                    }.padding(.horizontal, 20)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        analysisStatus
                        ForEach(transcript.orderedSegments) { segment in
                            VStack(alignment: .leading, spacing: 10) {
                                Button {
                                    player.play(text: segment.text, segment: segment, transcript: transcript, settings: settings)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Palette.accent)
                                        Text(segment.speaker ?? "Paragraph \(segment.index + 1)")
                                        if let start = segment.start { Text(timestamp(start)).monospacedDigit() }
                                    }.font(.footnote).foregroundStyle(.secondary).frame(minHeight: 36)
                                }.buttonStyle(.plain).accessibilityLabel("Play \(segment.speaker ?? "paragraph")")
                                ForEach(segment.orderedSentences) { sentence in
                                    SentenceText(sentence: sentence, items: transcript.activeItems) { word in selection = .word(word, sentence) }
                                        .padding(sentence.isKey ? 10 : 0)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(sentence.isKey ? Palette.key : .clear, in: RoundedRectangle(cornerRadius: 9))
                                        .overlay(alignment: .leading) { if sentence.isKey { Capsule().fill(.yellow).frame(width: 3).accessibilityHidden(true) } }
                                        .simultaneousGesture(LongPressGesture().onEnded { _ in selection = .sentence(sentence) })
                                        .accessibilityAction(named: "Translate Sentence") { selection = .sentence(sentence) }
                                }
                            }
                        }
                    }.padding(20)
                }.background(Palette.cell, in: UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28))
            } else { ItemsView(transcript: transcript) { item in if let sentence = item.sentence { selection = .word(item.text, sentence) } } }
        }
        .background(Palette.background).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Use Global (\(settings.targetLevel))") { store.changeLevel(transcript, to: nil) }
                    ForEach(CEFR.allCases, id: \.rawValue) { level in Button(level.rawValue + " and Above") { store.changeLevel(transcript, to: level.rawValue) } }
                } label: { Text((transcript.targetLevelOverride ?? settings.targetLevel) + "+").font(.headline) }.accessibilityLabel("Target Level")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle("Include Mastered Words", isOn: $includeMastered)
                    Button("Analyze with AI", systemImage: "sparkles") { Task { await store.analyze(transcript) } }.disabled(transcript.analysisState == "pending")
                    if transcript.remoteAudioURL != nil && AudioStore.localURL(transcript.id) == nil {
                        Button("Download Audio", systemImage: "arrow.down.circle") { Task { await store.downloadAudio(transcript) } }.disabled(store.downloading.contains(transcript.id))
                    }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("More")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if tab == 0 { PlaybackBar(transcript: transcript) }
                PrimaryButton(title: "Start Dictation", symbol: "pencil.line") { player.stop(); practice = true }
                    .disabled(transcript.activeItems.isEmpty).opacity(transcript.activeItems.isEmpty ? 0.5 : 1)
            }.padding(.horizontal, 16).padding(.bottom, 8)
        }
        .sheet(item: $selection, onDismiss: { store.save() }) { value in
            switch value {
            case .word(let word, let sentence): WordSheet(word: word, sentence: sentence, transcript: transcript)
            case .sentence(let sentence): SentenceSheet(sentence: sentence, transcript: transcript)
            }
        }
        .fullScreenCover(isPresented: $practice) { DictationView(transcript: transcript, includeMastered: includeMastered) }
        .onDisappear { player.stop(); store.save() }
    }
    @ViewBuilder private var analysisStatus: some View {
        if transcript.analysisState == "pending" { HStack { ProgressView(); Text("Finding key sentences…").font(.footnote).foregroundStyle(Palette.ai) } }
        if let error = transcript.analysisError {
            VStack(alignment: .leading, spacing: 8) {
                Text(error).font(.footnote).foregroundStyle(.secondary)
                if transcript.analysisState == "aiFailed" { Button("Retry AI Analysis") { Task { await store.analyze(transcript) } } }
            }
        }
    }
}

private struct SentenceText: View {
    let sentence: Sentence
    let items: [DictationItem]
    let selectWord: (String) -> Void
    var body: some View {
        Text(attributed).font(.system(.title3, design: .serif)).lineSpacing(7).frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "learn-word", let word = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value else { return .systemAction }
                selectWord(word); return .handled
            })
            .accessibilityHint("Tap a word for its meaning. Long press to translate the sentence.")
    }
    private var attributed: AttributedString {
        let text = sentence.text
        var result = AttributedString(text)
        let tokenizer = NLTokenizer(unit: .word); tokenizer.string = text; tokenizer.setLanguage(.english)
        for range in tokenizer.tokens(for: text.startIndex..<text.endIndex) {
            guard let r = Range(range, in: result) else { continue }
            var components = URLComponents(); components.scheme = "learn-word"; components.host = "pick"
            components.queryItems = [URLQueryItem(name: "word", value: String(text[range]))]
            result[r].link = components.url; result[r].foregroundColor = .primary
        }
        let inflections = Lemmatizer.tokens(text).compactMap { token -> (String, DictationItem)? in
            guard let item = items.first(where: { $0.key == token.lemma }) else { return nil }
            return (token.text, item)
        }
        // Longer phrases take priority over words inside them.
        let highlights = (inflections + items.map { ($0.text, $0) }).sorted { $0.0.count < $1.0.count }
        for (surface, item) in highlights {
            var search = text.startIndex..<text.endIndex
            while let range = text.range(of: TextMatch.pattern(for: surface), options: [.regularExpression, .caseInsensitive], range: search) {
                if let r = Range(range, in: result) {
                    result[r].foregroundColor = Palette.source(item.itemSource)
                    result[r].font = .system(.title3, design: .serif).weight(.semibold)
                    result[r].underlineStyle = Text.LineStyle(pattern: item.itemSource == .manual ? .dot : item.itemSource == .ai ? .dash : .solid)
                    var components = URLComponents(); components.scheme = "learn-word"; components.host = "pick"
                    components.queryItems = [URLQueryItem(name: "word", value: String(text[range]))]
                    result[r].link = components.url
                }
                search = range.upperBound..<text.endIndex
            }
        }
        return result
    }
}

struct PlaybackBar: View {
    let transcript: Transcript
    @Environment(ClipPlayer.self) private var player
    @Environment(SettingsStore.self) private var settings
    var body: some View {
        HStack(spacing: 4) {
            Button("Back 15 Seconds", systemImage: "gobackward.15") { player.skip(-15) }.labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(AudioStore.localURL(transcript.id) == nil)
            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                player.toggle(text: transcript.orderedSegments.map(\.text).joined(separator: " "), transcript: transcript, settings: settings)
            }.labelStyle(.iconOnly).frame(width: 44, height: 44).foregroundStyle(Palette.cell).background(.primary, in: Circle())
            Button("Forward 15 Seconds", systemImage: "goforward.15") { player.skip(15) }.labelStyle(.iconOnly).frame(width: 44, height: 44).disabled(AudioStore.localURL(transcript.id) == nil)
            VStack(spacing: 3) {
                if AudioStore.localURL(transcript.id) != nil {
                    ProgressView(value: min(player.position, player.duration), total: max(1, player.duration)).tint(.primary)
                    HStack { Text(timestamp(player.position)); Spacer(); Text("−" + timestamp(max(0, player.duration - player.position))) }.font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                } else { Text(storeDownloading ? "Downloading…" : "Text to Speech").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity)
            Button { player.changeSpeed() } label: { Text(String(format: "%g×", player.speed)).font(.headline).frame(minWidth: 44, minHeight: 44) }.disabled(AudioStore.localURL(transcript.id) == nil).accessibilityLabel("Playback Speed")
        }.buttonStyle(.plain).padding(8).background(.regularMaterial, in: Capsule())
            .alert("Playback Failed", isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) { Button("Close", role: .cancel) { player.error = nil } } message: { Text(player.error ?? "") }
    }
    @Environment(AppStore.self) private var store
    private var storeDownloading: Bool { store.downloading.contains(transcript.id) }
}
