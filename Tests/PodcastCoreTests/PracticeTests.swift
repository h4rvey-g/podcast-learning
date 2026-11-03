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
    #expect(Leitner.queue([b, c, a, removed], memories: memories, includeMastered: false).flatMap(\.items).map(\.key) == ["a", "b"])
    #expect(Leitner.queue([b, c, a, removed], memories: memories, includeMastered: true).flatMap(\.items).map(\.key) == ["a", "c", "b"])
}

@MainActor func testContainer() throws -> ModelContainer {
    try ModelContainer(for: LearningSchema.schema, configurations: ModelConfiguration(schema: LearningSchema.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none))
}

@MainActor @Test func wordsInOneParagraphArePracticedTogether() {
    let paragraph = Segment(index: 0, text: "Music felt profoundly different. We were keeping time.")
    let first = Sentence(index: 0, text: "Music felt profoundly different.")
    let second = Sentence(index: 1, text: "We were keeping time.")
    first.segment = paragraph; second.segment = paragraph
    let a = DictationItem(text: "profoundly", key: "profoundly", sentence: first)
    let b = DictationItem(text: "keeping time", key: "keep time", sentence: second)
    let other = DictationItem(text: "other", key: "other")
    #expect(Leitner.queue([b, other, a], memories: [:], includeMastered: false).count == 2)
}

@MainActor @Test func paragraphBlanksFollowReadingOrderAndKeepHintsSeparate() {
    let segment = Segment(index: 0, text: "Music felt profoundly different. We were keeping time, keeping time.")
    let first = Sentence(index: 0, text: "Music felt profoundly different.")
    let second = Sentence(index: 1, text: "We were keeping time, keeping time.")
    first.segment = segment; second.segment = segment
    let a = DictationItem(text: "profoundly", key: "profoundly", sentence: first)
    let b = DictationItem(text: "keeping time", key: "keep time", sentence: second)
    let queue = Leitner.queue([b, a], memories: [:], includeMastered: false)
    #expect(queue.count == 1)
    #expect(queue[0].items.map(\.id) == [a.id, b.id])
    #expect(queue[0].cloze() == "Music felt ________ different. We were ________, ________.")
    #expect(queue[0].cloze(completed: [b.id]) == "Music felt ________ different. We were keeping time, keeping time.")
    #expect(HintMask.tiles("keeping time").count == "keeping time".count)
}

@MainActor @Test func paragraphAttemptsGradeIndividuallyAndNeverRepeatCompletedWords() {
    let a = DictationItem(text: "profoundly", key: "profoundly")
    let b = DictationItem(text: "keeping time", key: "keep time")
    let c = DictationItem(text: "rhythm", key: "rhythm")
    let items = [a, b, c]
    var attempt = ParagraphAttempt()
    #expect(attempt.check([a.id: "profoundly"], items: items).isEmpty)
    #expect(attempt.phase(a.id) == .first) // Incomplete paragraphs consume no attempts.
    let first = attempt.check([a.id: "profoundly", b.id: "keeping", c.id: "rythm"], items: items)
    #expect(first == [a.id: .firstTry])
    #expect(attempt.phase(b.id) == .second && attempt.phase(c.id) == .second)
    let second = attempt.check([b.id: "keeping time", c.id: "wrong"], items: items)
    #expect(second == [b.id: .secondTry, c.id: .revealed])
    #expect(attempt.grade(a.id) == .firstTry)
    #expect(attempt.check([:], items: items, reveal: true).isEmpty)
    var revealed = ParagraphAttempt()
    _ = revealed.check([a.id: "profoundly", b.id: "wrong"], items: [a, b])
    #expect(revealed.check([:], items: [a, b], reveal: true) == [b.id: .revealed])
}

@MainActor @Test func paragraphsStaySeparateAndMasteredWordsStayOut() {
    let a = DictationItem(text: "music", key: "music")
    let b = DictationItem(text: "rhythm", key: "rhythm")
    let c = DictationItem(text: "time", key: "time")
    let segment = Segment(index: 0, text: "Music rhythm time")
    let sentence = Sentence(index: 0, text: segment.text); sentence.segment = segment
    a.sentence = sentence; b.sentence = sentence; c.sentence = sentence
    let memory = WordMemory(key: b.key); memory.box = 5
    c.isRemoved = true
    #expect(Leitner.queue([a,b,c], memories: [b.key: memory], includeMastered: false).flatMap(\.items).map(\.id) == [a.id])
    #expect(Leitner.queue([a,b,c], memories: [b.key: memory], includeMastered: true).flatMap(\.items).map(\.id) == [a.id,b.id])
    let phrase = DictationItem(text: "keeping time", key: "keep time")
    let word = DictationItem(text: "time", key: "time")
    let overlapping = Sentence(index: 0, text: "We were keeping time."); phrase.sentence = overlapping; word.sentence = overlapping
    let paragraph = PracticeParagraph(items: [phrase,word])
    #expect(paragraph.cloze() == "We were ________.")
    #expect(paragraph.cloze(completed: [phrase.id]) == "We were keeping ________.")
}

