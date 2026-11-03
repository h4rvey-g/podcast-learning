import Foundation
import SwiftData
import Testing
@testable import PodcastCore

func fixture(_ name: String) throws -> Data { try Data(contentsOf: Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!) }

@Test func textImports() throws {
    let srt = try TextImporter.paragraphs(String(decoding: fixture("transcript.srt"), as: UTF8.self), fileExtension: "srt")
    #expect(srt == ["Hello world. This is a test.", "We are studying abilities."])
    let vtt = try TextImporter.paragraphs(String(decoding: fixture("transcript.vtt"), as: UTF8.self), fileExtension: "vtt")
    #expect(vtt == ["Hello world.", "Another sentence."])
    #expect(try TextImporter.paragraphs("First.\r\n\r\nSecond.") == ["First.", "Second."])
    #expect(throws: ImportError.self) { try TextImporter.paragraphs(" \n\n ") }
    #expect(throws: ImportError.self) { try TextImporter.paragraphs(String(repeating: "a", count: 5_000_001)) }
}

@MainActor @Test func transcriptGraphAndPersistence() throws {
    let container = try testContainer(), context = container.mainContext
    let transcript = TextImporter.makeTranscript(title: "Test", paragraphs: ["A sentence. Another one!", "A third paragraph."])
    context.insert(transcript); try context.save()
    #expect(transcript.orderedSegments.count == 2)
    #expect(transcript.sentences.map(\.index) == [0, 1, 2])
    #expect(transcript.sentences[0].segment?.transcript?.id == transcript.id)
    let sentence = transcript.sentences[0]
    let item = DictationItem(text: "sentence", key: "sentence", sentence: sentence)
    transcript.items = [item]; try context.save()
    #expect(item.transcript?.id == transcript.id)
    context.delete(transcript); try context.save()
    #expect(try context.fetchCount(FetchDescriptor<Segment>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<Sentence>()) == 0)
    #expect(try context.fetchCount(FetchDescriptor<DictationItem>()) == 0)
}

@Test func bundledWordlist() throws {
    let marker = try LevelMarker.bundled()
    #expect(marker.words.count > 8500)
    #expect(Set(marker.words.values.flatMap { $0.values }) == Set(CEFR.allCases))
    #expect(marker.level(lemma: "notawordxyz", pos: "noun", surface: "NOTAWORDXYZ") == nil)
}

@MainActor @Test func lemmatizationAndFirstOccurrence() {
    let marker = LevelMarker(words: ["study": ["verb": .b2], "ability": ["noun": .c1], "play": ["verb": .a1], "london": ["noun": .c2]])
    let transcript = TextImporter.makeTranscript(title: "Test", paragraphs: ["They studied abilities in London. They studied abilities again and played games."])
    marker.mark(transcript, target: .b2)
    #expect(Set(transcript.activeItems.map(\.key)) == Set(["study", "ability"]))
    #expect(transcript.activeItems.first(where: { $0.key == "study" })?.text == "studied")
    marker.mark(transcript, target: .b2)
    #expect(transcript.activeItems.count == 2)
    transcript.activeItems[0].isRemoved = true
    marker.mark(transcript, target: .b2)
    #expect((transcript.items ?? []).count == 2)
}

@Test func levelsUsePOSBeforeLowestSense() {
    let marker = LevelMarker(words: ["cast": ["noun": .b2, "verb": .c1], "word": ["noun": .a2]])
    #expect(marker.level(lemma: "cast", pos: "verb", surface: "cast") == .c1)
    #expect(marker.level(lemma: "cast", pos: "other", surface: "cast") == .b2)
    #expect(marker.level(lemma: "unknown", pos: "noun", surface: "Word") == .a2)
    #expect(CEFR.c1 > .b2)
}

@MainActor @Test func aiDropsUnknownIDsHallucinationsDuplicatesAndRemovedWords() throws {
    let transcript = TextImporter.makeTranscript(title: "Test", paragraphs: ["Music keeps time. Music feels profoundly different."])
    let removed = DictationItem(text: "Music", key: "music", sentence: transcript.sentences[0]); removed.isRemoved = true
    transcript.items = [removed]
    let json = """
    {"keySentences":[{"sentenceId":1,"noteZh":"关键句"},{"sentenceId":999,"noteZh":"bad"}],
     "extraItems":[
       {"text":"music","sentenceId":0,"glossZh":"音乐","definitionEn":"sound"},
       {"text":"keeps time","sentenceId":0,"glossZh":"打拍子","definitionEn":"follow rhythm"},
       {"text":"keeps time","sentenceId":0,"glossZh":"duplicate","definitionEn":"duplicate"},
       {"text":"ghost","sentenceId":1,"glossZh":"bad","definitionEn":"bad"},
       {"text":"profoundly","sentenceId":999,"glossZh":"bad","definitionEn":"bad"},
       {"text":"time","sentenceId":1,"glossZh":"bad","definitionEn":"bad"},
       {"text":"","sentenceId":1,"glossZh":"bad","definitionEn":"bad"}],
     "glosses":[{"itemId":"\(removed.id.uuidString)","glossZh":"音乐","definitionEn":"sound"},{"itemId":"unknown","glossZh":"bad","definitionEn":"bad"}]}
    """
    let analysis = try JSONDecoder().decode(AIAnalysis.self, from: Data(json.utf8))
    analysis.apply(to: transcript); analysis.apply(to: transcript)
    #expect(transcript.activeItems.map(\.text) == ["keeps time"])
    #expect(transcript.sentences[1].isKey)
    #expect(removed.isRemoved)
    #expect(removed.glossZh == "音乐")
}

