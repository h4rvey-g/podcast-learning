import Foundation
import SwiftData
import Testing
@testable import PodcastCore

@Test func answerNormalization() {
    #expect(AnswerChecker.matches("  IT’S\n", answer: "it's"))
    #expect(!AnswerChecker.matches("ability", answer: "abilities"))
    #expect(!AnswerChecker.matches("keep  time", answer: "keep time"))
}

@Test func hintLadder() {
    #expect(HintMask.make("a") == "a")
    #expect(HintMask.make("at") == "a t")
    #expect(HintMask.make("cat") == "c _ t")
    #expect(HintMask.make("important") == "i _ _ o _ _ a _ t")
    #expect(HintMask.make("it's ok!").contains("'"))
    #expect(HintMask.make("") == "")
}

@Test func clozeHidesLengthAndUsesWholeWords() {
    #expect(HintMask.cloze("The music was profound.", answer: "profound") == "The music was ________.")
    #expect(HintMask.cloze("We are keeping time.", answer: "keeping time") == "We are ________.")
    #expect(HintMask.cloze("The musician played music.", answer: "music") == "The musician played ________.")
    #expect(HintMask.cloze("Ability matters.", answer: "ability") == "________ matters.")
    #expect(HintMask.cloze("Music, music, musician.", answer: "music") == "________, ________, musician.")
    #expect(HintMask.cloze("🎵 Café: café.", answer: "café") == "🎵 ________: ________.")
}

@Test func attemptStateMachine() {
    var attempt = DictationAttempt()
    #expect(attempt.check("wrong", answer: "right") == nil)
    #expect(attempt.phase == .second)
    #expect(attempt.check("RIGHT", answer: "right") == .secondTry)
    #expect(attempt.check("right", answer: "right") == nil)
    #expect(attempt.reveal() == nil)
    var first = DictationAttempt()
    #expect(first.check("right", answer: "right") == .firstTry)
    var missed = DictationAttempt()
    #expect(missed.check("no", answer: "yes") == nil)
    #expect(missed.check("no", answer: "yes") == .revealed)
    var skipped = DictationAttempt()
    #expect(skipped.reveal() == .revealed)
}

@Test func leitnerTransitions() {
    #expect(Leitner.nextBox(1, grade: .firstTry) == 2)
    #expect(Leitner.nextBox(5, grade: .firstTry) == 5)
    #expect(Leitner.nextBox(3, grade: .secondTry) == 3)
    #expect(Leitner.nextBox(5, grade: .revealed) == 1)
    let now = Date(timeIntervalSince1970: 1_000_000)
    for box in 1...5 { #expect(Leitner.dueDate(box: box, now: now).timeIntervalSince(now) == Double(1 << (box - 1)) * 86400) }
}

@MainActor @Test func memoryRecordingAndDeduplication() throws {
    let container = try testContainer()
    let context = container.mainContext
    let old = WordMemory(key: "music"), recent = WordMemory(key: "music")
    old.lastPracticedAt = Date(timeIntervalSince1970: 10)
    context.insert(old); context.insert(recent)
    Leitner.record(recent, grade: .firstTry, now: Date(timeIntervalSince1970: 100))
    try context.save()
    let memories = try Leitner.memories(in: context)
    #expect(memories.count == 1)
    #expect(memories["music"]?.box == 2)
    #expect(recent.attempts == 1 && recent.correct == 1)
    try context.save()
    #expect(try context.fetchCount(FetchDescriptor<WordMemory>()) == 1)
}

@MainActor @Test func queuePrioritizesDueLowBoxesAndSkipsMastered() {
    let a = DictationItem(text: "a", key: "a"), b = DictationItem(text: "b", key: "b"), c = DictationItem(text: "c", key: "c"), removed = DictationItem(text: "d", key: "d")
    let mastered = WordMemory(key: "c"); mastered.box = 5
    let later = WordMemory(key: "b"); later.dueAt = .distantFuture
    removed.isRemoved = true
    let memories = ["b": later, "c": mastered]
    #expect(Leitner.queue([b, c, a, removed], memories: memories, includeMastered: false).map(\.key) == ["a", "b"])
    #expect(Leitner.queue([b, c, a, removed], memories: memories, includeMastered: true).map(\.key) == ["a", "c", "b"])
}

@MainActor func testContainer() throws -> ModelContainer {
    try ModelContainer(for: LearningSchema.schema, configurations: ModelConfiguration(schema: LearningSchema.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
}
