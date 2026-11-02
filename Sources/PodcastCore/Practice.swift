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
    public static func make(_ text: String) -> String {
        let letters = Array(text)
        let positions = letters.indices.filter { letters[$0].isLetter }
        return letters.indices.map { i in
            guard letters[i].isLetter else { return String(letters[i]) }
            return i == positions.first || i == positions.last || i.isMultiple(of: 3) ? String(letters[i]) : "_"
        }.joined(separator: " ")
    }
    public static func cloze(_ sentence: String, answer: String, hint: Bool = false) -> String {
        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let regex = try? NSRegularExpression(pattern: TextMatch.pattern(for: answer), options: .caseInsensitive) else { return sentence }
        let replacement = hint ? make(answer) : "________"
        return regex.stringByReplacingMatches(in: sentence, range: NSRange(sentence.startIndex..., in: sentence),
                                               withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}

public enum PracticeGrade: Int, Sendable { case firstTry, secondTry, revealed }

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
    @MainActor public static func queue(_ items: [DictationItem], memories: [String: WordMemory], includeMastered: Bool, now: Date = Date()) -> [DictationItem] {
        items.filter { !$0.isRemoved && (includeMastered || (memories[$0.key]?.box ?? 1) < 5) }.sorted {
            let a = memories[$0.key], b = memories[$1.key]
            let aDue = (a?.dueAt ?? .distantPast) <= now, bDue = (b?.dueAt ?? .distantPast) <= now
            if aDue != bDue { return aDue }
            if (a?.box ?? 1) != (b?.box ?? 1) { return (a?.box ?? 1) < (b?.box ?? 1) }
            return ($0.sentence?.index ?? 0) < ($1.sentence?.index ?? 0)
        }
    }
}

public enum TextMatch {
    public static func range(of phrase: String, in text: String) -> Range<String.Index>? {
        guard !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text.range(of: pattern(for: phrase), options: [.regularExpression, .caseInsensitive])
    }
    public static func pattern(for phrase: String) -> String {
        "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: phrase) + "(?![\\p{L}\\p{N}])"
    }
}

public struct DictationAttempt: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case first, second, answered(PracticeGrade) }
    public private(set) var phase: Phase = .first
    public init() {}
    @discardableResult public mutating func check(_ input: String, answer: String) -> PracticeGrade? {
        guard case .answered = phase else {
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
}
