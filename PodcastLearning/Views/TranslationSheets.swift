import SwiftUI
import Translation
import PodcastCore

struct WordSheet: View {
    let word: String
    let sentence: Sentence
    let transcript: Transcript
    @Environment(AppStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(ClipPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var translation = ""
    @State private var explanation = ""
    @State private var error: String?
    @State private var busy = false
    @State private var configuration: TranslationSession.Configuration?
    private var item: DictationItem? {
        let key = Lemmatizer.tokens(word).first?.lemma ?? word.lowercased()
        return transcript.items?.first { $0.text.lowercased() == word.lowercased() || $0.key == key }
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack { Text(word).font(.system(.title2, design: .serif).bold()); if let level = item?.level { LevelBadge(level: level) }; Spacer(); RoundButton(title: "Pronounce", symbol: "speaker.wave.2") { player.play(text: word, settings: settings) } }
                    Text("\(Lemmatizer.tokens(word).first?.lemma ?? word.lowercased()) · \(Lemmatizer.tokens(word).first?.pos ?? "phrase")").font(.subheadline).foregroundStyle(.secondary)
                    if let gloss = item?.glossZh, !gloss.isEmpty { Text(gloss).font(.title3.weight(.semibold)) }
                    else if !translation.isEmpty { Text(translation).font(.title3.weight(.semibold)) }
                    else { Button("Translate Word", systemImage: "translate") { configuration = .init(source: .init(identifier: "en"), target: .init(identifier: "zh-Hans")) } }
                    if let definition = item?.definitionEn { Text(definition).foregroundStyle(.secondary) }
                    if let item { SourceLabel(source: item.itemSource) }
                    if !explanation.isEmpty { Text(explanation).font(.body) }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                    if busy { ProgressView("Generating gloss…") }
                    HStack {
                        Button(item?.isRemoved == false ? "Remove from Dictation" : "Add to Dictation", systemImage: item?.isRemoved == false ? "minus.circle" : "plus.circle") {
                            if let item, !item.isRemoved { item.isRemoved = true; store.save() }
                            else { store.addWord(word, sentence: sentence, transcript: transcript, gloss: translation.isEmpty ? nil : translation) }
                        }.buttonStyle(.bordered)
                        Button("AI Gloss", systemImage: "sparkles") { Task { await gloss() } }.buttonStyle(.bordered).disabled(busy)
                    }
                }.padding(20)
            }.navigationTitle("Word").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                .translationTask(configuration) { session in
                    do {
                        let result = try await session.translate(word); translation = result.targetText
                        if let item, item.glossZh == nil { item.glossZh = result.targetText; store.save() }
                    } catch { self.error = "Translation unavailable. Download the English and Chinese language packs, then try again. \(error.localizedDescription)" }
                }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    @MainActor private func gloss() async {
        busy = true; error = nil; defer { busy = false }
        do { explanation = try await AIAnalyzer(settings: settings).explain("Explain the word or phrase '\(word)' in this context: \(sentence.text)") }
        catch { self.error = error.localizedDescription }
    }
}

struct SentenceSheet: View {
    let sentence: Sentence
    let transcript: Transcript
    @Environment(SettingsStore.self) private var settings
    @Environment(ClipPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var configuration: TranslationSession.Configuration?
    @State private var translation = ""
    @State private var explanation = ""
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(sentence.text).font(.system(.title3, design: .serif)).lineSpacing(6)
                    if sentence.isKey { Label("Key Sentence", systemImage: "sparkles").font(.footnote).foregroundStyle(Palette.ai); if let note = sentence.keyNoteZh { Text(note).font(.subheadline).foregroundStyle(.secondary) } }
                    Divider()
                    if !translation.isEmpty { Text(translation).font(.body) }
                    else { Button("Translate to Chinese", systemImage: "translate") { configuration = .init(source: .init(identifier: "en"), target: .init(identifier: "zh-Hans")) } }
                    HStack {
                        Button("Play Paragraph", systemImage: "speaker.wave.2") { player.play(text: sentence.text, segment: sentence.segment, transcript: transcript, settings: settings) }.buttonStyle(.bordered)
                        Button("AI Explain", systemImage: "sparkles") { Task { await explain() } }.buttonStyle(.bordered).disabled(busy)
                    }
                    if busy { ProgressView("Explaining…") }
                    if !explanation.isEmpty { Text("AI Explanation").font(.headline); Text(explanation).textSelection(.enabled) }
                    if let error { Text(error).font(.footnote).foregroundStyle(.red) }
                }.padding(20)
            }.navigationTitle("Sentence").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                .translationTask(configuration) { session in
                    do { translation = try await session.translate(sentence.text).targetText }
                    catch { self.error = "Translation unavailable. Download the language packs and try again. \(error.localizedDescription)" }
                }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    @MainActor private func explain() async {
        busy = true; error = nil; defer { busy = false }
        do { explanation = try await AIAnalyzer(settings: settings).explain(sentence.text) }
        catch { self.error = error.localizedDescription }
    }
}
