import SwiftUI
import PodcastCore
import NaturalLanguage

// Semantic light/dark pairs sampled from the Figma document.
enum Palette {
    static let onAccent = Color("OnAccent")
    static let key = Color("KeySentence")
    static let list = Color("ListSource")
    static let ai = Color("AISource")
    static let manual = Color("ManualSource")
    static let background = Color(uiColor: .systemGroupedBackground)
    static let cell = Color(uiColor: .secondarySystemGroupedBackground)
    static func source(_ source: ItemSource) -> Color { source == .list ? list : source == .ai ? ai : manual }
}

struct ImportProgressView: View {
    let transcript: Transcript
    @Environment(AppStore.self) private var store
    @Environment(\.accentTheme) private var theme
    var body: some View {
        if let progress = store.importProgress(transcript) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text(progress.title).frame(maxWidth: .infinity, alignment: .leading)
                }.font(.footnote).foregroundStyle(.secondary)
                ProgressView(value: progress.fraction).tint(theme.color)
                    .accessibilityLabel("Import steps")
                    .accessibilityValue("\(progress.completed) of \(progress.steps.count) complete")
                DisclosureGroup("\(progress.completed) of \(progress.steps.count) steps complete") {
                    ForEach(progress.steps) { step in
                        HStack(spacing: 8) {
                            if step.state == .running { ProgressView().controlSize(.mini) }
                            else { Image(systemName: step.state == .done ? "checkmark.circle.fill" : step.state == .failed ? "exclamationmark.circle" : "circle") }
                            Text(step.title)
                            Spacer(minLength: 0)
                            if let fraction = step.fraction, step.state == .running {
                                Text(fraction, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                            }
                        }.accessibilityElement(children: .combine)
                            .accessibilityValue(step.state == .done ? "Complete" : step.state == .failed ? "Failed" : step.state == .running ? "In progress" : "Waiting")
                    }
                }.font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct PrimaryButton: View {
    @Environment(\.accentTheme) private var theme
    let title: String
    var symbol: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack { if let symbol { Image(systemName: symbol) }; Text(title) }
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15)
                .contentShape(Capsule())
        }.buttonStyle(.plain).foregroundStyle(Palette.onAccent).background(theme.color, in: Capsule())
    }
}

struct RoundButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        Button(action: action) { Image(systemName: symbol).font(.body.weight(.medium)).frame(width: 44, height: 44).contentShape(Circle()) }
            .buttonStyle(.plain)
            .background { if reduceTransparency { Circle().fill(Palette.cell) } else { Circle().fill(.regularMaterial) } }
            .accessibilityLabel(title)
    }
}

struct CoverArt: View {
    let transcript: Transcript?
    var size: CGFloat = 56
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 1, green: 0.48, blue: 0.35), Color(red: 0.43, green: 0.29, blue: 1)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: transcript?.episodeID == nil ? "doc.text" : "headphones").font(.system(size: size * 0.42)).foregroundStyle(.white)
            if let value = transcript?.coverURL,
               let url = transcript?.episodeID?.hasPrefix("bilibili:") == true ? BilibiliClient.coverURL(value) : URL(string: value) {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
            }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.2)).accessibilityHidden(true)
    }
}

struct LevelBadge: View {
    let level: String
    var body: some View { Text(level).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 3).background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 5)) }
}

struct SourceLabel: View {
    let source: ItemSource
    var body: some View {
        Label(source.label + (source == .ai ? "*" : source == .manual ? "+" : ""), systemImage: source.symbol)
            .foregroundStyle(Palette.source(source)).font(.footnote)
    }
}

extension View {
    func downloadCard() -> some View {
        padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.cell, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color(uiColor: .separator), lineWidth: 0.5))
    }
    func card(fill: Color = Palette.cell) -> some View { padding(16).frame(maxWidth: .infinity, alignment: .leading).background(fill, in: RoundedRectangle(cornerRadius: 22)) }
}

func timestamp(_ seconds: Double) -> String {
    let value = seconds.isFinite && seconds >= 0 && seconds < Double(Int.max) ? Int(seconds) : 0
    return String(format: "%02d:%02d", value / 60, value % 60)
}

struct Waveform: View {
    @Environment(\.accentTheme) private var theme
    var progress: Double
    var seek: ((Double) -> Void)? = nil
    @GestureState private var scrubbing: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var displayed: Double { max(0, min(1, scrubbing ?? progress)) }
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                bars(width: geometry.size.width, color: Color.secondary.opacity(0.35))
                bars(width: geometry.size.width, color: theme.color)
                    .mask(alignment: .leading) { Rectangle().frame(width: geometry.size.width * displayed) }
                if seek != nil {
                    Capsule().fill(theme.color).frame(width: 2, height: 32)
                        .offset(x: max(0, min(geometry.size.width - 2, geometry.size.width * displayed)))
                }
            }.frame(height: 44).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .updating($scrubbing) { value, state, _ in state = fraction(value.location.x, width: geometry.size.width) }
                    .onEnded { value in seek?(fraction(value.location.x, width: geometry.size.width)) })
                .allowsHitTesting(seek != nil)
                .animation(reduceMotion || scrubbing != nil ? nil : .linear(duration: 0.1), value: progress)
        }.frame(height: 44)
            .accessibilityRepresentation {
                if let seek {
                    Slider(value: Binding(get: { displayed }, set: { seek($0) }), in: 0...1) { Text("Paragraph Playback Position") }
                        .accessibilityValue(Text(displayed, format: .percent.precision(.fractionLength(0))))
                } else { Text("Paragraph playback progress: \(Int(displayed * 100)) percent") }
            }
    }
    private func fraction(_ x: CGFloat, width: CGFloat) -> Double { max(0, min(1, x / max(1, width))) }
    private func bars(width: CGFloat, color: Color) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<28) { index in
                Capsule().fill(color).frame(width: max(1, (width - 81) / 28), height: CGFloat([10, 18, 13, 24, 17, 28, 20, 12, 25][index % 9]))
            }
        }.frame(height: 28)
    }
}

