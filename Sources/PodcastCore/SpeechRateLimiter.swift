import Foundation

// OpenRouter has no published paid-TTS concurrency quota; learn from 429s, not the deprecated key.rate_limit.
actor SpeechRateLimiter {
    static let shared = SpeechRateLimiter()
    static let maximum = 8
    private(set) var concurrency = 2
    private(set) var active = 0
    private(set) var blockedUntil = Date.distantPast
    private var successes = 0

    func acquire() async throws {
        while true {
            try Task.checkCancellation()
            let delay = blockedUntil.timeIntervalSinceNow
            guard delay <= 3600 else { throw ImportError.service("OpenRouter's rate-limit reset is more than an hour away. Retry later; completed audio parts are kept.") }
            if active < concurrency && delay <= 0 { active += 1; return }
            try await Task.sleep(for: .seconds(max(0.05, delay)))
        }
    }
    @discardableResult func complete(_ response: HTTPURLResponse?, attempt: Int = 0, now: Date = Date()) -> Bool {
        active -= 1
        guard let response else { return false }
        if response.statusCode == 429 {
            concurrency = max(1, concurrency / 2); successes = 0
            var delay = response.value(forHTTPHeaderField: "Retry-After").flatMap(TransferRetryPolicy.retryAfter) ?? pow(2, Double(attempt))
            if response.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap(Int.init) == 0,
               let value = response.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(Double.init), value.isFinite {
                let reset = Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
                delay = max(delay, reset.timeIntervalSince(now))
            }
            blockedUntil = max(blockedUntil, now.addingTimeInterval(delay))
            return delay <= 3600
        }
        if (200..<300).contains(response.statusCode), now >= blockedUntil {
            successes += 1
            if successes >= concurrency { concurrency = min(Self.maximum, concurrency + 1); successes = 0 }
        }
        return false
    }
}
