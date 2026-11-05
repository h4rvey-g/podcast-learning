import Foundation
import Testing
import PodcastCore
@testable import PodcastAI
import AISDKProviderUtils

private actor StreamObserver {
    var values: [String] = []
    var receivedBeforeEnd = false
    var ended = false
    func receive(_ value: String) { values.append(value); receivedBeforeEnd = receivedBeforeEnd || !ended }
    func finish() { ended = true }
    func waitForConsumer() async throws {
        for _ in 0..<400 {
            if !values.isEmpty { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw URLError(.timedOut)
    }
}

private func event(_ object: [String: Any]) throws -> Data {
    let json = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    return Data("data: \(json)\n\n".utf8)
}

private func streamingResponse(_ request: URLRequest, fragments: [String], observer: StreamObserver? = nil,
                               finish: String = "stop", fail: Bool = false, holdOpen: Bool = false) throws -> FetchResponse {
    let api: AIProviderAPI = request.url!.path.hasSuffix("/responses") ? .responses : request.url!.path.hasSuffix("/messages") ? .anthropic : request.url!.path.contains(":streamGenerateContent") ? .gemini : .chat
    var start: [Data] = [], deltas: [Data] = [], end: [Data] = []
    switch api {
    case .chat:
        deltas = try fragments.map { try event(["id": "test", "object": "chat.completion.chunk", "created": 1, "model": "test",
            "choices": [["index": 0, "delta": ["content": $0], "finish_reason": NSNull()]]]) }
        end = [try event(["id": "test", "object": "chat.completion.chunk", "created": 1, "model": "test",
            "choices": [["index": 0, "delta": [:], "finish_reason": finish]]]), Data("data: [DONE]\n\n".utf8)]
    case .responses:
        start = [try event(["type": "response.created", "response": ["id": "resp", "created_at": 1, "model": "test"]]),
                 try event(["type": "response.output_item.added", "output_index": 0, "item": ["id": "msg", "type": "message", "role": "assistant", "content": []]]),
                 try event(["type": "response.content_part.added", "item_id": "msg", "output_index": 0, "content_index": 0, "part": ["type": "output_text", "text": "", "annotations": []]])]
        deltas = try fragments.map { try event(["type": "response.output_text.delta", "item_id": "msg", "output_index": 0, "content_index": 0, "delta": $0]) }
        end = [try event(["type": "response.completed", "response": ["id": "resp", "created_at": 1, "model": "test", "status": "completed", "usage": ["input_tokens": 1, "output_tokens": 1]]])]
    case .anthropic:
        start = [try event(["type": "message_start", "message": ["id": "msg", "type": "message", "role": "assistant", "model": "test", "content": [], "usage": ["input_tokens": 1, "output_tokens": 0]]]),
                 try event(["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]])]
        deltas = try fragments.map { try event(["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": $0]]) }
        end = [try event(["type": "content_block_stop", "index": 0]),
               try event(["type": "message_delta", "delta": ["stop_reason": "end_turn", "stop_sequence": NSNull()], "usage": ["output_tokens": 1]]), try event(["type": "message_stop"])]
    case .gemini:
        deltas = try fragments.map { try event(["candidates": [["index": 0, "content": ["role": "model", "parts": [["text": $0]]]]]]) }
        end = [try event(["candidates": [["index": 0, "finishReason": "STOP"]], "usageMetadata": ["promptTokenCount": 1, "candidatesTokenCount": 1, "totalTokenCount": 2]])]
    }
    let initial = start, pieces = deltas, final = end
    let stream = AsyncThrowingStream<Data, Error> { continuation in
        let task = Task {
            do {
                for data in initial { continuation.yield(data) }
                for (index, data) in pieces.enumerated() {
                    // Exercise SSE framing split across network deliveries.
                    let split = data.count / 2
                    continuation.yield(data.prefix(split)); continuation.yield(data.suffix(data.count - split))
                    if index == 0, let observer { try await observer.waitForConsumer() }
                }
                if holdOpen { try await Task.sleep(for: .seconds(30)) }
                if fail { throw URLError(.networkConnectionLost) }
                await observer?.finish()
                for data in final { continuation.yield(data) }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
    return FetchResponse(body: .stream(stream), urlResponse: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
        headerFields: ["Content-Type": "text/event-stream"])!)
}

@Test func completeJSONElementsHandleEscapesUnicodeAndEveryFragmentBoundary() throws {
    let json = #"{"pieces":["中文 🎵 and \"quotes\"","line\nback\\slash"],"glosses":[{"itemId":"x","glossZh":"中","definitionEn":"value } ]","phonetic":""}]}"#
    for split in json.indices {
        var parser = JSONElementStream()
        let elements = try parser.append(String(json[..<split])) + parser.append(String(json[split...]))
        #expect(elements.map(\.key) == ["pieces", "pieces", "glosses"])
        #expect(try JSONDecoder().decode(String.self, from: elements[0].data) == "中文 🎵 and \"quotes\"")
    }
    var parser = JSONElementStream()
    #expect(try parser.append(#"{"pieces":["unfinished"#).isEmpty)
    #expect(try parser.append(#" text"]}"#).count == 1)
}

@Test func nativeProvidersStreamTextBeforeTheResponseEnds() async throws {
    for (api, model) in [(AIProviderAPI.chat, "gpt-4.1"), (.responses, "gpt-4.1"), (.anthropic, "claude-sonnet-4-6"), (.gemini, "gemini-2.5-flash")] {
        let observer = StreamObserver()
        let client = try AIClient(baseURL: "https://provider.example/v1", model: model, key: "test-key", api: api, fetch: {
            try streamingResponse($0, fragments: ["First ", "second"], observer: observer)
        })
        let result = try await client.completion(system: "Reply", input: "Test", onDelta: { await observer.receive($0) })
        #expect(result == "First second")
        #expect(await observer.values == ["First ", "second"])
        #expect(await observer.receivedBeforeEnd)
    }
}

@Test func cleanupEmitsCompletedParagraphBeforeTheRestOfTheJSON() async throws {
    let observer = StreamObserver()
    let client = try AIClient(baseURL: "https://provider.example/v1", model: "gpt-4.1", key: "test-key", fetch: {
        try streamingResponse($0, fragments: [#"{"pieces":["First clean paragraph.","#, #""Second clean paragraph."]}"#], observer: observer)
    })
    let pieces = try await client.cleanText("Raw text", onPiece: { await observer.receive($0) })
    #expect(pieces == ["First clean paragraph.", "Second clean paragraph."])
    #expect(await observer.values == pieces)
    #expect(await observer.receivedBeforeEnd)
}

@Test func failedAndTruncatedStreamsKeepCompletedFeedbackButNeverReturnSuccess() async throws {
    for (finish, fail) in [("length", false), ("stop", true)] {
        let observer = StreamObserver()
        let client = try AIClient(baseURL: "https://provider.example/v1", model: "gpt-4.1", key: "test-key", fetch: {
            try streamingResponse($0, fragments: [#"{"pieces":["A complete paragraph."]}"#], observer: observer, finish: finish, fail: fail)
        })
        await #expect(throws: (any Error).self) { try await client.cleanText("Raw", onPiece: { await observer.receive($0) }) }
        #expect(await observer.values == ["A complete paragraph."])
    }
}

@MainActor @Test func analysisEmitsUsableItemsBeforeItsBatchCompletes() async throws {
    let transcript = TextImporter.makeTranscript(title: "Live analysis", paragraphs: ["Music keeps time."])
    let observer = StreamObserver()
    let client = try AIClient(baseURL: "https://provider.example/v1", model: "gpt-4.1", key: "test-key", fetch: {
        try streamingResponse($0, fragments: [#"{"extraItems":[{"text":"keeps time","sentenceId":0,"kind":"phrase","glossZh":"打拍子","definitionEn":"follow rhythm","phonetic":""}],"#,
            #""keySentences":[],"glosses":[]}"#], observer: observer)
    })
    let apply: @MainActor @Sendable (AIAnalysis) -> Void = { $0.apply(to: transcript) }
    _ = try await client.analyze(TranscriptAnalysisInput(transcript: transcript, targetLevel: "B2"), onUpdate: { update in
        await observer.receive(update.extraItems.first?.text ?? "")
        await apply(update)
    })
    #expect(transcript.activeItems.map(\.text) == ["keeps time"])
    #expect(await observer.receivedBeforeEnd)
}

@Test func cancellationStopsAnOpenAIStreamWithoutReturningPartialSuccess() async throws {
    let observer = StreamObserver()
    let client = try AIClient(baseURL: "https://provider.example/v1", model: "gpt-4.1", key: "test-key", fetch: {
        try streamingResponse($0, fragments: ["Partial text"], observer: observer, holdOpen: true)
    })
    let task = Task { try await client.completion(system: "Reply", input: "Test", onDelta: { await observer.receive($0) }) }
    try await observer.waitForConsumer()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await observer.values == ["Partial text"])
}
