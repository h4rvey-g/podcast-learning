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
            if request.url?.path.hasSuffix("/messages") == true {
                body = ["type": "error", "error": ["type": "invalid_request_error", "message": "Rejected option \(parameter)"]]
            } else if request.url?.path.hasSuffix(":generateContent") == true {
                body = ["error": ["code": status, "message": "Rejected option \(parameter)", "status": "INVALID_ARGUMENT"]]
            } else {
                body = ["error": ["message": "Rejected option", "type": "invalid_request_error", "param": parameter, "code": "invalid_parameter"]]
            }
        } else if request.url?.path.hasSuffix("/responses") == true {
            body = ["id": "resp_test", "object": "response", "created_at": 1, "status": "completed", "model": "gpt-6.1-sol",
                    "output": [["id": "msg_test", "type": "message", "role": "assistant", "status": "completed", "content": [["type": "output_text", "text": "OK", "annotations": []]]]],
                    "usage": ["input_tokens": 1, "output_tokens": 1, "total_tokens": 2]]
        } else if request.url?.path.hasSuffix("/messages") == true {
            body = ["id": "msg_test", "type": "message", "role": "assistant", "model": "claude-sonnet-4-6",
                    "content": [["type": "text", "text": "OK"]], "stop_reason": finish == "length" ? "max_tokens" : "end_turn",
                    "stop_sequence": NSNull(), "usage": ["input_tokens": 1, "output_tokens": 1]]
        } else if request.url?.path.hasSuffix(":generateContent") == true {
            body = ["candidates": [["content": ["role": "model", "parts": [["text": "OK"]]],
                                    "finishReason": finish == "length" ? "MAX_TOKENS" : "STOP"]],
                    "usageMetadata": ["promptTokenCount": 1, "candidatesTokenCount": 1, "totalTokenCount": 2]]
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
    for api in [AIProviderAPI.chat, .responses] {
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

private let nativeProviders: [(AIProviderAPI, String)] = [(.anthropic, "claude-sonnet-4-6"), (.gemini, "gemini-3-flash-preview")]

@Test func nativeProvidersSendAuthenticationPromptsThinkingAndSchema() async throws {
    for (api, model) in nativeProviders {
        let stub = ProviderStub()
        let client = try AIClient(baseURL: "https://provider.example/custom/api/", model: model, key: "test-key", api: api,
                                  thinking: .medium, fetch: { try await stub.fetch($0) })
        #expect(try await client.completion(system: "System instructions", input: "Transcript input", json: true) == "OK")
        let request = try #require(await stub.snapshot().first)
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.url?.query == nil)
        #expect(body["store"] == nil)
        if api == .anthropic {
            #expect(request.url?.path == "/custom/api/messages")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "test-key")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            #expect(body["model"] as? String == model)
            #expect((body["system"] as? [[String: Any]])?.first?["text"] as? String == "System instructions")
            #expect((body["messages"] as? [[String: Any]])?.first?["role"] as? String == "user")
            let config = try #require(body["output_config"] as? [String: Any])
            #expect(config["effort"] as? String == "medium")
            let format = try #require(config["format"] as? [String: Any])
            #expect(format["type"] as? String == "json_schema")
            #expect((format["schema"] as? [String: Any])?["properties"] != nil)
        } else {
            #expect(request.url?.path == "/custom/api/models/\(model):generateContent")
            #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "test-key")
            let system = body["systemInstruction"] as? [String: Any]
            #expect((system?["parts"] as? [[String: Any]])?.first?["text"] as? String == "System instructions")
            #expect((body["contents"] as? [[String: Any]])?.first?["role"] as? String == "user")
            let config = try #require(body["generationConfig"] as? [String: Any])
            #expect((config["thinkingConfig"] as? [String: Any])?["thinkingLevel"] as? String == "medium")
            #expect(config["responseMimeType"] as? String == "application/json")
            #expect((config["responseJsonSchema"] as? [String: Any])?["properties"] != nil)
        }
        #expect(String(decoding: request.httpBody!, as: UTF8.self).contains("Transcript input"))
    }
}

@Test func nativeDefaultThinkingIsOmitted() async throws {
    for (api, model) in nativeProviders {
        let stub = ProviderStub()
        let client = try AIClient(baseURL: "https://provider.example/v1", model: model, key: "test-key", api: api,
                                  fetch: { try await stub.fetch($0) })
        _ = try await client.completion(system: "Reply OK", input: "Test")
        let request = try #require(await stub.snapshot().first)
        let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["thinking"] == nil)
        #expect((body["output_config"] as? [String: Any])?["effort"] == nil)
        #expect((body["generationConfig"] as? [String: Any])?["thinkingConfig"] == nil)
    }
}