@Test func textMatchBoundaries() {
    #expect(TextMatch.range(of: "art", in: "start") == nil)
    #expect(TextMatch.range(of: "", in: "anything") == nil)
    #expect(TextMatch.range(of: "keep time", in: "We KEEP TIME.") != nil)
    #expect(TextMatch.range(of: "C++", in: "Use C++.") != nil)
}

@Test func aiSchemaRequiresAllFieldsAndRejectsAdditionalProperties() throws {
    let schema = try #require(JSONSerialization.jsonObject(with: AIAnalysis.schemaData()) as? [String: Any])
    #expect(schema["additionalProperties"] as? Bool == false)
    #expect(schema["required"] as? [String] == ["extraItems", "glosses", "keySentences"])
    let properties = try #require(schema["properties"] as? [String: [String: Any]])
    for name in ["extraItems", "glosses", "keySentences"] {
        let items = try #require(properties[name]?["items"] as? [String: Any])
        #expect(items["additionalProperties"] as? Bool == false)
        #expect(!(items["required"] as? [String] ?? []).isEmpty)
    }
}

@MainActor @Test func sharedHighlightsKeepPhrasesWholeAndPreserveInflections() {
    let text = "🎵 They studied music, keeping time. Time matters."
    let phrase = DictationItem(text: "keeping time", key: "keep time", source: .ai)
    let word = DictationItem(text: "time", key: "time")
    let inflected = DictationItem(text: "study", key: "study", source: .manual)
    let highlights = TextMatch.highlights(in: text, items: [word, phrase, inflected])
    #expect(highlights.map { String(text[$0.range]) } == ["studied", "keeping time", "Time"])
    #expect(highlights.map { $0.item.itemSource } == [.manual, .ai, .list])
    #expect(TextMatch.highlights(in: "start", items: [DictationItem(text: "art", key: "art")]).isEmpty)
}

@MainActor @Test func durationUsesLatestFinitePositiveTimestamp() {
    let transcript = Transcript(title: "Duration")
    #expect(transcript.duration == nil)
    transcript.segments = [Segment(index: 0, text: "A", end: 30), Segment(index: 1, text: "B", end: 75), Segment(index: 2, text: "C", end: .infinity), Segment(index: 3, text: "D", end: -1)]
    #expect(transcript.duration == 75)
    transcript.audioDuration = 2172
    #expect(transcript.duration == 2172)
    transcript.audioDuration = .nan
    #expect(transcript.duration == 75)
}

@MainActor @Test func aiPronunciationsAreOptionalAndPersistWithWordDetails() throws {
    let container = try testContainer(), context = container.mainContext
    let transcript = TextImporter.makeTranscript(title: "IPA", paragraphs: ["Music feels profoundly different."])
    context.insert(transcript)
    let item = DictationItem(text: "Music", key: "music", sentence: transcript.sentences[0]); transcript.items = [item]
    let json = """
    {"keySentences":[],"extraItems":[{"text":"profoundly","sentenceId":0,"glossZh":"深刻地","definitionEn":"deeply","phonetic":"/prəˈfaʊndli/"}],
    "glosses":[{"itemId":"\(item.id)","glossZh":"音乐","definitionEn":"sound","phonetic":"/ˈmjuːzɪk/"}]}
    """
    try JSONDecoder().decode(AIAnalysis.self, from: Data(json.utf8)).apply(to: transcript)
    try context.save()
    let stored = try context.fetch(FetchDescriptor<DictationItem>())
    #expect(stored.first { $0.key == "music" }?.phonetic == "/ˈmjuːzɪk/")
    #expect(stored.first { $0.key == "profoundly" }?.phonetic == "/prəˈfaʊndli/")
    let schema = try #require(JSONSerialization.jsonObject(with: AIAnalysis.schemaData()) as? [String: Any])
    let properties = try #require(schema["properties"] as? [String: [String: Any]])
    for name in ["extraItems", "glosses"] {
        let fields = try #require(properties[name]?["items"] as? [String: Any])
        #expect((fields["required"] as? [String] ?? []).contains("phonetic"))
    }
}

@MainActor @Test func speechOffsetsFollowOrderedParagraphsAndUTF16Boundaries() {
    let transcript = Transcript(title: "Speech")
    let first = Segment(index: 0, text: "🎵 Hi.")
    let second = Segment(index: 1, text: "Another paragraph.")
    transcript.segments = [second, first]
    #expect(transcript.spokenText == first.text + " " + second.text)
    #expect(transcript.segment(atSpeechOffset: 0)?.id == first.id)
    #expect(transcript.segment(atSpeechOffset: first.text.utf16.count + 1)?.id == second.id)
    #expect(transcript.segment(atSpeechOffset: transcript.spokenText.utf16.count) == nil)
    #expect(transcript.segment(atSpeechOffset: -1) == nil)
}
