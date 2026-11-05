import SwiftUI
import PodcastCore

struct DictationView: View {
    @Environment(\.accentTheme) private var theme
    let transcript: Transcript
    let includeMastered: Bool
    @Environment(AppStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(ClipPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var queue: [PracticeParagraph] = []
    @State private var memories: [String: WordMemory] = [:]
    @State private var index = 0
    @State private var inputs: [UUID: String] = [:]
    @State private var retries: [UUID: RetryLetters] = [:]
    @State private var attempt = ParagraphAttempt()
    @State private var results: [PracticeResult] = []
    @State private var sessionStartedAt = Date()
    @State private var completedAt: Date?
    @State private var loaded = false
    @State private var exitConfirmation = false
    @State private var error: String?
    @State private var focused: UUID?
    private var current: PracticeParagraph? { queue.indices.contains(index) ? queue[index] : nil }
    private var answered: Bool { current?.items.allSatisfy { attempt.grade($0.id) != nil } ?? false }
    private var secondTry: Bool { current?.items.contains { attempt.phase($0.id) == .second } ?? false }
    private var editableItems: [DictationItem] {
        guard let current else { return [] }
        let completed = Set(current.items.filter { attempt.grade($0.id) != nil }.map(\.id))
        var seen: Set<UUID> = []
        return current.parts(completed: completed).compactMap(\.item).filter { seen.insert($0.id).inserted }
    }
    private func isFilled(_ item: DictationItem) -> Bool {
        if attempt.phase(item.id) == .second { return (retries[item.id] ?? RetryLetters(answer: item.text)).value != nil }
        return !(inputs[item.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private var canCheck: Bool { !editableItems.isEmpty && editableItems.allSatisfy(isFilled) }
    var body: some View {
        NavigationStack {
            Group {
                if loaded && index >= queue.count && !queue.isEmpty { summary }
                else if let item = current { card(item) }
                else { ContentUnavailableView {
                    Label("Nothing to Practice", systemImage: "checkmark.circle")
                } description: { Text("There are no unmastered items in this transcript. Add words in the reader, or include mastered words.") }
                  actions: { Button("Include Mastered Words") { setup(includeMastered: true) }; Button("Back to Transcript") { dismiss() } }
                }
            }.background(Palette.background)
                .toolbar {
                    if index < queue.count {
                        ToolbarItem(placement: .topBarLeading) { Button("End Session", systemImage: "xmark") { exitConfirmation = true }.labelStyle(.iconOnly) }
                        ToolbarItem(placement: .principal) { ProgressView(value: Double(index), total: Double(max(1, queue.count))).frame(maxWidth: 220).tint(theme.color) }
                        ToolbarItem(placement: .topBarTrailing) { Text("\(min(index + 1, queue.count)) of \(queue.count)").accessibilityLabel("Paragraph \(min(index + 1, queue.count)) of \(queue.count)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit() }
                    }
                }
                .confirmationDialog("End this session? Your answers are saved so you can continue later.", isPresented: $exitConfirmation, titleVisibility: .visible) { Button("End Session", role: .destructive) { dismiss() }; Button("Keep Practicing", role: .cancel) {} }
                .alert("Could Not Save Review", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("Close", role: .cancel) { error = nil } } message: { Text(error ?? "") }
        }
        .task { if !loaded { setup(includeMastered: includeMastered) } }
        .onDisappear { player.stop() }
    }
    private func card(_ paragraph: PracticeParagraph) -> some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack {
                    Text(answered ? "Answer" : secondTry ? "Second Try" : "First Try").font(.subheadline.weight(.semibold)).foregroundStyle(answered && paragraph.items.contains { attempt.grade($0.id) == .revealed } ? .red : theme.color)
                    Spacer()
                    if paragraph.items.count == 1, let item = paragraph.items.first {
                        if let level = item.level { LevelBadge(level: level) }
                        Text("Box \(memories[item.key]?.box ?? 1)").font(.footnote).foregroundStyle(.secondary)
                    } else { Text("\(paragraph.items.count) blanks · One paragraph").font(.footnote).foregroundStyle(.secondary) }
                }
                HStack(spacing: 12) {
                    Button { replay(paragraph) } label: {
                        Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(theme.color).frame(width: 44, height: 44)
                    }.buttonStyle(.plain).accessibilityLabel("Replay Paragraph")
                        .disabled(player.isWaitingForAudio(transcript, settings: settings))
                    VStack(alignment: .leading, spacing: 0) {
                        Waveform(progress: player.progress(in: paragraph.segment), seek: player.canSeek(paragraph, in: transcript) ? { fraction in player.seek(to: fraction, in: paragraph, transcript: transcript, settings: settings) } : nil)
                        Text(audioLabel(paragraph)).font(.caption).foregroundStyle(.secondary)
                    }
                }.card()
                    .alert("Playback Failed", isPresented: Binding(get: { player.error != nil }, set: { if !$0 { player.error = nil } })) { Button("Close", role: .cancel) { player.error = nil } } message: { Text(player.error ?? "") }
                InlineParagraphEditor(paragraph: paragraph, attempt: attempt, inputs: $inputs, retries: $retries, focused: $focused) { advanceFocus(after: $0) }.card()
                if answered { ForEach(paragraph.items) { answerFeedback($0) } }
                if !answered {
                    Text(secondTry ? "Fill the underscores in the paragraph. Given letters stay fixed." : "Tap a blank and type in the paragraph. Check all blanks together.").font(.footnote).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(16)
        }.scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom) {
                if answered { PrimaryButton(title: index == queue.count - 1 ? "Finish Session" : "Next Paragraph", symbol: "arrow.right") { next() }.padding(16) }
                else {
                    VStack(spacing: 6) {
                        PrimaryButton(title: secondTry ? "Check Again" : "Check") { submit(reveal: false) }.disabled(!canCheck)
                        // Kept above the keyboard so giving up mid-paragraph never needs a scroll.
                        Button("Reveal Remaining Answers", systemImage: "eye") { submit(reveal: true) }.font(.subheadline).frame(minHeight: 44)
                    }.padding(16)
                }
            }
    }
    @ViewBuilder private func answerFeedback(_ item: DictationItem) -> some View {
        if let grade = attempt.grade(item.id) {
            VStack(alignment: .leading, spacing: 8) {
                Label(grade == .revealed ? "Answer Revealed" : "Correct", systemImage: grade == .revealed ? "eye" : "checkmark.circle.fill")
                    .foregroundStyle(grade == .revealed ? .red : .green).font(.subheadline.weight(.semibold))
                HStack {
                    Text(item.text).font(.system(.title2, design: .serif).bold())
                    if let level = item.level { LevelBadge(level: level) }
                    Button("Pronounce", systemImage: "speaker.wave.2") { player.play(text: item.text, settings: settings) }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                }
                if let gloss = item.glossZh { Text(gloss) }
                if let definition = item.definitionEn { Text(definition).foregroundStyle(.secondary) }
                let wrongInputs = attempt.inputs(item.id).filter { !AnswerChecker.matches($0, answer: item.text) }
                if !wrongInputs.isEmpty {
                    (Text("Your tries: ").foregroundColor(.secondary) + Text(wrongInputs.joined(separator: "  ")).strikethrough().foregroundColor(.red)).font(.footnote)
                }
                Text("Next review: \(memories[item.key]?.dueAt.formatted(date: .abbreviated, time: .omitted) ?? "tomorrow")").font(.footnote).foregroundStyle(.secondary)
            }.card()
        }
    }
    private func focusFirstUnfinished() {
        focused = editableItems.first { item in attempt.phase(item.id) != .second || !(retries[item.id] ?? RetryLetters(answer: item.text)).editableIndices.isEmpty }?.id
    }
    private func advanceFocus(after item: DictationItem) {
        guard let position = editableItems.firstIndex(where: { $0.id == item.id }) else { return }
        if let next = editableItems.dropFirst(position + 1).first { focused = next.id }
        else if canCheck { submit(reveal: false) }
        else { focused = editableItems.first(where: { !isFilled($0) })?.id }
    }
    private var missed: [PracticeResult] { results.filter { $0.grade != .firstTry } }
    private var summary: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "party.popper").font(.system(size: 38)).foregroundStyle(.green).frame(width: 88, height: 88).background(.green.opacity(0.12), in: Circle()).padding(.top, 36)
                VStack(spacing: 8) {
                    Text("Session Complete").font(.title2.bold())
                    Text("\(results.count) words in \(Duration.seconds(Int((completedAt ?? Date()).timeIntervalSince(sessionStartedAt))).formatted(.units(allowed: [.minutes, .seconds], width: .wide)))").font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    metric("First Try", symbol: "checkmark.circle", color: .green, count: results.filter { $0.grade == .firstTry }.count)
                    metric("Second Try", symbol: "lightbulb", color: theme.color, count: results.filter { $0.grade == .secondTry }.count)
                    metric("Shown", symbol: "eye", color: .red, count: results.filter { $0.grade == .revealed }.count)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Missed Words").font(.footnote.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 16)
                    VStack(spacing: 0) {
                        if missed.isEmpty { Text("Every word right on the first try. Nice work!").foregroundStyle(.secondary).padding() }
                        ForEach(missed) { result in
                            ItemSummaryRow(item: result.item, memory: memories[result.item.key]).padding(.horizontal, 16)
                            if result.id != missed.last?.id { Divider().padding(.leading, 48) }
                        }
                    }.background(Palette.cell, in: RoundedRectangle(cornerRadius: 22))
                }
            }.padding(.horizontal, 16).padding(.bottom, 20)
        }.safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if !missed.isEmpty { PrimaryButton(title: "Practice Missed Words", symbol: "repeat") { restartMissed() } }
                Button("Done") { dismiss() }.font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15).foregroundStyle(.primary).background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            }.padding(16)
        }
    }
    private func metric(_ label: String, symbol: String, color: Color, count: Int) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color)
            Text("\(count)").font(.largeTitle.bold())
            Text(label).font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 16).background(Palette.cell, in: RoundedRectangle(cornerRadius: 22))
    }
    private func restartMissed() {
        do {
            memories = try Leitner.memories(in: store.context)
            let retry = Leitner.retryQueue(results, memories: memories)
            try store.context.save()
            queue = retry; index = 0; inputs = [:]; retries = [:]; attempt = ParagraphAttempt(); results = []
            sessionStartedAt = Date(); completedAt = nil
            focusFirstUnfinished()
            if let current { replay(current) }
        } catch { self.error = error.localizedDescription }
    }
    private func audioLabel(_ paragraph: PracticeParagraph) -> String {
        if player.isWaitingForAudio(transcript, settings: settings) { return "AI audio not ready · Wait or retry in the reader" }
        if !store.downloading.contains(transcript.id), AudioStore.localURL(transcript.id) != nil, let start = paragraph.segment?.start, let end = paragraph.segment?.end { return "Paragraph · \(timestamp(start))–\(timestamp(end))" }
        return "Paragraph · English Text to Speech"
    }
    private func replay(_ paragraph: PracticeParagraph) { player.play(text: paragraph.text, segment: paragraph.segment, transcript: transcript, settings: settings) }
    private func setup(includeMastered: Bool) {
        do {
            memories = try Leitner.memories(in: store.context)
            if let saved = DictationSessionStore.load(for: transcript.id)?.filtered(to: Set(transcript.practiceItems.map(\.id))), !saved.isFinished, let resumed = resume(saved) {
                queue = resumed.paragraphs; results = resumed.results; index = resumed.index; sessionStartedAt = saved.startedAt
                attempt.restore(saved.grades)
            } else {
                queue = Leitner.queue(transcript.practiceItems, memories: memories, includeMastered: includeMastered)
                try store.context.save()
            }
            loaded = true; focusFirstUnfinished()
            if let current { replay(current) } else { player.stop() }
        } catch { self.error = error.localizedDescription }
    }
    private func resume(_ saved: DictationSession) -> (paragraphs: [PracticeParagraph], results: [PracticeResult], index: Int)? {
        let items = Dictionary(transcript.practiceItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let paragraphs = saved.paragraphs.compactMap { ids -> PracticeParagraph? in
            let found = ids.compactMap { items[$0] }
            return found.isEmpty ? nil : PracticeParagraph(items: found)
        }
        guard !paragraphs.isEmpty else { return nil }
        let results = paragraphs.flatMap(\.items).compactMap { item in saved.grades[item.id].map { PracticeResult(item: item, grade: $0) } }
        let index = paragraphs.firstIndex { $0.items.contains { saved.grades[$0.id] == nil } } ?? paragraphs.count
        return (paragraphs, results, index)
    }
    private func saveSession() {
        var grades: [UUID: PracticeGrade] = [:]
        for result in results { grades[result.item.id] = result.grade }
        DictationSessionStore.save(DictationSession(paragraphs: queue.map { $0.items.map(\.id) }, grades: grades, startedAt: sessionStartedAt), for: transcript.id)
    }
    private func submit(reveal: Bool) {
        guard let paragraph = current, !answered, reveal || canCheck else { return }
        let previous = attempt
        var submitted = inputs
        for item in editableItems where attempt.phase(item.id) == .second { submitted[item.id] = (retries[item.id] ?? RetryLetters(answer: item.text)).value }
        // Overlapping items become visible after their enclosing blank is completed.
        let grades = attempt.check(submitted, items: reveal ? paragraph.items : editableItems, reveal: reveal)
        var updated = memories
        for item in paragraph.items {
            guard let grade = grades[item.id] else { continue }
            let memory = updated[item.key] ?? WordMemory(key: item.key)
            if updated[item.key] == nil { store.context.insert(memory) }
            Leitner.record(memory, grade: grade); updated[item.key] = memory
        }
        do {
            try store.context.save(); memories = updated
            results += paragraph.items.compactMap { item in grades[item.id].map { PracticeResult(item: item, grade: $0) } }
            for item in paragraph.items where attempt.phase(item.id) == .second && retries[item.id] == nil { retries[item.id] = RetryLetters(answer: item.text) }
            saveSession()
            focusFirstUnfinished()
            if !answered { replay(paragraph) }
        } catch { store.context.rollback(); attempt = previous; self.error = error.localizedDescription }
    }
    private func next() {
        index += 1; inputs = [:]; retries = [:]; attempt = ParagraphAttempt()
        if index >= queue.count { completedAt = Date(); DictationSessionStore.clear(for: transcript.id) }
        focusFirstUnfinished()
        if let current { replay(current) } else { player.stop() }
    }
}
