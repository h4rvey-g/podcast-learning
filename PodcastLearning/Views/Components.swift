import SwiftUI
import PodcastCore

// Semantic light/dark pairs sampled from the Figma document.
enum Palette {
    static let accent = Color("AccentColor")
    static let onAccent = Color("OnAccent")
    static let key = Color("KeySentence")
    static let list = Color("ListSource")
    static let ai = Color("AISource")
    static let manual = Color("ManualSource")
    static let background = Color(uiColor: .systemGroupedBackground)
    static let cell = Color(uiColor: .secondarySystemGroupedBackground)
    static func source(_ source: ItemSource) -> Color { source == .list ? list : source == .ai ? ai : manual }
}

struct PrimaryButton: View {
    let title: String
    var symbol: String? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack { if let symbol { Image(systemName: symbol) }; Text(title) }
                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15)
        }.buttonStyle(.plain).foregroundStyle(Palette.onAccent).background(Palette.accent, in: Capsule())
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
            if let value = transcript?.coverURL, let url = URL(string: value) {
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
    func card() -> some View { padding(16).frame(maxWidth: .infinity, alignment: .leading).background(Palette.cell, in: RoundedRectangle(cornerRadius: 22)) }
}

func timestamp(_ seconds: Double) -> String {
    let value = seconds.isFinite ? max(0, Int(seconds)) : 0
    return String(format: "%02d:%02d", value / 60, value % 60)
}
