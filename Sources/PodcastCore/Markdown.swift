import Foundation

/// The small slice of markdown an LLM explanation actually uses, so it can be laid out as
/// SwiftUI views instead of showing literal `**` and `-` characters.
public enum MarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case bullet(String)
    case numbered(marker: String, text: String)
    case paragraph(String)
}

public enum Markdown {
    public static func blocks(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = [], paragraph: [String] = [], inFence = false
        func flush() {
            let joined = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { blocks.append(.paragraph(joined)) }
            paragraph.removeAll()
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { flush(); inFence.toggle(); continue }
            if inFence || line.isEmpty || isRule(line) || onlyMarkers(line) { flush(); continue }
            if let heading = heading(line) {
                flush(); blocks.append(.heading(level: heading.level, text: heading.text))
            } else if line.hasPrefix(">") {
                paragraph.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
            } else if let item = remainder(line, prefixes: ["- ", "* ", "• "]) {
                flush(); blocks.append(.bullet(item))
            } else if let item = numbered(line) {
                flush(); blocks.append(.numbered(marker: item.marker, text: item.text))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") else { return nil }
        let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"\s*#+$"#, with: "", options: .regularExpression)
        return text.isEmpty ? nil : (hashes, text)
    }

    private static func remainder(_ line: String, prefixes: [String]) -> String? {
        guard let prefix = prefixes.first(where: { line.hasPrefix($0) }) else { return nil }
        let text = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func numbered(_ line: String) -> (marker: String, text: String)? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 2 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let separator = rest.first, separator == "." || separator == ")" else { return nil }
        let text = rest.dropFirst().trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (digits + ".", text)
    }

    private static func onlyMarkers(_ line: String) -> Bool { line.allSatisfy { "#-*•>".contains($0) } }

    private static func isRule(_ line: String) -> Bool {
        guard let first = line.first, "-*_".contains(first), line.count >= 3 else { return false }
        return line.allSatisfy { $0 == first || $0 == " " }
    }
}