@Test func attemptsKeepHistoryWithoutRecordingAfterCompletion() {
    var attempt = DictationAttempt()
    #expect(attempt.check("profund", answer: "profoundly") == nil)
    #expect(attempt.check("profundly", answer: "profoundly") == .revealed)
    #expect(attempt.inputs == ["profund", "profundly"])
    _ = attempt.check("profoundly", answer: "profoundly")
    _ = attempt.reveal()
    #expect(attempt.inputs == ["profund", "profundly"])
}

@MainActor @Test func singleBlankKeepsTheSimpleLayoutAndParagraphHistoryIsPerWord() {
    let sentence = Sentence(index: 0, text: "The music felt profoundly different.")
    let item = DictationItem(text: "profoundly", key: "profoundly", sentence: sentence)
    #expect(PracticeParagraph(items: [item]).cloze() == "The music felt ________ different.")
    #expect(PracticeParagraph(items: [item]).cloze(completed: [item.id]) == sentence.text)
    var attempt = ParagraphAttempt()
    _ = attempt.check([item.id: "profund"], items: [item])
    _ = attempt.check([item.id: "profoundly"], items: [item])
    #expect(attempt.inputs(item.id) == ["profund", "profoundly"])
    #expect(attempt.inputs(UUID()).isEmpty)
}

@MainActor @Test func retryQueueIncludesOnlyMissedWordsEvenIfNowMastered() throws {
    let container = try testContainer(), context = container.mainContext
    let transcript = TextImporter.makeTranscript(title: "Retry", paragraphs: ["Music felt profoundly different. We were keeping time."])
    context.insert(transcript)
    let first = DictationItem(text: "Music", key: "music", sentence: transcript.sentences[0])
    let second = DictationItem(text: "profoundly", key: "profoundly", sentence: transcript.sentences[0])
    let revealed = DictationItem(text: "keeping time", key: "keep time", sentence: transcript.sentences[1])
    transcript.items = [first, second, revealed]
    let memory = WordMemory(key: second.key); memory.box = 5; context.insert(memory)
    let originalReview = Date(timeIntervalSince1970: 1234)
    memory.lastPracticedAt = originalReview
    try context.save()
    let results = [PracticeResult(item: first, grade: .firstTry), PracticeResult(item: second, grade: .secondTry), PracticeResult(item: revealed, grade: .revealed)]
    let retry = Leitner.retryQueue(results, memories: [second.key: memory])
    #expect(retry.count == 1)
    #expect(retry[0].items.map(\.id) == [second.id, revealed.id])
    #expect(memory.box == 5 && memory.lastPracticedAt == originalReview) // Building a retry never regrades saved work.
    revealed.isRemoved = true
    #expect(Leitner.retryQueue(results, memories: [:]).flatMap(\.items).map(\.id) == [second.id])
    #expect(Leitner.retryQueue([results[0]], memories: [:]).isEmpty)
}

@Test func retryLettersTypeAndPasteOnlyIntoMissingCells() {
    var retry = RetryLetters(answer: "profoundly")
    #expect(retry.value == nil)
    #expect(retry.firstEmptyIndex == 1)
    #expect(retry.replace(at: 0, with: "x") == nil)
    #expect(retry.letters[0] == "p")
    #expect(retry.replace(at: 1, with: "r") == 2)
    #expect(retry.replace(at: 2, with: "o") == 4)
    #expect(retry.replace(at: 4, with: "ou dl") == 8)
    #expect(retry.value == "profoundly")
    #expect(retry.replace(at: 8, with: "z") == 8)
    #expect(retry.value == "profoundzy")
    _ = retry.replace(at: 1, with: "PROFOUNDLY")
    #expect(AnswerChecker.matches(retry.value!, answer: "profoundly"))
    #expect(retry.letters[3] == "f")
}

