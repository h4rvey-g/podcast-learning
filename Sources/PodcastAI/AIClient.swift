import Foundation
import PodcastCore
import SwiftAISDK
import OpenAIProvider
import AnthropicProvider
import GoogleProvider
import AISDKProvider
import AISDKProviderUtils

public enum ThinkingLevel: String, CaseIterable, Sendable {
    case providerDefault = "provider-default", none, minimal, low, medium, high, xhigh, max
    public var label: String {
        switch self {
        case .providerDefault: "Provider Default"
        case .xhigh: "Extra High"
        default: rawValue.capitalized
        }
    }
}

public enum AIProviderAPI: String, CaseIterable, Sendable {
    case chat, responses, anthropic, gemini
    public var label: String {
        switch self {
        case .chat: "OpenAI-Compatible Chat"
        case .responses: "OpenAI Responses"
        case .anthropic: "Anthropic Messages"
        case .gemini: "Google Gemini"
        }
    }
}

public struct AIClient: Sendable {
    private let baseURL: String
    private let model: String
    private let key: String
    private let api: AIProviderAPI
    private let thinking: ThinkingLevel
    private let fetch: FetchFunction?
    public init(baseURL: String, model: String, key: String, api: AIProviderAPI = .chat,
                thinking: ThinkingLevel = .providerDefault, fetch: FetchFunction? = nil) throws {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              url.port == nil, url.query == nil, url.fragment == nil,
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ImportError.service("Use an HTTPS provider base URL, such as https://api.openai.com/v1, and a model name.")
        }
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.service("Add your API key in Settings to use AI analysis.") }
        self.baseURL = url.absoluteString; self.model = model; self.key = key
        self.api = api; self.thinking = thinking; self.fetch = fetch
    }
    public func completion(system: String, input: String, json: Bool = false, maxTokens: Int? = nil) async throws -> String {
        let send = fetch ?? defaultFetchFunction()
        let thinking = thinking, api = api
        let checkedFetch: FetchFunction = { request in
            if thinking != .providerDefault {
                let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let applied: Bool
                switch api {
                case .chat:
                    applied = body?["reasoning_effort"] as? String == thinking.rawValue
                case .responses:
                    applied = (body?["reasoning"] as? [String: Any])?["effort"] as? String == thinking.rawValue
                case .anthropic:
                    let config = body?["output_config"] as? [String: Any]
                    let nativeThinking = body?["thinking"] as? [String: Any]
                    applied = thinking == .none ? nativeThinking?["type"] as? String == "disabled"
                        : config?["effort"] as? String == thinking.rawValue
                            || (nativeThinking?["type"] as? String == "enabled" && (nativeThinking?["budget_tokens"] as? Int ?? 0) > 0)
                case .gemini:
                    let generation = body?["generationConfig"] as? [String: Any]
                    let config = generation?["thinkingConfig"] as? [String: Any]
                    let budget = config?["thinkingBudget"] as? Int
                    applied = thinking == .none ? budget == 0
                        : config?["thinkingLevel"] as? String == thinking.rawValue || (budget ?? 0) > 0
                }
                guard applied else { throw ImportError.service("This model does not support the selected thinking level. Choose Provider Default or a supported level.") }
            }
            return try await send(request)
        }
        let languageModel: any LanguageModelV4
        switch api {
        case .chat, .responses:
            let provider = try createOpenAIProvider(settings: .init(baseURL: baseURL, apiKey: key, fetch: checkedFetch))
            languageModel = api == .chat ? provider.chat(model) : provider.responses(model)
        case .anthropic:
            languageModel = createAnthropic(settings: .init(baseURL: baseURL, apiKey: key, fetch: checkedFetch)).messages(model)
        case .gemini:
            languageModel = try createGoogle(settings: .init(baseURL: baseURL, apiKey: key, fetch: checkedFetch)).languageModel(modelId: model)
        }
        let schema = json ? try JSONDecoder().decode(JSONValue.self, from: AIAnalysis.schemaData()) : nil
        func request(_ schema: JSONValue?) async throws -> String {
            let output = Output.Specification<String, String>(name: "transcript",
                responseFormat: { json ? .json(schema: schema, name: "transcript_analysis", description: nil) : .text },
                parsePartial: { $0 }, parseOutput: { text, _ in text })
            let result = try await generateText(model: languageModel, instructions: .text(system), prompt: input,
                output: output, providerOptions: api == .chat || api == .responses ? ["openai": ["store": .bool(false)]] : nil,
                settings: CallSettings(maxOutputTokens: maxTokens ?? (json ? 12000 : 2000),
                    reasoning: thinking == .providerDefault ? nil : LanguageModelV4ReasoningEffort(rawValue: thinking.rawValue),
                    maxRetries: 0, abortSignal: { Task.isCancelled }, timeout: .milliseconds(180_000)))
            guard result.finishReason != .length, !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.invalidResponse }
            return result.text
        }
        do {
            do { return try await request(schema) }
            catch let failure as APICallError where json && Self.rejectedFormat(failure) { return try await request(nil) }
        } catch let failure as APICallError {
            // Provider bodies may echo input or credentials; keep them out of UI and test diagnostics.
            throw ImportError.service("The AI provider could not complete the request (HTTP \(failure.statusCode ?? 0)). Check the model, thinking level, key, and provider settings.")
        }
    }
    private static func rejectedFormat(_ failure: APICallError) -> Bool {
        guard [400, 422].contains(failure.statusCode ?? 0) else { return false }
        let data = failure.responseBody.flatMap { $0.data(using: .utf8) }
        let body = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let error = body?["error"] as? [String: Any]
        let parameter = error?["param"] as? String ?? ""
        return parameter.hasPrefix("response_format") || parameter.hasPrefix("text.format") || parameter.hasPrefix("output_config.format")
            || ["json_schema", "output_config.format", "responsejsonschema", "responseschema", "response_json_schema"].contains { failure.message.lowercased().contains($0) }
    }
}
