import Foundation
import SwiftData

public enum CEFR: String, Codable, CaseIterable, Comparable, Sendable {
    case a1 = "A1", a2 = "A2", b1 = "B1", b2 = "B2", c1 = "C1", c2 = "C2"
    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public enum ItemSource: String, CaseIterable, Sendable {
    case list, ai, manual
    public var label: String { self == .ai ? "AI" : rawValue.capitalized }
    public var symbol: String { self == .list ? "book" : self == .ai ? "sparkles" : "hand.tap" }
}

@Model public final class Transcript {
    public var id: UUID = UUID()
    public var title: String = ""
    public var author: String = ""
    public var coverURL: String?
    public var sourceURL: String?
    public var episodeID: String?
    public var remoteAudioURL: String?
    public var targetLevelOverride: String?
    public var analysisState: String = "marked"
    public var analysisError: String?
    public var createdAt: Date = Date()
    @Relationship(deleteRule: .cascade, inverse: \Segment.transcript) public var segments: [Segment]?
    @Relationship(deleteRule: .cascade, inverse: \DictationItem.transcript) public var items: [DictationItem]?
    public init(title: String, author: String = "Pasted text") { self.title = title; self.author = author }
    public var orderedSegments: [Segment] { (segments ?? []).sorted { $0.index < $1.index } }
    public var sentences: [Sentence] { orderedSegments.flatMap(\.orderedSentences) }
    public var activeItems: [DictationItem] { (items ?? []).filter { !$0.isRemoved }.sorted { ($0.sentence?.index ?? 0) < ($1.sentence?.index ?? 0) } }
}

@Model public final class Segment {
    public var id: UUID = UUID()
    public var index: Int = 0
    public var speaker: String?
    public var start: Double?
    public var end: Double?
    public var text: String = ""
    public var transcript: Transcript?
    @Relationship(deleteRule: .cascade, inverse: \Sentence.segment) public var sentences: [Sentence]?
    public init(index: Int, text: String, speaker: String? = nil, start: Double? = nil, end: Double? = nil) {
        self.index = index; self.text = text; self.speaker = speaker; self.start = start; self.end = end
    }
    public var orderedSentences: [Sentence] { (sentences ?? []).sorted { $0.index < $1.index } }
}

@Model public final class Sentence {
    public var id: UUID = UUID()
    public var index: Int = 0
    public var text: String = ""
    public var isKey: Bool = false
    public var keyNoteZh: String?
    public var segment: Segment?
    @Relationship(deleteRule: .nullify, inverse: \DictationItem.sentence) public var items: [DictationItem]?
    public init(index: Int, text: String) { self.index = index; self.text = text }
}

@Model public final class DictationItem {
    public var id: UUID = UUID()
    public var text: String = ""
    public var key: String = ""
    public var level: String?
    public var source: String = "list"
    public var glossZh: String?
    public var definitionEn: String?
    public var isRemoved: Bool = false
    public var transcript: Transcript?
    @Relationship(deleteRule: .nullify) public var sentence: Sentence?
    public init(text: String, key: String, level: String? = nil, source: ItemSource = .list, sentence: Sentence? = nil) {
        self.text = text; self.key = key; self.level = level; self.source = source.rawValue; self.sentence = sentence
    }
    public var itemSource: ItemSource { ItemSource(rawValue: source) ?? .manual }
}

@Model public final class WordMemory {
    public var key: String = ""
    public var box: Int = 1
    public var dueAt: Date = Date.distantPast
    public var attempts: Int = 0
    public var correct: Int = 0
    public var lastPracticedAt: Date?
    public init(key: String) { self.key = key }
}

public enum LearningSchema {
    public static var schema: Schema { Schema([Transcript.self, Segment.self, Sentence.self, DictationItem.self, WordMemory.self]) }
}
