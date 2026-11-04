import Foundation
import AVFoundation
import Testing
import Alamofire
import PodcastAI
import PodcastCore

private struct LiveCredentials: Decodable {
    let azureSpeechEndpoint: String
    let azureSpeechKey: String
    let aiBaseURL: String
    let aiAPI: AIProviderAPI
    let thinking: ThinkingLevel
    let speechModel: String
    let aiModel: String
    let aiKey: String

    private enum CodingKeys: String, CodingKey {
        case azureSpeechEndpoint, azureSpeechKey, azureSpeechModel, aiBaseUrl, aiHost, aiBasePath, aiProvider, thinking, aiModel, aiKey
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        azureSpeechEndpoint = try c.decode(String.self, forKey: .azureSpeechEndpoint)
        azureSpeechKey = try c.decode(String.self, forKey: .azureSpeechKey)
        speechModel = try c.decodeIfPresent(String.self, forKey: .azureSpeechModel) ?? "MAI-Transcribe-2"
        aiModel = try c.decode(String.self, forKey: .aiModel); aiKey = try c.decode(String.self, forKey: .aiKey)
        if let url = try c.decodeIfPresent(String.self, forKey: .aiBaseUrl) { aiBaseURL = url }
        else { aiBaseURL = "https://" + (try c.decode(String.self, forKey: .aiHost)) + (try c.decode(String.self, forKey: .aiBasePath)) }
        let provider = try c.decodeIfPresent(String.self, forKey: .aiProvider) ?? "chat"
        switch provider {
        case "OpenAIProvider", "responses": aiAPI = .responses
        case "OpenAICompatibleProvider", "chat": aiAPI = .chat
        case "AnthropicProvider", "anthropic": aiAPI = .anthropic
        case "GoogleProvider", "gemini": aiAPI = .gemini
        default: throw LiveCheckError("Use responses, chat, anthropic, or gemini for aiProvider.")
        }
        let effort = try c.decodeIfPresent(String.self, forKey: .thinking) ?? "provider-default"
        guard let level = ThinkingLevel(rawValue: effort) else { throw LiveCheckError("Set thinking to provider-default, none, minimal, low, medium, high, xhigh, or max.") }
        thinking = level
    }
    static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(".env.live.json")
    static func load() throws -> Self {
        guard let data = try? Data(contentsOf: file), let credentials = try? JSONDecoder().decode(Self.self, from: data) else {
            throw LiveCheckError("Fill in the gitignored .env.live.json in the project root using .env.live.json.example. Check the JSON syntax.")
        }
        return credentials
    }
    func validateAzure() throws {
        guard !azureSpeechKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LiveCheckError("Set azureSpeechKey in .env.live.json.") }
        do { _ = try MAITranscriber(endpoint: azureSpeechEndpoint, key: azureSpeechKey, model: speechModel) }
        catch { throw LiveCheckError("Check azureSpeechEndpoint and azureSpeechKey in .env.live.json.") }
    }
    func validateAI() throws {
        do {
            guard !aiModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ImportError.invalidResponse }
            _ = try aiClient()
        } catch { throw LiveCheckError("Check aiBaseUrl, aiKey, aiModel, aiProvider, and thinking in .env.live.json.") }
    }
    func aiClient() throws -> AIClient {
        try AIClient(baseURL: aiBaseURL, model: aiModel, key: aiKey, api: aiAPI, thinking: thinking)
    }
}

