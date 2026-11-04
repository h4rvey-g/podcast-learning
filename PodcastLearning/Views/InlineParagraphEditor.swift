import SwiftUI
import UIKit
import PodcastCore

struct InlineParagraphEditor: UIViewRepresentable {
    let paragraph: PracticeParagraph
    let attempt: ParagraphAttempt
    @Binding var inputs: [UUID: String]
    @Binding var retries: [UUID: RetryLetters]
    @Binding var focused: UUID?
    let advance: (DictationItem) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accentTheme) private var theme

    struct Snapshot: Equatable {
        let text: String
        let words: [String]
        let ids: [UUID]
        let attempt: ParagraphAttempt
        let inputs: [UUID: String]
        let retries: [UUID: RetryLetters]
        let focus: UUID?
        let typeSize: DynamicTypeSize
        let scheme: ColorScheme
        let contrast: ColorSchemeContrast
        let theme: AccentTheme
    }
    private var snapshot: Snapshot {
        Snapshot(text: paragraph.text, words: paragraph.items.map(\.text), ids: paragraph.items.map(\.id), attempt: attempt, inputs: inputs, retries: retries, focus: focused, typeSize: typeSize, scheme: colorScheme, contrast: contrast, theme: theme)
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear; view.isScrollEnabled = false
        view.textContainerInset = .zero; view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.keyboardType = .asciiCapable; view.autocapitalizationType = .none; view.autocorrectionType = .no
        view.spellCheckingType = .no; view.smartQuotesType = .no; view.smartDashesType = .no
        view.returnKeyType = .done
        view.accessibilityLabel = "Dictation paragraph"
        view.accessibilityHint = "Tap a blank to type directly in the paragraph. On the second try, given letters are fixed."
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        if coordinator.requestedFocus != focused { coordinator.target = nil; coordinator.requestedFocus = focused }
        // Playback ticks must not reset the native editor's selection or composition.
        if coordinator.lastRender != snapshot { coordinator.render(view) }
        if focused != nil && !view.isFirstResponder {
            DispatchQueue.main.async { [weak view, weak coordinator] in
                guard let view, view.window != nil, coordinator?.parent.focused != nil, view.isEditable else { return }
                view.becomeFirstResponder()
            }
        }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 320
        return CGSize(width: width, height: ceil(uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        struct Region {
            let id: UUID
            let occurrence: Int
            let letter: Int?
            let range: NSRange
            let placeholder: Bool
        }
        struct Target: Equatable { let id: UUID; let occurrence: Int; let letter: Int?; var offset = 0; var length = 0 }
        var parent: InlineParagraphEditor
        var requestedFocus: UUID?
        var target: Target?
        var lastRender: Snapshot?
        private var regions: [Region] = []
        private var rendering = false
        init(_ parent: InlineParagraphEditor) { self.parent = parent }

        func render(_ view: UITextView) {
            guard !rendering else { return }
            rendering = true; defer { rendering = false }
            let body = UIFont.preferredFont(forTextStyle: .title3, compatibleWith: view.traitCollection)
            let serif = UIFont(descriptor: body.fontDescriptor.withDesign(.serif) ?? body.fontDescriptor, size: 0)
            let strong = UIFont(descriptor: serif.fontDescriptor.withSymbolicTraits(.traitBold) ?? serif.fontDescriptor, size: 0)
            let style = NSMutableParagraphStyle(); style.lineSpacing = 8
            let base: [NSAttributedString.Key: Any] = [.font: serif, .foregroundColor: UIColor.label, .paragraphStyle: style]
            let accent = UIColor(parent.theme.color).resolvedColor(with: view.traitCollection)
            let result = NSMutableAttributedString(string: "")
            let completed = Set(parent.paragraph.items.filter { parent.attempt.grade($0.id) != nil }.map(\.id))
            var speech: [String] = []
            let parts = parent.paragraph.parts(completed: completed)
            if let current = target {
                let item = parts.indices.contains(current.occurrence) ? parts[current.occurrence].item : nil
                let retrying = parent.attempt.phase(current.id) == .second
                if item?.id != current.id || retrying != (current.letter != nil) { target = nil }
            }
            if target == nil, let id = parent.focused, let occurrence = parts.firstIndex(where: { $0.item?.id == id }), let item = parts[occurrence].item {
                let retry = parent.retries[id] ?? RetryLetters(answer: item.text)
                let letter = parent.attempt.phase(id) == .second ? retry.firstEmptyIndex ?? retry.editableIndices.first : nil
                target = Target(id: id, occurrence: occurrence, letter: letter, offset: (parent.inputs[id] ?? "").utf16.count)
            }
            regions = []
            for (occurrence, part) in parts.enumerated() {
                guard let item = part.item else {
                    let text = NSMutableAttributedString(string: part.text, attributes: base)
                    for match in TextMatch.highlights(in: part.text, items: parent.paragraph.items.filter { completed.contains($0.id) }) {
                        text.addAttributes([.foregroundColor: parent.attempt.grade(match.item.id) == .revealed ? UIColor.systemRed : UIColor.systemGreen, .font: strong], range: NSRange(match.range, in: part.text))
                    }
                    result.append(text); speech.append(part.text); continue
                }
                let number = (parent.paragraph.items.firstIndex { $0.id == item.id } ?? 0) + 1
                if parent.attempt.phase(item.id) == .second {
                    let retry = parent.retries[item.id] ?? RetryLetters(answer: item.text)
                    speech.append("blank \(number): " + retry.letters.map { $0.isEmpty ? "blank" : $0 }.joined(separator: " "))
                    for index in retry.hints.indices {
                        let editable = retry.editableIndices.contains(index)
                        let value = retry.letters[index].isEmpty ? "_" : retry.letters[index]
                        let location = result.length
                        result.append(NSAttributedString(string: value, attributes: [.font: editable ? serif : strong, .foregroundColor: editable ? UIColor.label : accent, .paragraphStyle: style]))
                        if editable { regions.append(Region(id: item.id, occurrence: occurrence, letter: index, range: NSRange(location: location, length: value.utf16.count), placeholder: false)) }
                    }
                } else {
                    let value = parent.inputs[item.id] ?? "", placeholder = value.isEmpty
                    let text = placeholder ? "________" : value
                    let range = NSRange(location: result.length, length: text.utf16.count)
                    result.append(NSAttributedString(string: text, attributes: [.font: serif, .foregroundColor: placeholder ? accent : UIColor.label, .underlineStyle: placeholder ? 0 : NSUnderlineStyle.single.rawValue, .underlineColor: accent, .paragraphStyle: style]))
                    regions.append(Region(id: item.id, occurrence: occurrence, letter: nil, range: range, placeholder: placeholder))
                    speech.append("blank \(number): " + (placeholder ? "empty" : value))
                }
            }
            view.attributedText = result; view.isEditable = !regions.isEmpty
            view.accessibilityValue = speech.joined()
            if !regions.contains(where: matchesTarget), let id = parent.focused {
                let firstEmpty = parent.retries[id]?.firstEmptyIndex
                let region = regions.first { $0.id == id && $0.letter == firstEmpty } ?? regions.first { $0.id == id }
                target = region.map { Target(id: $0.id, occurrence: $0.occurrence, letter: $0.letter, offset: $0.range.length) }
            }
            if let region = regions.first(where: matchesTarget) {
                view.tintColor = accent
                let offset = region.letter == nil ? min(target?.offset ?? 0, region.range.length) : 0
                view.selectedRange = region.placeholder ? region.range : NSRange(location: region.range.location + offset, length: region.letter == nil ? min(target?.length ?? 0, region.range.length - offset) : 0)
            }
            var seen: Set<UUID> = []
            view.accessibilityCustomActions = regions.filter { seen.insert($0.id).inserted }.map { region in
                let number = (parent.paragraph.items.firstIndex { $0.id == region.id } ?? 0) + 1
                return UIAccessibilityCustomAction(name: "Edit blank \(number)") { [weak self, weak view] _ in
                    guard let self, let view else { return false }
                    self.target = Target(id: region.id, occurrence: region.occurrence, letter: region.letter)
                    self.setFocus(region.id); self.render(view); view.becomeFirstResponder(); return true
                }
            }
            lastRender = parent.snapshot
            view.invalidateIntrinsicContentSize()
        }
        private func matchesTarget(_ region: Region) -> Bool { region.id == target?.id && region.occurrence == target?.occurrence && region.letter == target?.letter }
        private func setFocus(_ id: UUID?) { requestedFocus = id; parent.focused = id }
        func textViewDidBeginEditing(_ textView: UITextView) {
            if target == nil, let region = regions.first { target = Target(id: region.id, occurrence: region.occurrence, letter: region.letter) }
            setFocus(target?.id); render(textView)
        }
        func textViewDidEndEditing(_ textView: UITextView) { if !rendering { setFocus(nil) } }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !rendering, textView.isFirstResponder, !regions.isEmpty else { return }
            let location = textView.selectedRange.location
            let region = regions.first { NSLocationInRange(location, $0.range) } ?? regions.min { distance(location, $0.range) < distance(location, $1.range) }!
            let offset = max(0, min(region.range.length, location - region.range.location))
            let next = Target(id: region.id, occurrence: region.occurrence, letter: region.letter, offset: offset, length: min(textView.selectedRange.length, region.range.length - offset))
            let expected = region.placeholder ? region.range : NSRange(location: region.range.location + (region.letter == nil ? offset : 0), length: region.letter == nil ? next.length : 0)
            if target == next && parent.focused == region.id && textView.selectedRange == expected { return }
            target = next; setFocus(region.id); render(textView)
        }
        func textViewDidChange(_ textView: UITextView) { if !rendering { render(textView) } }
        private func distance(_ location: Int, _ range: NSRange) -> Int { location < range.location ? range.location - location : max(0, location - NSMaxRange(range)) }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard let region = regions.first(where: matchesTarget), let item = parent.paragraph.items.first(where: { $0.id == region.id }) else { return false }
            if text == "\n" { parent.advance(item); return false }
            if let letter = region.letter {
                var retry = parent.retries[item.id] ?? RetryLetters(answer: item.text)
                let next = text.isEmpty ? retry.backspace(at: letter) : retry.replace(at: letter, with: text)
                parent.retries[item.id] = retry
                target = Target(id: item.id, occurrence: region.occurrence, letter: next ?? letter)
            } else {
                let old = parent.inputs[item.id] ?? ""
                if region.placeholder { parent.inputs[item.id] = text; target?.offset = text.utf16.count }
                else {
                    guard range.location >= region.range.location, NSMaxRange(range) <= NSMaxRange(region.range) else { return false }
                    let local = NSRange(location: range.location - region.range.location, length: range.length)
                    guard let swiftRange = Range(local, in: old) else { return false }
                    parent.inputs[item.id] = old.replacingCharacters(in: swiftRange, with: text)
                    target?.offset = local.location + text.utf16.count; target?.length = 0
                }
            }
            render(textView); return false
        }
    }
}
