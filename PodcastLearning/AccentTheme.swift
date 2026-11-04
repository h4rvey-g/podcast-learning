import SwiftUI

enum AccentTheme: String, CaseIterable {
    case purple, blue, teal, rose, amber

    var label: String { rawValue.capitalized }
    var assetName: String { self == .purple ? "AccentColor" : "Accent\(label)" }
    var color: Color { Color(assetName) }
}

extension EnvironmentValues {
    @Entry var accentTheme: AccentTheme = .purple
}
