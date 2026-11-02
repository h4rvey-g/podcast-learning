import Foundation
import AVFoundation
import Observation
import PodcastCore

struct AudioStore {
    static func directory() throws -> URL {
        let url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func file(_ id: UUID) throws -> URL { try directory().appendingPathComponent(id.uuidString + ".mp3") }
    static func localURL(_ id: UUID) -> URL? {
        guard let url = try? file(id), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
    static func size(_ id: UUID) -> Int64 {
        guard let url = localURL(id), let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
    static func download(_ remote: URL, id: UUID) async throws {
        guard ["https", "http"].contains(remote.scheme) else { throw ImportError.invalidURL }
        let (temporary, response) = try await URLSession.shared.download(from: remote)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !(http.mimeType ?? "").contains("text"), !(http.mimeType ?? "").contains("json") else { throw ImportError.invalidResponse }
        let destination = try file(id)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: destination) }
        var url = destination, values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    static func delete(_ id: UUID) throws {
        if let url = localURL(id) { try FileManager.default.removeItem(at: url) }
    }
}

@MainActor @Observable final class ClipPlayer: NSObject, AVSpeechSynthesizerDelegate {
    var isPlaying = false
    var position: Double = 0
    var duration: Double = 0
    var speed: Float = 1
    var error: String?
    private let player = AVPlayer()
    private let speech = AVSpeechSynthesizer()
    private var boundary: Any?
    private var periodic: Any?
    private var notifications: [NSObjectProtocol] = []
    private var currentURL: URL?
    override init() {
        super.init(); speech.delegate = self
        periodic = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                let total = self.player.currentItem?.duration.seconds ?? 0
                self.duration = total.isFinite ? total : 0
                if self.player.currentItem?.status == .failed {
                    self.error = "Audio playback failed. Try downloading this episode again."
                    self.isPlaying = false
                }
            }
        }
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.stop() } })
        notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            guard note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
            Task { @MainActor in self?.stop() }
        })
        notifications.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.isPlaying = false } })
    }
    isolated deinit {
        if let periodic { player.removeTimeObserver(periodic) }
        if let boundary { player.removeTimeObserver(boundary) }
        notifications.forEach(NotificationCenter.default.removeObserver)
    }
    private func activate() -> Bool {
        do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio); try AVAudioSession.sharedInstance().setActive(true); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func play(text: String, segment: Segment? = nil, transcript: Transcript? = nil, settings: SettingsStore, clip: Bool = true) {
        stop(); guard activate() else { return }
        let validTiming = (segment?.start ?? -1) >= 0 && (segment?.end ?? 0) > (segment?.start ?? 0)
        if let transcript, let url = AudioStore.localURL(transcript.id), !clip || validTiming {
            if currentURL != url { player.replaceCurrentItem(with: AVPlayerItem(url: url)); currentURL = url; position = 0 }
            let start = clip ? max(0, (segment?.start ?? 0) - 0.3) : position
            if clip, let end = segment?.end, end > start {
                boundary = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: end + 0.3, preferredTimescale: 600))], queue: .main) { [weak self] in Task { @MainActor in self?.stop() } }
            }
            isPlaying = true
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] success in
                Task { @MainActor in guard let self, success, self.isPlaying else { return }; self.player.playImmediately(atRate: self.speed) }
            }
        } else {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = AVSpeechSynthesisVoice(language: settings.voice)
            utterance.rate = Float(settings.rate); speech.speak(utterance); isPlaying = true
        }
    }
    func toggle(text: String, transcript: Transcript, settings: SettingsStore) {
        if isPlaying {
            player.pause()
            if speech.isSpeaking { speech.pauseSpeaking(at: .immediate) }
            isPlaying = false
        } else if speech.isPaused {
            speech.continueSpeaking(); isPlaying = true
        } else { play(text: text, transcript: transcript, settings: settings, clip: false) }
    }
    func skip(_ seconds: Double) {
        guard currentURL != nil else { return }
        player.seek(to: CMTime(seconds: max(0, min(duration, position + seconds)), preferredTimescale: 600))
    }
    func changeSpeed() { speed = speed >= 1.5 ? 0.75 : speed + 0.25; if isPlaying { player.rate = speed } }
    func stop() {
        player.pause(); speech.stopSpeaking(at: .immediate); isPlaying = false
        if let boundary { player.removeTimeObserver(boundary); self.boundary = nil }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) { Task { @MainActor in self.isPlaying = false } }
}