// Never attach SDK errors, requests, responses, or credentials to Swift Testing diagnostics.
private struct LiveCheckError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["RUN_LIVE_PROVIDER_TESTS"] == "1"), .serialized)
struct LiveProviderTests {
    @MainActor @Test func speechProviderTranscribesAndReusesSavedResult() async throws {
        let credentials = try LiveCredentials.load()
        try credentials.validateAzure()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let speech = directory.appendingPathComponent("sample.aiff"), wav = directory.appendingPathComponent("sample.wav")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", speech.path, "Hello. This is a short audio transcription test for the learning app."]
        say.standardOutput = FileHandle.nullDevice; say.standardError = FileHandle.nullDevice
        do {
            try say.run(); say.waitUntilExit()
            guard say.terminationStatus == 0 else { throw LiveCheckError("Synthetic speech generation failed. Install the macOS Samantha voice.") }
            try AudioPreparation.wav(from: speech, to: wav)
        } catch { throw LiveCheckError("Could not prepare synthetic speech. Check the macOS Samantha voice and local audio conversion.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120; configuration.timeoutIntervalForResource = 180
        let session = Session(configuration: configuration, interceptor: TransferRetryPolicy(retryLimit: 0))
        let client = try MAITranscriber(endpoint: credentials.azureSpeechEndpoint, key: credentials.azureSpeechKey, model: credentials.speechModel, session: session)
        let resultFile = directory.appendingPathComponent("result.json")
        do {
            let result = try await client.transcribe(wav, resultFile: resultFile)
            let transcript = Transcript(title: "Synthetic live check")
            try result.apply(to: transcript)
            guard !transcript.sentences.isEmpty, transcript.orderedSegments.allSatisfy({ ($0.start ?? -1) >= 0 && ($0.end ?? 0) > ($0.start ?? 0) }) else {
                throw LiveCheckError("Azure returned no usable timed transcript.")
            }
            try FileManager.default.removeItem(at: wav)
            // No audio remains: success must come from the persisted result, not another paid upload.
            let cached = try await client.transcribe(wav, resultFile: resultFile)
            guard cached.phrases.map(\.text) == result.phrases.map(\.text) else { throw LiveCheckError("Saved transcription result did not match.") }
        } catch {
            throw LiveCheckError("Speech live check failed. Verify the provider base URL, model, key, and network. Provider details are withheld to protect credentials.")
        }
    }

    @MainActor @Test func aiReturnsUsableTranscriptAnalysis() async throws {
        let credentials = try LiveCredentials.load()
        try credentials.validateAI()
        let transcript = TextImporter.makeTranscript(title: "Synthetic live check", paragraphs: ["Learning a language requires perseverance."])
        do {
            let text = try await credentials.aiClient().completion(
                system: "Return JSON analysis for an English learner. Select sentence 0 as a key sentence with a short Chinese note. Leave extraItems and glosses empty. Return only keySentences, extraItems, and glosses.",
                input: "Sentence 0: Learning a language requires perseverance.", schema: .transcriptAnalysis, maxTokens: 4096)
            let analysis = try JSONDecoder().decode(AIAnalysis.self, from: Data(text.utf8))
            analysis.apply(to: transcript)
            guard transcript.sentences.first?.isKey == true, transcript.sentences.first?.keyNoteZh?.isEmpty == false else {
                throw LiveCheckError("AI did not return usable sentence analysis.")
            }

        } catch {
            throw LiveCheckError("AI live check failed. Verify the provider base URL, model, thinking level, key, and network. Provider details are withheld to protect credentials.")
        }
    }
}

@MainActor @Test(.enabled(if: ProcessInfo.processInfo.environment["RUN_LIVE_BILIBILI_TESTS"] == "1"))
func bilibiliDownloadsAndTranscribesTimedAudio() async throws {
    let credentials = try LiveCredentials.load()
    try credentials.validateAzure()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 120; configuration.timeoutIntervalForResource = 1800
    // Full recordings can be billable; never automatically replay a failed speech upload in live tests.
    let session = Session(configuration: configuration, interceptor: TransferRetryPolicy(retryLimit: 0))
    let audio = directory.appendingPathComponent("bilibili.m4a"), wav = directory.appendingPathComponent("bilibili.wav")
    let resultFile = directory.appendingPathComponent("result.json")
    var stage = "resolving Bilibili audio"
    do {
        let link = try BilibiliLink("https://www.bilibili.com/video/BV1iu4y1K7UE/")
        let media = try await BilibiliClient(session: session).resolve(link)
        guard media.link.episodeID == link.episodeID, !media.audio.isEmpty, media.video.isEmpty,
              let expectedDuration = media.duration, expectedDuration > 0, expectedDuration < 7200 else {
            throw LiveCheckError("Bilibili did not resolve a complete, audio-only recording shorter than two hours.")
        }
        print("Bilibili live check: resolved BV1iu4y1K7UE, duration=\(expectedDuration)s; downloading full audio.")
        stage = "downloading Bilibili audio"
        try await ReliableTransfer.download(media.audio, to: audio, headers: BilibiliClient.headers, session: session)
        let bytes = try audio.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard bytes > 0 else { throw LiveCheckError("Bilibili returned an empty audio download.") }
        stage = "converting downloaded audio to WAV"
        try await Task.detached(priority: .utility) { try AudioPreparation.wav(from: audio, to: wav) }.value
        let file = try AVAudioFile(forReading: wav)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, abs(duration - expectedDuration) <= max(2, expectedDuration * 0.01) else {
            throw LiveCheckError("Downloaded audio duration does not match the complete Bilibili recording.")
        }
        stage = "transcribing the full recording"
        let client = try MAITranscriber(endpoint: credentials.azureSpeechEndpoint, key: credentials.azureSpeechKey,
                                        model: credentials.speechModel, session: session)
        let result = try await client.transcribe(wav, resultFile: resultFile)
        stage = "validating transcript timestamps"
        let transcript = Transcript(title: media.title, author: media.author)
        try result.apply(to: transcript)
        guard !transcript.sentences.isEmpty, abs(result.durationMilliseconds / 1000 - duration) <= 2,
              transcript.orderedSegments.allSatisfy({ segment in
                  guard let start = segment.start, let end = segment.end else { return false }
                  return start.isFinite && end.isFinite && start >= 0 && end > start && end <= duration + 1
              }) else { throw LiveCheckError("Speech returned no usable timed transcript for the downloaded recording.") }
        if client.isOpenRouter, duration > 300,
           !result.phrases.contains(where: { $0.offsetMilliseconds >= 300_000 }) {
            throw LiveCheckError("The full Bilibili transcription is missing timestamps beyond the first five-minute upload part.")
        }
        stage = "reusing the saved transcription without audio"
        try FileManager.default.removeItem(at: wav)
        let cached = try await client.transcribe(wav, resultFile: resultFile)
        guard cached.phrases.map(\.text) == result.phrases.map(\.text),
              cached.durationMilliseconds == result.durationMilliseconds else {
            throw LiveCheckError("Saved Bilibili transcription did not match the original result.")
        }
        let words = result.phrases.reduce(0) { $0 + ($1.words?.count ?? 0) }
        print("Bilibili live check passed: audioBytes=\(bytes), duration=\(duration)s, segments=\(transcript.orderedSegments.count), timedWords=\(words); saved result reused.")
    } catch let error as LiveCheckError { throw error }
    catch {
        throw LiveCheckError("Bilibili live check failed while \(stage). Verify public video availability, speech settings, and network. Provider details are withheld to protect credentials.")
    }
}

@Test func liveCredentialValidationAcceptsNewAndLegacyFields() throws {
    let current = Data(#"{"azureSpeechEndpoint":"https://openrouter.ai/api/v1","azureSpeechModel":"microsoft/mai-transcribe-2","azureSpeechKey":"test-key","aiBaseUrl":"https://api.openai.com/v1","aiProvider":"OpenAIProvider","aiModel":"gpt-6.1","thinking":"medium","aiKey":"test-key"}"#.utf8)
    let credentials = try JSONDecoder().decode(LiveCredentials.self, from: current)
    try credentials.validateAI(); try credentials.validateAzure()
    #expect(credentials.thinking == .medium && credentials.aiAPI == .responses)
    for (provider, api, url, model) in [
        ("AnthropicProvider", AIProviderAPI.anthropic, "https://api.anthropic.com/v1", "claude-sonnet-4-6"),
        ("anthropic", .anthropic, "https://api.anthropic.com/v1", "claude-sonnet-4-6"),
        ("GoogleProvider", .gemini, "https://generativelanguage.googleapis.com/v1beta", "gemini-2.5-flash"),
        ("gemini", .gemini, "https://generativelanguage.googleapis.com/v1beta", "gemini-2.5-flash")
    ] {
        let data = Data(String(decoding: current, as: UTF8.self)
            .replacingOccurrences(of: "OpenAIProvider", with: provider)
            .replacingOccurrences(of: "https://api.openai.com/v1", with: url)
            .replacingOccurrences(of: "gpt-6.1", with: model).utf8)
        let native = try JSONDecoder().decode(LiveCredentials.self, from: data)
        try native.validateAI()
        #expect(native.aiAPI == api)
    }
    let legacy = Data(#"{"azureSpeechEndpoint":"https://study.cognitiveservices.azure.com","azureSpeechKey":"test-key","aiHost":"api.openai.com","aiBasePath":"/v1","aiModel":"gpt-4.1","aiKey":"test-key"}"#.utf8)
    let previous = try JSONDecoder().decode(LiveCredentials.self, from: legacy)
    try previous.validateAI(); try previous.validateAzure()
    #expect(previous.aiAPI == .chat && previous.thinking == .providerDefault)
    let missing = Data(String(decoding: current, as: UTF8.self).replacingOccurrences(of: "test-key", with: "").utf8)
    let blank = try JSONDecoder().decode(LiveCredentials.self, from: missing)
    #expect(throws: LiveCheckError.self) { try blank.validateAI() }
    #expect(throws: LiveCheckError.self) { try blank.validateAzure() }
    let invalid = Data(String(decoding: current, as: UTF8.self).replacingOccurrences(of: "medium", with: "unknown").utf8)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(LiveCredentials.self, from: invalid) }
}
