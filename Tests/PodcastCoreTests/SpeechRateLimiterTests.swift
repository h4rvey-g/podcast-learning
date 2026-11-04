import Foundation
import Testing
@testable import PodcastCore

private func response(_ status: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://openrouter.ai/api/v1/audio/speech")!, statusCode: status, httpVersion: nil, headerFields: headers)!
}

@Test func speechLimiterAdaptsConcurrencyAndHonorsAnExhaustedQuotaReset() async throws {
    let limiter = SpeechRateLimiter()
    #expect(await limiter.concurrency == 2)
    for _ in 0..<2 { try await limiter.acquire(); await limiter.complete(response(200)) }
    #expect(await limiter.concurrency == 3)
    try await limiter.acquire()
    let now = Date(), reset = now.addingTimeInterval(0.2)
    #expect(await limiter.complete(response(429, headers: ["Retry-After": "0.01", "X-RateLimit-Remaining": "0",
        "X-RateLimit-Reset": String(reset.timeIntervalSince1970)]), now: now))
    #expect(await limiter.concurrency == 1)
    #expect(await limiter.blockedUntil >= reset)
    try await limiter.acquire()
    #expect(Date() >= reset)
    await limiter.complete(response(401))
    #expect(await limiter.concurrency == 1)
    #expect(await limiter.active == 0)
    for _ in 0..<100 { try await limiter.acquire(); await limiter.complete(response(200)) }
    #expect(await limiter.concurrency == SpeechRateLimiter.maximum)
}

@Test func speechLimiterCancellationDoesNotConsumeAPermitAndLongResetsStopForManualRetry() async throws {
    let limiter = SpeechRateLimiter()
    try await limiter.acquire(); try await limiter.acquire()
    let waiting = Task { try await limiter.acquire() }
    waiting.cancel()
    await #expect(throws: CancellationError.self) { try await waiting.value }
    #expect(await limiter.active == 2)
    await limiter.complete(nil); await limiter.complete(nil)
    #expect(await limiter.active == 0)
    try await limiter.acquire()
    #expect(await limiter.complete(response(429, headers: ["Retry-After": "3601"])) == false)
    await #expect(throws: ImportError.self) { try await limiter.acquire() }
    #expect(await limiter.active == 0)
}

@Test func speechPieceValidationRejectsEmptyOversizedAndExcessiveContent() throws {
    for pieces in [[], [" "], [String(repeating: "x", count: 4001)], [String(repeating: "👨‍👩‍👧‍👦", count: 1000)], Array(repeating: String(repeating: "x", count: 4000), count: 1250)] {
        #expect(throws: ImportError.self) { try SpeechText.validatePieces(pieces) }
    }
    try SpeechText.validatePieces(["First paragraph.\n\nA heading.", "Second paragraph."])
}
