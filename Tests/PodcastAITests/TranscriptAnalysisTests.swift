import Foundation
import Testing
import PodcastCore
@testable import PodcastAI
import AISDKProviderUtils

private actor AnalysisProvider {
    var inputs: [[String: Any]] = []
    var active = 0
    var peak = 0
    var generatedGlosses = 0
    let fail: Bool
    let injectForeignIDs: Bool
    init(fail: Bool = false, injectForeignIDs: Bool = false) { self.fail = fail; self.injectForeignIDs = injectForeignIDs }

    func fetch(_ request: URLRequest) async throws -> FetchResponse {
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: Any]])
        let text = try #require(messages.last?["content"] as? String)
        let input = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let lines = try #require(input["sentences"] as? [[String: Any]])
        let items = try #require(input["items"] as? [[String: Any]])
        inputs.append(input); active += 1; peak = max(peak, active)
        defer { active -= 1 }
        if fail { throw URLError(.notConnectedToInternet) }
        let needed = items.filter { $0["needsGloss"] as? Bool != false }
        generatedGlosses += needed.count
        // Simulate generation time proportional to requested definitions, without a paid provider.
        try await Task.sleep(for: .milliseconds(needed.count * 3 + 10))
        var keys: [[String: Any]] = lines.map { ["sentenceId": $0["id"]!, "noteZh": "关键句"] }
        var glosses: [[String: Any]] = needed.map { ["itemId": $0["id"]!, "glossZh": "释义", "definitionEn": "Short definition", "phonetic": ""] }
        if injectForeignIDs {
            keys.append(["sentenceId": 999999, "noteZh": "Wrong ID"])
            glosses.append(["itemId": "unknown", "glossZh": "Wrong ID", "definitionEn": "Invalid", "phonetic": ""])
        }
        let output: [String: Any] = ["keySentences": keys, "extraItems": [], "glosses": glosses]
        let content = String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self)
        let response: [String: Any] = ["id": "test", "object": "chat.completion", "created": 1, "model": "test",
            "choices": [["index": 0, "message": ["role": "assistant", "content": content], "finish_reason": "stop"]]]
        return FetchResponse(body: .data(try JSONSerialization.data(withJSONObject: response)),
            urlResponse: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
    func metrics() -> (calls: Int, peak: Int, maxCharacters: Int, glosses: Int, sentenceIDs: [Int], itemIDs: [String]) {
        (inputs.count, peak, inputs.map { input in
            (input["sentences"] as? [[String: Any]] ?? []).reduce(0) { $0 + ($1["text"] as? String ?? "").count }
        }.max() ?? 0, generatedGlosses,
         inputs.flatMap { ($0["sentences"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? Int } },
         inputs.flatMap { ($0["items"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String } })
    }
}

@MainActor @Test func longAnalysisUsesBoundedParallelRequestsAndKeepsEveryID() async throws {
    let paragraphs = (0..<80).map { "Paragraph \($0). " + String(repeating: "Music keeps time and practice improves our abilities. ", count: 3) }
    let transcript = TextImporter.makeTranscript(title: "Long analysis", paragraphs: paragraphs)
    transcript.items = transcript.sentences.map { DictationItem(text: "Music", key: "music-\($0.index)", sentence: $0) }
    let input = TranscriptAnalysisInput(transcript: transcript, targetLevel: "B2")
    let provider = AnalysisProvider()
    let client = try AIClient(baseURL: "https://provider.example/v1", model: "test", key: "test-key", fetch: { try await provider.fetch($0) })
    let start = ContinuousClock.now
    let result = try await client.analyze(input)
    let metrics = await provider.metrics()
    print("Analysis fixture: \(metrics.calls) requests, peak \(metrics.peak), largest chunk \(metrics.maxCharacters) characters, \(metrics.glosses) definitions, elapsed \(start.duration(to: .now))")
    #expect(metrics.calls > 1)
    #expect(metrics.peak == 2)
    #expect(metrics.maxCharacters <= 6000)
    #expect(metrics.sentenceIDs.sorted() == transcript.sentences.map(\.index))
    #expect(Set(metrics.itemIDs) == Set(transcript.activeItems.map { $0.id.uuidString }))
    #expect(result.keySentences.map(\.sentenceId) == transcript.sentences.map(\.index))
    #expect(result.glosses.count == transcript.activeItems.count)
}

@MainActor @Test func repeatedAnalysisDoesNotRegenerateSavedDefinitions() async throws {
    let transcript = TextImporter.makeTranscript(title: "Saved definitions", paragraphs: ["Music keeps time."])
    let complete = DictationItem(text: "Music", key: "music", sentence: transcript.sentences[0])
    complete.glossZh = "音乐"; complete.definitionEn = "Sound"; complete.phonetic = ""
    let missing = DictationItem(text: "time", key: "time", sentence: transcript.sentences[0])
    transcript.items = [complete, missing]
    let provider = AnalysisProvider()
    let client = try AIClient(baseURL: "https://provider.example/v1", model: "test", key: "test-key", fetch: { try await provider.fetch($0) })
    let result = try await client.analyze(TranscriptAnalysisInput(transcript: transcript, targetLevel: "B2"))
    let metrics = await provider.metrics()
    #expect(metrics.calls == 1)
    #expect(metrics.glosses == 1)
    #expect(Set(metrics.itemIDs) == Set([complete.id.uuidString, missing.id.uuidString]))
    #expect(result.glosses.map(\.itemId) == [missing.id.uuidString])
}

@MainActor @Test func analysisHandlesEmptyInputOversizedSentencesAndUnlinkedWords() async throws {
    let empty = Transcript(title: "Empty")
    let provider = AnalysisProvider(injectForeignIDs: true)
    let client = try AIClient(baseURL: "https://provider.example/v1", model: "test", key: "test-key", fetch: { try await provider.fetch($0) })
    let noResult = try await client.analyze(TranscriptAnalysisInput(transcript: empty, targetLevel: "B2"))
    #expect(noResult.keySentences.isEmpty && noResult.glosses.isEmpty)
    #expect(await provider.metrics().calls == 0)
    let long = String(repeating: "word ", count: 2000)
    let transcript = TextImporter.makeTranscript(title: "Long sentence", paragraphs: [long])
    let orphan = DictationItem(text: "music", key: "music")
    transcript.items = [orphan]
    let result = try await client.analyze(TranscriptAnalysisInput(transcript: transcript, targetLevel: "B2"))
    let metrics = await provider.metrics()
    #expect(metrics.maxCharacters == transcript.sentences[0].text.count)
    #expect(metrics.calls == 2)
    #expect(result.keySentences.map(\.sentenceId) == transcript.sentences.map(\.index))
    #expect(result.glosses.map(\.itemId) == [orphan.id.uuidString])
}

@MainActor @Test func failedAnalysisStopsSchedulingRemainingBatches() async throws {
    let transcript = TextImporter.makeTranscript(title: "Failure", paragraphs: (0..<10).map { "Paragraph \($0) " + String(repeating: "word ", count: 1000) })
    let provider = AnalysisProvider(fail: true)
    let client = try AIClient(baseURL: "https://provider.example/v1", model: "test", key: "test-key", fetch: { try await provider.fetch($0) })
    await #expect(throws: (any Error).self) {
        try await client.analyze(TranscriptAnalysisInput(transcript: transcript, targetLevel: "B2"))
    }
    let metrics = await provider.metrics()
    #expect(metrics.calls <= 2)
    #expect(transcript.items == nil && transcript.sentences.allSatisfy { !$0.isKey })
}
