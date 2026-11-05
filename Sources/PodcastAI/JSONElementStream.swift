import Foundation
import PodcastCore

/// Emits only complete strings/objects from arrays in a streamed JSON object.
struct JSONElementStream {
    private var bytes = Data()
    private var offset = 0
    private var depth = 0
    private var quoted = false
    private var escaped = false
    private var stringStart = 0
    private var elementStart: Int?
    private var key = ""
    private var arrayKey: String?

    mutating func append(_ delta: String) throws -> [(key: String, data: Data)] {
        bytes.append(contentsOf: delta.utf8)
        guard bytes.count <= 10_000_000 else { throw ImportError.tooLarge }
        var elements: [(String, Data)] = []
        func element(endingAt end: Int) {
            if let start = elementStart, let arrayKey {
                elements.append((arrayKey, bytes.subdata(in: start..<end)))
                elementStart = nil
            }
        }
        while offset < bytes.count {
            let byte = bytes[offset]
            defer { offset += 1 }
            if quoted {
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 {
                    quoted = false
                    if depth == 1 { key = try JSONDecoder().decode(String.self, from: bytes.subdata(in: stringStart..<(offset + 1))) }
                    if depth == 2 { element(endingAt: offset + 1) }
                }
                continue
            }
            if depth == 2, arrayKey != nil, elementStart == nil, byte == 34 || byte == 123 { elementStart = offset }
            switch byte {
            case 34: quoted = true; stringStart = offset
            case 123: depth += 1
            case 91:
                if depth == 1 { arrayKey = key }
                depth += 1
            case 125:
                depth -= 1
                if depth == 2 { element(endingAt: offset + 1) }
            case 93:
                depth -= 1
                if depth == 1 { arrayKey = nil; elementStart = nil }
            default: break
            }
        }
        return elements
    }
}
