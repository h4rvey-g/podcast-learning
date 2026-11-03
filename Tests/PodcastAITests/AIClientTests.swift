import Foundation
import Testing
import PodcastAI
import PodcastCore
import AISDKProviderUtils

private actor ProviderStub {
    private var requests: [URLRequest] = []
    let failure: Int?
    let parameter: String
    let finish: String
    init(failure: Int? = nil, parameter: String = "response_format", finish: String = "stop") {
        self.failure = failure; self.parameter = parameter; self.finish = finish
    }
    func fetch(_ request: URLRequest) throws -> FetchResponse {
        requests.append(request)
        let status = requests.count == 1 ? failure ?? 200 : 200
        let body: [String: Any]
        if status != 200 {
            body = ["error": ["message": "Rejected option", "type": "invalid_request_error", "param": parameter, "code": "invalid_parameter"]]
        } else if request.url?.path.hasSuffix("/responses") == true {
            body = ["id": "resp_test", "object": "response", "created_at": 1, "status": "completed", "model": "gpt-6.1-sol",
                    "output": [["id": "msg_test", "type": "message", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": "OK", "annotations": []]]]],
                    "usage": ["input_tokens": 1, "output_tokens": 1, "total_tokens": 2]]
        } else {
            body = ["id": "chat_test", "object": "chat.completion", "created": 1, "model": "gpt-6.1-sol",
                    "choices": [["index": 0, "message": ["role": "assistant", "content": "OK"], "finish_reason": finish]],
                    "usage": ["prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2]]
        }
        return FetchResponse(body: .data(try JSONSerialization.data(withJSONObject: body)),
                             urlResponse: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
    func snapshot() -> [URLRequest] { requests }
}

@Test func thinkingAndSchemaReachChatAndResponsesRequests() async throws {
    for api in AIProviderAPI.allCases {
        let stub = ProviderStub()
        let client = try AIClient(baseURL: "https://provider.example/v1", model: "gpt-6.1-sol", key: "test-key", api: api,
                                  thinking: .medium, fetch: { try await stub.fetch($0) })
        #expect(try await client.completion(system: "Reply OK", input: "Test", json: true) == "OK")
        let request = try #require(await stub.snapshot().first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["store"] as? Bool == false)
        if api == .chat {
            #expect(request.url?.path == "/v1/chat/completions")
            #expect(body["reasoning_effort"] as? String == "medium")
            #expect((body["response_format"] as? [String: Any])?["type"] as? String == "json_schema")
        } else {
            #expect(request.url?.path == "/v1/responses")
            #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "medium")
            let text = body["text"] as? [String: Any]
            #expect((text?["format"] as? [String: Any])?["type"] as? String == "json_schema")
        }
    }
}

@Test func defaultThinkingIsOmittedAndNoneIsExplicit() async throws {
    for thinking in [ThinkingLevel.providerDefault, .none] {
        let stub = ProviderStub()
        let client = try AIClient(baseURL: "https://provider.example/v1", model: "gpt-5.1", key: "test-key", thinking: thinking,
                                  fetch: { try await stub.fetch($0) })
        _ = try await client.completion(system: "Reply OK", input: "Test")
        let request = try #require(await stub.snapshot().first)
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["reasoning_effort"] as? String == (thinking == .none ? "none" : nil))
    }
}

@Test func schemaFallbackOnlyRetriesFormatRejections() async throws {
    for (status, parameter, count) in [(400, "response_format", 2), (422, "text.format", 2), (401, "response_format", 1), (400, "reasoning_effort", 1), (429, "", 1)] {
        let stub = ProviderStub(failure: status, parameter: parameter)
        let client = try AIClient(baseURL: "https://provider.example/v1", model: "gpt-6.1-sol", key: "test-key", fetch: { try await stub.fetch($0) })
        if count == 2 {
            _ = try await client.completion(system: "Return JSON", input: "Test", json: true)
            let requests = await stub.snapshot()
            let body = try #require(JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: Any])
            #expect((body["response_format"] as? [String: Any])?["type"] as? String == "json_object")
        } else {
            await #expect(throws: ImportError.self) { try await client.completion(system: "Return JSON", input: "Test", json: true) }
        }
        #expect(await stub.snapshot().count == count)
    }
}

@Test func aiRejectsInvalidConfigurationAndTruncatedOutput() async throws {
    for url in ["http://provider.example/v1", "https://key@provider.example/v1", "https://provider.example/v1?key=secret"] {
        #expect(throws: ImportError.self) { try AIClient(baseURL: url, model: "test", key: "test-key") }
    }
    #expect(throws: ImportError.self) { try AIClient(baseURL: "https://provider.example/v1", model: "test", key: "") }
    let stub = ProviderStub(finish: "length")
    let client = try AIClient(baseURL: "https://provider.example/v1", model: "test", key: "test-key", fetch: { try await stub.fetch($0) })
    await #expect(throws: ImportError.self) { try await client.completion(system: "Reply OK", input: "Test") }
    let unsupported = ProviderStub()
    let limited = try AIClient(baseURL: "https://provider.example/v1", model: "gpt-6.1-sol", key: "test-key", thinking: .none, fetch: { try await unsupported.fetch($0) })
    await #expect(throws: (any Error).self) { try await limited.completion(system: "Reply OK", input: "Test") }
    #expect(await unsupported.snapshot().isEmpty)
}