@Test func nativeBudgetThinkingAndExplicitNoneReachRequests() async throws {
    for (api, model) in [(AIProviderAPI.anthropic, "claude-sonnet-4-5"), (.gemini, "gemini-2.5-flash")] {
        for thinking in [ThinkingLevel.medium, .none] {
            let stub = ProviderStub()
            let client = try AIClient(baseURL: "https://provider.example/v1", model: model, key: "test-key", api: api,
                                      thinking: thinking, fetch: { try await stub.fetch($0) })
            _ = try await client.completion(system: "Reply OK", input: "Test")
            let request = try #require(await stub.snapshot().first)
            let body = try #require(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            if api == .anthropic {
                let config = try #require(body["thinking"] as? [String: Any])
                #expect(config["type"] as? String == (thinking == .none ? "disabled" : "enabled"))
                #expect(config["budget_tokens"] as? Int == (thinking == .none ? nil : 19200))
            } else {
                let generation = body["generationConfig"] as? [String: Any]
                let config = try #require(generation?["thinkingConfig"] as? [String: Any])
                #expect(config["thinkingBudget"] as? Int == (thinking == .none ? 0 : 19661))
            }
        }
    }
}

@Test func nativeUnsupportedThinkingFailsBeforeSending() async throws {
    for (api, model, thinking) in [(AIProviderAPI.anthropic, "claude-sonnet-4-6", ThinkingLevel.minimal),
                                   (.gemini, "gemini-3-flash-preview", .max), (.gemini, "gemini-3-pro-preview", .none)] {
        let stub = ProviderStub()
        let client = try AIClient(baseURL: "https://provider.example/v1", model: model, key: "test-key", api: api,
                                  thinking: thinking, fetch: { try await stub.fetch($0) })
        await #expect(throws: (any Error).self) { try await client.completion(system: "Reply OK", input: "Test") }
        #expect(await stub.snapshot().isEmpty)
    }
}

@Test func nativeSchemaFallbackAndErrors() async throws {
    for (api, model) in nativeProviders {
        let parameter = api == .anthropic ? "output_config.format" : "generationConfig.responseJsonSchema"
        for (status, rejected, count) in [(400, parameter, 2), (422, parameter, 2), (400, "thinking", 1), (401, parameter, 1), (429, parameter, 1)] {
            let stub = ProviderStub(failure: status, parameter: rejected)
            let client = try AIClient(baseURL: "https://provider.example/v1", model: model, key: "test-key", api: api,
                                      fetch: { try await stub.fetch($0) })
            if count == 2 {
                #expect(try await client.completion(system: "Return JSON", input: "Test", json: true) == "OK")
                let requests = await stub.snapshot()
                let body = try #require(JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: Any])
                #expect((body["output_config"] as? [String: Any])?["format"] == nil)
                #expect((body["generationConfig"] as? [String: Any])?["responseJsonSchema"] == nil)
            } else {
                await #expect(throws: ImportError.self) { try await client.completion(system: "Return JSON", input: "Test", json: true) }
            }
            #expect(await stub.snapshot().count == count)
        }
        let stub = ProviderStub(finish: "length")
        let client = try AIClient(baseURL: "https://provider.example/v1", model: model, key: "test-key", api: api,
                                  fetch: { try await stub.fetch($0) })
        await #expect(throws: ImportError.self) { try await client.completion(system: "Reply OK", input: "Test") }
    }
}
