import Foundation

public struct AIAnalysis: Codable, Sendable {
    public var keySentences: [KeySentence]
    public var extraItems: [ExtraItem]
    public var glosses: [Gloss]
    public struct KeySentence: Codable, Sendable { public let sentenceId: Int; public let noteZh: String }
    public struct ExtraItem: Codable, Sendable {
        public let text: String
        public let sentenceId: Int
        public let kind: String?
        public let glossZh: String
        public let definitionEn: String
        public let phonetic: String?
    }
    public struct Gloss: Codable, Sendable { public let itemId: String; public let glossZh: String; public let definitionEn: String; public let phonetic: String? }

    @MainActor public func apply(to transcript: Transcript) {
        let sentences = Dictionary(transcript.sentences.map { ($0.index, $0) }, uniquingKeysWith: { first, _ in first })
        let items = Dictionary((transcript.items ?? []).map { ($0.id.uuidString.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for key in keySentences {
            sentences[key.sentenceId]?.isKey = true
            sentences[key.sentenceId]?.keyNoteZh = key.noteZh
        }
        for gloss in glosses {
            items[gloss.itemId.lowercased()]?.glossZh = gloss.glossZh
            items[gloss.itemId.lowercased()]?.definitionEn = gloss.definitionEn
            items[gloss.itemId.lowercased()]?.phonetic = gloss.phonetic
        }
        var keys = Set((transcript.items ?? []).flatMap { [$0.key, $0.text.lowercased()] })
        var added: [DictationItem] = []
        for extra in extraItems {
            let text = extra.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let sentence = sentences[extra.sentenceId], TextMatch.range(of: text, in: sentence.text) != nil else { continue }
            let key = text.contains(" ") ? text.lowercased() : (Lemmatizer.tokens(text).first?.lemma ?? text.lowercased())
            guard !keys.contains(key), !keys.contains(text.lowercased()) else { continue }
            keys.insert(key); keys.insert(text.lowercased())
            let item = DictationItem(text: text, key: key, source: .ai, sentence: sentence)
            item.glossZh = extra.glossZh; item.definitionEn = extra.definitionEn; item.phonetic = extra.phonetic; added.append(item)
        }
        transcript.items = (transcript.items ?? []) + added
    }
}

extension AIAnalysis {
    public static func schemaData() throws -> Data {
        func object(_ properties: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
        }
        func array(_ fields: [String: Any]) -> [String: Any] { ["type": "array", "items": object(fields)] }
        let string = ["type": "string"], integer = ["type": "integer"]
        let schema = object([
            "keySentences": array(["sentenceId": integer, "noteZh": string]),
            "extraItems": array(["text": string, "sentenceId": integer, "kind": string, "glossZh": string, "definitionEn": string, "phonetic": string]),
            "glosses": array(["itemId": string, "glossZh": string, "definitionEn": string, "phonetic": string])
        ])
        return try JSONSerialization.data(withJSONObject: schema, options: .sortedKeys)
    }
}
