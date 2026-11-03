import Foundation
import SwiftData

public enum AnswerChecker {
    public static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
    }
    public static func matches(_ input: String, answer: String) -> Bool { normalized(input) == normalized(answer) }
}

public enum HintMask {
    public static func make(_ text: String) -> String { tiles(text).joined(separator: " ") }
    public static func tiles(_ text: String) -> [String] {
        let letters = Array(text)
        let positions = letters.indices.filter { letters[$0].isLetter }
        return letters.indices.map { i in
            guard letters[i].isLetter else { return String(letters[i]) }
            return i == positions.first || i == positions.last || i.isMultiple(of: 3) ? String(letters[i]) : "_"
        }
    }
    public static func cloze(_ sentence: String, answer: String, hint: Bool = false) -> String {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let regex = try? NSRegularExpression(pattern: TextMatch.pattern(for: answer), options: .caseInsensitive) else { return sentence }
        let replacement = hint ? make(answer) : "________"
        return regex.stringByReplacingMatches(in: sentence, range: NSRange(sentence.startIndex..., in: sentence),
                                               withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}

public struct RetryLetters: Equatable, Sendable {
    public let hints: [String]
    public private(set) var letters: [String]
    public let editableIndices: [Int]
    public init(answer: String) {
        let mask = HintMask.tiles(answer), characters = Array(answer)
        let editable = mask.indices.filter { characters[$0].isLetter && mask[$0] == "_" }
        hints = mask; editableIndices = editable
        letters = mask.indices.map { editable.contains($0) ? "" : mask[$0] }
    }
    public var firstEmptyIndex: Int? { editableIndices.first { letters[$0].isEmpty } }
    public var value: String? { !letters.isEmpty && letters.allSatisfy { !$0.isEmpty } ? letters.joined() : nil }
    @discardableResult public mutating func replace(at index: Int, with input: String) -> Int? {
        guard editableIndices.contains(index) else { return nil }
        if input.isEmpty { letters[index] = ""; return index }
        let characters = Array(input)
        if characters.count == hints.count {
            for slot in editableIndices { letters[slot] = characters[slot].isLetter ? String(characters[slot]) : "" }
            return editableIndices.last
        }
        let incoming = characters.filter(\.isLetter)
        var last = index
        for (slot, letter) in zip(editableIndices.filter { $0 >= index }, incoming) { letters[slot] = String(letter); last = slot }
        guard !incoming.isEmpty else { return index }
        return editableIndices.first { $0 > last } ?? last
    }
    @discardableResult public mutating func backspace(at index: Int) -> Int? {
        guard editableIndices.contains(index) else { return nil }
        let target = letters[index].isEmpty ? editableIndices.last(where: { $0 < index }) ?? index : index
        letters[target] = ""; return target
    }
}

public enum PracticeGrade: Int, Sendable, Codable { case firstTry, secondTry, revealed }

public enum Leitner {
    public static func nextBox(_ box: Int, grade: PracticeGrade) -> Int {
        switch grade {
        case .firstTry: return min(5, max(1, box) + 1)
        case .secondTry: return min(5, max(1, box))
        case .revealed: return 1
        }
    }
    public static func dueDate(box: Int, now: Date) -> Date {
        now.addingTimeInterval(Double([1, 2, 4, 8, 16][min(5, max(1, box)) - 1]) * 86_400)
    }
    @MainActor public static func record(_ memory: WordMemory, grade: PracticeGrade, now: Date = Date()) {
        memory.box = nextBox(memory.box, grade: grade)
        memory.attempts += 1
        if grade != .revealed { memory.correct += 1 }
        memory.lastPracticedAt = now
        memory.dueAt = dueDate(box: memory.box, now: now)
    }
    @MainActor public static func memories(in context: ModelContext) throws -> [String: WordMemory] {
        let rows = try context.fetch(FetchDescriptor<WordMemory>())
        var result: [String: WordMemory] = [:]
        // CloudKit can create duplicate keys. The most recent review owns the schedule.
        for row in rows.sorted(by: { ($0.lastPracticedAt ?? .distantPast) > ($1.lastPracticedAt ?? .distantPast) }) {
            if result[row.key] == nil { result[row.key] = row }
            else { context.delete(row) }
        }
        return result
    }
    @MainActor public static func retryQueue(_ results: [PracticeResult], memories: [String: WordMemory]) -> [PracticeParagraph] {
        queue(results.filter { $0.grade != .firstTry }.map(\.item), memories: memories, includeMastered: true)
    }
    @MainActor public static func queue(_ items: [DictationItem], memories: [String: WordMemory], includeMastered: Bool, now: Date = Date()) -> [PracticeParagraph] {
        let ordered = items.filter { !$0.isRemoved && (includeMastered || (memories[$0.key]?.box ?? 1) < 5) }.sorted {
            let a = memories[$0.key], b = memories[$1.key]
            let aDue = (a?.dueAt ?? .distantPast) <= now, bDue = (b?.dueAt ?? .distantPast) <= now
            if aDue != bDue { return aDue }
            if (a?.box ?? 1) != (b?.box ?? 1) { return (a?.box ?? 1) < (b?.box ?? 1) }
            return ($0.sentence?.index ?? 0) < ($1.sentence?.index ?? 0)
        }
        var groups: [[DictationItem]] = []
        for item in ordered {
            if let segment = item.sentence?.segment, let index = groups.firstIndex(where: { $0.first?.sentence?.segment?.id == segment.id }) {
                groups[index].append(item)
            } else { groups.append([item]) }
        }
        return groups.map(PracticeParagraph.init)
    }
}

public enum TextMatch {
    public static func range(of phrase: String, in text: String) -> Range<String.Index>? {
        guard !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text.range(of: pattern(for: phrase), options: [.regularExpression, .caseInsensitive])
    }
    @MainActor public static func highlights(in text: String, items: [DictationItem]) -> [(range: Range<String.Index>, item: DictationItem)] {
        let inflections = Lemmatizer.tokens(text).compactMap { token in
            items.first { $0.key == token.lemma }.map { (token.text, $0) }
        }
        let candidates = (inflections + items.map { ($0.text, $0) }).sorted { $0.0.count > $1.0.count }
        var matches: [(range: Range<String.Index>, item: DictationItem)] = []
        for (surface, item) in candidates where !surface.isEmpty {
            var search = text.startIndex..<text.endIndex
            while let range = text.range(of: pattern(for: surface), options: [.regularExpression, .caseInsensitive], range: search) {
                if !matches.contains(where: { $0.range.overlaps(range) }) { matches.append((range, item)) }
                search = range.upperBound..<text.endIndex
            }
        }
        return matches.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }
    public static func pattern(for phrase: String) -> String {
        "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![\\p{L}\\p{N}])"
    }
}

@MainActor public struct PracticeResult: Identifiable {
    public let id: UUID
    public let item: DictationItem
    public let grade: PracticeGrade
    public init(item: DictationItem, grade: PracticeGrade) { self.id = item.id; self.item = item; self.grade = grade }
}

public struct DictationAttempt: Equatable, Sendable {
    public private(set) var inputs: [String] = []
    public enum Phase: Equatable, Sendable { case first, second, answered(PracticeGrade) }
    public private(set) var phase: Phase = .first
    public init() {}
    @discardableResult public mutating func check(_ input: String, answer: String) -> PracticeGrade? {
        guard case .answered = phase else {
            inputs.append(input)
            if AnswerChecker.matches(input, answer: answer) {
                let grade: PracticeGrade = phase == .first ? .firstTry : .secondTry
                phase = .answered(grade); return grade
            }
            if phase == .first { phase = .second; return nil }
            phase = .answered(.revealed); return .revealed
        }
        return nil
    }
    @discardableResult public mutating func reveal() -> PracticeGrade? {
        if case .answered = phase { return nil }
        phase = .answered(.revealed); return .revealed
    }
    public mutating func restore(_ grade: PracticeGrade) {
        if case .answered = phase { return }
        phase = .answered(grade)
    }
}

@MainActor public struct PracticeParagraph {
    public let items: [DictationItem]
    public var segment: Segment? { items.first?.sentence?.segment }
    public var text: String { segment?.text ?? items.first?.sentence?.text ?? items.first?.text ?? "" }
    public init(items: [DictationItem]) {
        self.items = items.sorted {
            let a = $0.sentence?.index ?? 0, b = $1.sentence?.index ?? 0
            if a != b { return a < b }
            let text = $0.sentence?.text ?? $0.text
            let start = TextMatch.range(of: $0.text, in: text)?.lowerBound ?? text.endIndex
            let end = TextMatch.range(of: $1.text, in: text)?.lowerBound ?? text.endIndex
            return start < end
        }
    }
    public struct Part { public let text: String; public let item: DictationItem? }
    public func parts(completed: Set<UUID> = []) -> [Part] {
        let pending = items.filter { !completed.contains($0.id) }
        let patterns = pending.map(\.text).filter { !$0.isEmpty }.sorted { $0.count > $1.count }.map(TextMatch.pattern)
        guard !patterns.isEmpty, let regex = try? NSRegularExpression(pattern: patterns.joined(separator: "|"), options: .caseInsensitive) else { return [Part(text: text, item: nil)] }
        var result: [Part] = [], cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let item = pending.first(where: { AnswerChecker.matches(String(text[range]), answer: $0.text) }) else { continue }
            if cursor < range.lowerBound { result.append(Part(text: String(text[cursor..<range.lowerBound]), item: nil)) }
            result.append(Part(text: String(text[range]), item: item)); cursor = range.upperBound
        }
        if cursor < text.endIndex { result.append(Part(text: String(text[cursor...]), item: nil)) }
        return result
    }
    public func cloze(completed: Set<UUID> = []) -> String {
        parts(completed: completed).map { $0.item == nil ? $0.text : "________" }.joined()
    }
}

public struct ParagraphAttempt: Equatable, Sendable {
    private var attempts: [UUID: DictationAttempt] = [:]
    public init() {}
    public func phase(_ id: UUID) -> DictationAttempt.Phase { attempts[id]?.phase ?? .first }
    public func inputs(_ id: UUID) -> [String] { attempts[id]?.inputs ?? [] }
    public func grade(_ id: UUID) -> PracticeGrade? {
        if case .answered(let grade) = phase(id) { return grade }; return nil
    }
    /// Reapplies grades saved by an earlier session without recording them again.
    public mutating func restore(_ grades: [UUID: PracticeGrade]) {
        for (id, grade) in grades { attempts[id, default: DictationAttempt()].restore(grade) }
    }
    @MainActor public mutating func check(_ inputs: [UUID: String], items: [DictationItem], reveal: Bool = false) -> [UUID: PracticeGrade] {
        let pending = items.filter { grade($0.id) == nil }
        guard reveal || pending.allSatisfy({ !(inputs[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return [:] }
        var grades: [UUID: PracticeGrade] = [:]
        for item in pending {
            var attempt = attempts[item.id] ?? DictationAttempt()
            grades[item.id] = reveal ? attempt.reveal() : attempt.check(inputs[item.id] ?? "", answer: item.text)
            attempts[item.id] = attempt
        }
        return grades
    }
}

/// Saved dictation progress for one transcript, so a session can be continued later.
public struct DictationSession: Codable, Equatable, Sendable {
    public let paragraphs: [[UUID]]
    public let grades: [UUID: PracticeGrade]
    public let startedAt: Date
    public init(paragraphs: [[UUID]], grades: [UUID: PracticeGrade], startedAt: Date = Date()) {
        self.paragraphs = paragraphs; self.grades = grades; self.startedAt = startedAt
    }
    public var wordCount: Int { paragraphs.reduce(0) { $0 + $1.count } }
    public var answeredCount: Int { min(grades.count, wordCount) }
    public var isFinished: Bool { answeredCount >= wordCount }
}

public enum DictationSessionStore {
    private static func key(_ transcriptID: UUID) -> String { "dictationSession.\(transcriptID.uuidString)" }
    public static func load(for transcriptID: UUID, defaults: UserDefaults = .standard) -> DictationSession? {
        guard let data = defaults.data(forKey: key(transcriptID)) else { return nil }
        return try? JSONDecoder().decode(DictationSession.self, from: data)
    }
    public static func save(_ session: DictationSession, for transcriptID: UUID, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        defaults.set(data, forKey: key(transcriptID))
    }
    public static func clear(for transcriptID: UUID, defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key(transcriptID)) }
}
