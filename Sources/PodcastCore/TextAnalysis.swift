import Foundation
import NaturalLanguage

public enum ImportError: LocalizedError {
    case invalidURL, emptyText, invalidResponse, service(String), tooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter an Apple Podcasts episode link, including its episode ID."
        case .emptyText: return "No transcript text was found. Paste some text or choose a PDF, DOC, DOCX, TXT, SRT, or VTT file."
        case .invalidResponse: return "The service returned an unreadable response. Try again or import text instead."
        case .service(let message): return message
        case .tooLarge: return "This transcript is too large. Import a file smaller than 5 MB."
        }
    }
}

public enum TextImporter {
    public static func paragraphs(_ input: String, fileExtension: String = "txt") throws -> [String] {
        guard input.utf8.count <= 5_000_000 else { throw ImportError.tooLarge }
        var text = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        text = text.replacingOccurrences(of: "\n[\\t ]*\n", with: "\n\n", options: .regularExpression)
        if ["srt", "vtt"].contains(fileExtension.lowercased()) {
            text = text.components(separatedBy: "\n\n").compactMap { block -> String? in
                let lines = block.components(separatedBy: "\n")
                guard block.range(of: "^(NOTE|STYLE|REGION)(\\s|$)", options: .regularExpression) == nil else { return nil }
                guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
                return lines.dropFirst(timing + 1).joined(separator: " ")
            }.joined(separator: "\n\n")
            text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        let paragraphs = text.components(separatedBy: "\n\n").map {
            $0.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !paragraphs.isEmpty else { throw ImportError.emptyText }
        return paragraphs
    }
    public static func sentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text; tokenizer.setLanguage(.english)
        return tokenizer.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    @MainActor public static func makeTranscript(title: String, paragraphs: [String], author: String = "Pasted text") -> Transcript {
        let transcript = Transcript(title: title, author: author)
        transcript.segments = makeSegments(paragraphs)
        return transcript
    }
    @MainActor public static func makeSegments(_ paragraphs: [String]) -> [Segment] {
        var index = 0
        return paragraphs.enumerated().map { offset, text in
            let segment = Segment(index: offset, text: text)
            segment.sentences = sentences(text).map { text in
                defer { index += 1 }
                return Sentence(index: index, text: text)
            }
            return segment
        }
    }
}

public struct WordToken: Sendable {
    public let text: String
    public let lemma: String
    public let pos: String
}

public enum Lemmatizer {
    public static func tokens(_ text: String) -> [WordToken] {
        let tagger = NLTagger(tagSchemes: [.lemma, .lexicalClass, .nameType])
        tagger.string = text; tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
        var result: [WordToken] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            let name = tagger.tag(at: range.lowerBound, unit: .word, scheme: .nameType).0
            guard ![NLTag.personalName, .placeName, .organizationName].contains(name), tag != .number else { return true }
            let surface = String(text[range])
            guard surface.contains(where: \.isLetter) else { return true }
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue ?? surface
            let pos: String
            switch tag { case .noun: pos = "noun"; case .verb: pos = "verb"; case .adjective: pos = "adjective"; case .adverb: pos = "adverb"; default: pos = "other" }
            result.append(WordToken(text: surface, lemma: lemma.lowercased(), pos: pos)); return true
        }
        return result
    }
}

public struct LevelMarker: Sendable {
    public let words: [String: [String: CEFR]]
    public init(words: [String: [String: CEFR]]) { self.words = words }
    public static func bundled() throws -> Self {
        guard let url = Bundle.module.url(forResource: "wordlist", withExtension: "json") else { throw ImportError.invalidResponse }
        return try Self(words: JSONDecoder().decode([String: [String: CEFR]].self, from: Data(contentsOf: url)))
    }
    public func level(lemma: String, pos: String, surface: String) -> CEFR? {
        words[lemma]?[pos] ?? words[lemma]?.values.min() ?? words[surface.lowercased()]?.values.min()
    }
    @MainActor public func mark(_ transcript: Transcript, target: CEFR) {
        var seen = Set((transcript.items ?? []).map(\.key))
        var added: [DictationItem] = []
        for sentence in transcript.sentences {
            for token in Lemmatizer.tokens(sentence.text) {
                guard let level = level(lemma: token.lemma, pos: token.pos, surface: token.text), level >= target,
                      seen.insert(token.lemma).inserted else { continue }
                added.append(DictationItem(text: token.text, key: token.lemma, level: level.rawValue, sentence: sentence))
            }
        }
        transcript.items = (transcript.items ?? []) + added
    }
}