struct ItemSummaryRow: View {
    let item: DictationItem
    let memory: WordMemory?
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.itemSource.symbol).foregroundStyle(Palette.source(item.itemSource)).frame(width: 20)
            VStack(alignment: .leading, spacing: 5) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 5) { heading; gloss }
                    VStack(alignment: .leading, spacing: 4) { heading; gloss }
                }
                if let sentence = item.sentence {
                    Text(sentence.text).font(.system(.footnote, design: .serif)).foregroundStyle(.secondary).lineLimit(1)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(memory.map { "Box \($0.box)" } ?? "New").font(.footnote).foregroundStyle(.secondary)
        }.padding(.vertical, 6)
    }
    private var heading: some View {
        HStack(spacing: 5) { Text(item.text).font(.headline); if let level = item.level { LevelBadge(level: level) } }
    }
    @ViewBuilder private var gloss: some View {
        if let gloss = item.glossZh { Text(gloss).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
    }
}

struct WavyUnderline: TextAttribute {}
struct SourceUnderlineRenderer: TextRenderer {
    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                context.draw(run)
                if run[WavyUnderline.self] != nil {
                    let rect = run.typographicBounds.rect
                    var path = Path()
                    let y = rect.maxY + 1
                    path.move(to: CGPoint(x: rect.minX, y: y))
                    for x in stride(from: rect.minX, through: rect.maxX, by: 1) {
                        path.addLine(to: CGPoint(x: x, y: y + sin((x - rect.minX) * .pi / 4)))
                    }
                    context.stroke(path, with: .color(Palette.ai), lineWidth: 1)
                }
            }
        }
    }
}

struct HighlightedText: View {
    let sentence: Sentence
    let items: [DictationItem]
    var selectWord: ((String) -> Void)? = nil
    var body: some View {
        content.font(.system(.title3, design: .serif)).lineSpacing(7).textRenderer(SourceUnderlineRenderer())
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "learn-word", let selectWord,
                      let word = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value else { return .discarded }
                selectWord(word); return .handled
            })
    }
    private var content: Text {
        let text = sentence.text
        var result = Text("")
        var cursor = text.startIndex
        for match in TextMatch.highlights(in: text, items: items) {
            result = result + linkedText(String(text[cursor..<match.range.lowerBound]))
            let source = match.item.itemSource
            let marker = source == .ai ? "*" : source == .manual ? "+" : ""
            var highlighted = Text(linked(String(text[match.range]) + marker, word: String(text[match.range])))
                .foregroundColor(Palette.source(source)).font(.system(.title3, design: .serif).weight(.semibold))
            if source == .ai { highlighted = highlighted.customAttribute(WavyUnderline()) }
            else { highlighted = highlighted.underline(true, pattern: source == .manual ? .dot : .solid) }
            result = result + highlighted
            cursor = match.range.upperBound
        }
        return result + linkedText(String(text[cursor...]))
    }
    private func linkedText(_ text: String) -> Text {
        var attributed = AttributedString(text)
        if selectWord != nil {
            let tokenizer = NLTokenizer(unit: .word); tokenizer.string = text; tokenizer.setLanguage(.english)
            for range in tokenizer.tokens(for: text.startIndex..<text.endIndex) {
                if let r = Range(range, in: attributed) { attributed[r].link = wordURL(String(text[range])); attributed[r].foregroundColor = .primary }
            }
        }
        return Text(attributed)
    }
    private func linked(_ text: String, word: String) -> AttributedString {
        var attributed = AttributedString(text)
        if selectWord != nil { attributed.link = wordURL(word) }
        return attributed
    }
    private func wordURL(_ word: String) -> URL? {
        var components = URLComponents(); components.scheme = "learn-word"; components.host = "pick"
        components.queryItems = [URLQueryItem(name: "word", value: word)]
        return components.url
    }
}

struct SettingsIcon: View {
    let symbol: String
    var color: Color = .blue
    var body: some View {
        Image(systemName: symbol).font(.body).foregroundStyle(.white).frame(width: 30, height: 30)
            .background(color, in: RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
    }
}

/// Renders an AI answer's markdown (headings, bullets, numbered steps, inline bold/code) as SwiftUI text.
struct MarkdownText: View {
    @Environment(\.accentTheme) private var theme
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Markdown.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(inline(text)).font(level <= 2 ? .headline : .subheadline.weight(.semibold)).padding(.top, 2)
                case .bullet(let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•").foregroundStyle(theme.color); Text(inline(text)) }
                case .numbered(let marker, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text(marker).foregroundStyle(theme.color).monospacedDigit(); Text(inline(text)) }
                case .paragraph(let text):
                    Text(inline(text))
                }
            }
        }.font(.callout).textSelection(.enabled)
    }
    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(text)
    }
}
