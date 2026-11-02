import SwiftUI
import PodcastCore

private struct PracticeResult: Identifiable {
    let id = UUID()
    let item: DictationItem
    let grade: PracticeGrade
}

struct DictationView: View {
    let transcript: Transcript
    let includeMastered: Bool
    @Environment(AppStore.self) private var store
    @Environment(SettingsStore.self) private var settings
    @Environment(ClipPlayer.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var queue: [DictationItem] = []
    @State private var memories: [String: WordMemory] = [:]
    @State private var index = 0
    @State private var input = ""
    @State private var attempt = DictationAttempt()
    @State private var results: [PracticeResult] = []
    @State private var loaded = false
    @State private var exitConfirmation = false
    @State private var error: String?
    @FocusState private var focused: Bool
    private var current: DictationItem? { queue.indices.contains(index) ? queue[index] : nil }
    private var answered: Bool { if case .answered = attempt.phase { return true }; return false }
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
                        ToolbarItem(placement: .principal) { ProgressView(value: Double(index), total: Double(max(1, queue.count))).frame(maxWidth: 220).tint(Palette.accent) }
                        ToolbarItem(placement: .topBarTrailing) { Text("\(min(index + 1, queue.count)) of \(queue.count)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit() }
                    }
                }
                .confirmationDialog("End this session? Completed answers are saved.", isPresented: $exitConfirmation, titleVisibility: .visible) { Button("End Session", role: .destructive) { dismiss() }; Button("Keep Practicing", role: .cancel) {} }
                .alert("Could Not Save Review", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("Close", role: .cancel) { error = nil } } message: { Text(error ?? "") }
        }
        .task { if !loaded { setup(includeMastered: includeMastered) } }
        .onDisappear { player.stop() }
    }
    private func card(_ item: DictationItem) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                HStack {
                    Text(answered ? "Answer" : attempt.phase == .first ? "First Try" : "Second Try").font(.subheadline.weight(.semibold)).foregroundStyle(Palette.accent)
                    Spacer()
                    if let level = item.level { LevelBadge(level: level) }
                    Text("Box \(memories[item.key]?.box ?? 1)").font(.footnote).foregroundStyle(.secondary)
                }
                Button { replay(item) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 5) {
                            Image(systemName: "waveform").font(.title).foregroundStyle(Palette.accent)
                            Text(audioLabel(item)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("Replay").font(.subheadline)
                    }.card()
                }.buttonStyle(.plain).accessibilityLabel("Replay Context")
                Text(answered ? (item.sentence?.text ?? item.text) : HintMask.cloze(item.sentence?.text ?? item.text, answer: item.text, hint: attempt.phase == .second))
                    .font(.system(.title3, design: .serif)).lineSpacing(8).frame(maxWidth: .infinity, alignment: .leading).card()
                    .accessibilityLabel(answered ? (item.sentence?.text ?? item.text) : HintMask.cloze(item.sentence?.text ?? item.text, answer: item.text, hint: attempt.phase == .second).replacingOccurrences(of: "________", with: "blank"))
                if answered {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(results.last?.grade == .revealed ? "Answer Revealed" : "Correct", systemImage: results.last?.grade == .revealed ? "eye" : "checkmark.circle.fill").foregroundStyle(results.last?.grade == .revealed ? .red : .green).font(.headline)
                        Text(item.text).font(.title2.bold()).foregroundStyle(Palette.accent)
                        if let gloss = item.glossZh { Text(gloss).font(.title3) }
                        if let definition = item.definitionEn { Text(definition).foregroundStyle(.secondary) }
                        Text("Next review: \(memories[item.key]?.dueAt.formatted(date: .abbreviated, time: .omitted) ?? "tomorrow")").font(.footnote).foregroundStyle(.secondary)
                    }.card()
                    PrimaryButton(title: index == queue.count - 1 ? "Finish Session" : "Next Word", symbol: "arrow.right") { next() }
                } else {
                    if attempt.phase == .second { Label("Not quite. Use the letters and try again.", systemImage: "info.circle").font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
                    TextField("Type the missing word or phrase", text: $input)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.asciiCapable)
                        .font(.title3.weight(.semibold)).padding(15).background(Palette.cell, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Palette.accent, lineWidth: 2)).focused($focused).submitLabel(.done).onSubmit { check() }
                        .accessibilityLabel("Your Answer")
                    PrimaryButton(title: "Check") { check() }.disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Reveal Answer") { submit(reveal: true) }.font(.subheadline).padding(4)
                }
            }.padding(16)
        }.scrollDismissesKeyboard(.interactively)
    }
    private var summary: some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 64)).foregroundStyle(.green).padding(.top, 30)
                Text("Session Complete").font(.largeTitle.bold())
                Text("\(results.count) words practiced").foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    metric("First Try", count: results.filter { $0.grade == .firstTry }.count)
                    metric("Second Try", count: results.filter { $0.grade == .secondTry }.count)
                    metric("Revealed", count: results.filter { $0.grade == .revealed }.count)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Text("Keep Practicing").font(.headline)
                    if results.allSatisfy({ $0.grade == .firstTry }) { Text("Every word right on the first try. Nice work!").foregroundStyle(.secondary) }
                    ForEach(results.filter { $0.grade != .firstTry }) { result in
                        HStack { VStack(alignment: .leading) { Text(result.item.text).font(.headline); Text(result.item.glossZh ?? "Review this word in context").font(.subheadline).foregroundStyle(.secondary) }; Spacer(); Button("Play Word", systemImage: "speaker.wave.2") { replay(result.item) }.labelStyle(.iconOnly).frame(width: 44, height: 44) }
                        Divider()
                    }
                }.card()
                PrimaryButton(title: "Back to Transcript") { dismiss() }
            }.padding(20)
        }
    }
    private func metric(_ label: String, count: Int) -> some View {
        VStack(spacing: 6) { Text("\(count)").font(.title.bold()); Text(label).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity).padding(.vertical, 20).background(Palette.cell, in: RoundedRectangle(cornerRadius: 20))
    }
    private func audioLabel(_ item: DictationItem) -> String {
        if AudioStore.localURL(transcript.id) != nil, let start = item.sentence?.segment?.start, let end = item.sentence?.segment?.end { return "Paragraph · \(timestamp(start))–\(timestamp(end))" }
        return "English Text to Speech"
    }
    private func replay(_ item: DictationItem) { player.play(text: item.sentence?.text ?? item.text, segment: item.sentence?.segment, transcript: transcript, settings: settings) }
    private func setup(includeMastered: Bool) {
        do {
            memories = try Leitner.memories(in: store.context)
            queue = Leitner.queue(transcript.activeItems, memories: memories, includeMastered: includeMastered)
            try store.context.save(); loaded = true; focused = true
            if let current { replay(current) }
        } catch { self.error = error.localizedDescription }
    }
    private func check() { guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }; submit(reveal: false) }
    private func submit(reveal: Bool) {
        guard let item = current else { return }
        let previous = attempt
        let grade = reveal ? attempt.reveal() : attempt.check(input, answer: item.text)
        guard let grade else { input = ""; replay(item); return }
        let memory = memories[item.key] ?? WordMemory(key: item.key)
        if memories[item.key] == nil { store.context.insert(memory) }
        Leitner.record(memory, grade: grade)
        do {
            try store.context.save(); memories[item.key] = memory
            results.append(PracticeResult(item: item, grade: grade)); focused = false
        } catch { store.context.rollback(); attempt = previous; self.error = error.localizedDescription }
    }
    private func next() {
        index += 1; input = ""; attempt = DictationAttempt()
        if let current { replay(current); focused = true } else { player.stop(); focused = false }
    }
}