@Test func retryLettersBackspaceSkipsFixedHints() {
    var retry = RetryLetters(answer: "profoundly")
    _ = retry.replace(at: 1, with: "ro")
    #expect(retry.backspace(at: 4) == 2)
    #expect(retry.letters[2] == "")
    #expect(retry.letters[3] == "f")
    #expect(retry.backspace(at: 2) == 1)
    #expect(retry.letters[1] == "")
    #expect(retry.backspace(at: 1) == 1)
    #expect(retry.backspace(at: 0) == nil)
    #expect(retry.value == nil)
}

@Test func retryLettersKeepPhraseSpacesPunctuationAndShortWordHints() {
    var retry = RetryLetters(answer: "keeping time")
    _ = retry.replace(at: retry.firstEmptyIndex!, with: "KEEPING TIME")
    #expect(AnswerChecker.matches(retry.value!, answer: "keeping time"))
    #expect(retry.letters[7] == " ")
    var apostrophe = RetryLetters(answer: "it's okay")
    _ = apostrophe.replace(at: apostrophe.firstEmptyIndex!, with: "it's okay")
    #expect(apostrophe.value == "it's okay")
    #expect(apostrophe.letters[2] == "'")
    var underscore = RetryLetters(answer: "foo_bar")
    _ = underscore.replace(at: underscore.firstEmptyIndex!, with: "foo_bar")
    #expect(underscore.value == "foo_bar")
    #expect(!underscore.editableIndices.contains(3))
    #expect(RetryLetters(answer: "at").value == "at")
    #expect(RetryLetters(answer: "at").firstEmptyIndex == nil)
    #expect(RetryLetters(answer: "").value == nil)
}

@MainActor @Test func inlineRetryRetainsTheFirstWrongAttemptAndGradesTheAssembledWord() {
    let item = DictationItem(text: "profoundly", key: "profoundly")
    var attempt = ParagraphAttempt()
    _ = attempt.check([item.id: "profund"], items: [item])
    var retry = RetryLetters(answer: item.text)
    #expect(retry.value == nil)
    #expect(attempt.inputs(item.id) == ["profund"])
    _ = retry.replace(at: retry.firstEmptyIndex!, with: "rooudl")
    #expect(retry.value == "profoundly")
    #expect(attempt.check([item.id: retry.value!], items: [item]) == [item.id: .secondTry])
    #expect(attempt.inputs(item.id) == ["profund", "profoundly"])
}

@MainActor @Test func inlineParagraphPartsPreserveContextUnicodeAndRepeatedBlanks() {
    let segment = Segment(index: 0, text: "🎵 Music felt profoundly different. We were keeping time, keeping time.")
    let sentence = Sentence(index: 0, text: segment.text); sentence.segment = segment
    let word = DictationItem(text: "profoundly", key: "profoundly", sentence: sentence)
    let phrase = DictationItem(text: "keeping time", key: "keep time", sentence: sentence)
    let paragraph = PracticeParagraph(items: [word, phrase])
    #expect(paragraph.parts().map(\.text).joined() == segment.text)
    #expect(paragraph.parts().compactMap(\.item).map(\.id) == [word.id, phrase.id, phrase.id])
    #expect(paragraph.parts(completed: [word.id]).compactMap(\.item).map(\.id) == [phrase.id, phrase.id])
    #expect(paragraph.parts(completed: [word.id, phrase.id]).allSatisfy { $0.item == nil })
}

@MainActor @Test func overlappingInlineBlanksBecomeEditableWithoutRegradingCompletedItems() {
    let sentence = Sentence(index: 0, text: "We were keeping time.")
    let phrase = DictationItem(text: "keeping time", key: "keep time", sentence: sentence)
    let word = DictationItem(text: "time", key: "time", sentence: sentence)
    let paragraph = PracticeParagraph(items: [phrase, word])
    var attempt = ParagraphAttempt()
    let first = paragraph.parts().compactMap(\.item)
    #expect(first.map(\.id) == [phrase.id])
    #expect(attempt.check([phrase.id: "keeping time"], items: first) == [phrase.id: .firstTry])
    let remaining = paragraph.parts(completed: [phrase.id]).compactMap(\.item)
    #expect(remaining.map(\.id) == [word.id])
    #expect(attempt.check([word.id: "time"], items: remaining) == [word.id: .firstTry])
    #expect(attempt.inputs(phrase.id) == ["keeping time"])
}
