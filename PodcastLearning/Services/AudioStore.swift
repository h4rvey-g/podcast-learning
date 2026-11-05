import Foundation
import AVFoundation
import Observation
import PodcastCore

@MainActor @Observable final class ClipPlayer: NSObject, AVSpeechSynthesizerDelegate {
    var isPlaying = false
    var position: Double = 0
    var duration: Double = 0
    var segmentID: UUID?
    private(set) var activeSegmentID: UUID?
    var transcriptID: UUID?
    private var audioTranscript: Transcript?
    var speechProgress: Double = 0
    var speed: Float = 1
    private var utterance: AVSpeechUtterance?
    private var speechTranscript: Transcript?
    var error: String?
    private let player = AVPlayer()
    private let speech = AVSpeechSynthesizer()
    private var boundary: Any?
    private var periodic: Any?
    private var notifications: [NSObjectProtocol] = []
    private var currentURL: URL?
    private var playbackRequest = UUID()
    private var seeking = false
    private var synthesisTask: Task<Void, Never>?
    private let speechCache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var generatedRanges: [(UUID, PlaybackRange)] = []
    private var generatedPlayback = false
    override init() {
        super.init(); speech.delegate = self
        periodic = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.seeking, self.utterance == nil else { return }
                let time = self.player.currentTime().seconds
                // Only publish real changes: a paused player still fires this observer.
                let newPosition = time.isFinite ? time : 0
                if self.position != newPosition { self.position = newPosition }
                let total = self.player.currentItem?.duration.seconds ?? 0
                let newDuration = total.isFinite ? total : 0
                if self.duration != newDuration { self.duration = newDuration }
                if self.generatedPlayback {
                    self.speechProgress = newDuration > 0 ? min(1, newPosition / newDuration) : 0
                    if let id = self.generatedRanges.first(where: { newPosition >= $0.1.start && newPosition < $0.1.end })?.0 { self.activeSegmentID = id }
                }
                if self.segmentID == nil, let transcript = self.audioTranscript {
                    let id = ClipPlayer.segmentID(at: newPosition, in: transcript)
                    if self.activeSegmentID != id { self.activeSegmentID = id }
                }
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
        notifications.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.stop() } })
    }
    isolated deinit {
        synthesisTask?.cancel()
        try? FileManager.default.removeItem(at: speechCache)
        if let periodic { player.removeTimeObserver(periodic) }
        if let boundary { player.removeTimeObserver(boundary) }
        notifications.forEach(NotificationCenter.default.removeObserver)
    }
    private func activate() -> Bool {
        do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio); try AVAudioSession.sharedInstance().setActive(true); return true }
        catch { self.error = error.localizedDescription; return false }
    }
    func isWaitingForAudio(_ transcript: Transcript, settings: SettingsStore) -> Bool {
        settings.speechService == .openRouter &&
        ["preparing", "pending", "preparationFailed", "failed"].contains(transcript.synthesisState) &&
        AudioStore.localURL(transcript.id) == nil
    }
    func play(text: String, segment: Segment? = nil, transcript: Transcript? = nil, settings: SettingsStore, clip: Bool = true, startAt: Double? = nil, readyAudio: URL? = nil) {
        stop()
        if let transcript, isWaitingForAudio(transcript, settings: settings), readyAudio == nil {
            error = "AI audio is not ready. Wait for generation to finish, or retry document processing or audio generation in the reader."
            return
        }
        guard activate() else { return }
        error = nil
        segmentID = segment?.id; transcriptID = transcript?.id; speechProgress = 0
        let paragraphFile = transcript.flatMap { AudioStore.localURL($0.id) } == nil ? readyAudio : nil
        let range = paragraphFile == nil ? PlaybackRange(start: segment?.start ?? -1, end: segment?.end ?? 0) : nil
        let validTiming = range != nil
        if let transcript, let url = AudioStore.localURL(transcript.id) ?? paragraphFile, !clip || validTiming || paragraphFile != nil {
            if currentURL != url { player.replaceCurrentItem(with: AVPlayerItem(url: url)); currentURL = url; position = 0 }
            generatedPlayback = paragraphFile != nil
            let start = paragraphFile != nil ? 0 : startAt ?? (clip ? max(0, (range?.start ?? 0) - 0.3) : position)
            position = start
            audioTranscript = paragraphFile == nil ? transcript : nil
            activeSegmentID = segment?.id ?? ClipPlayer.segmentID(at: start, in: transcript)
            let request = playbackRequest
            if clip, let end = range?.end {
                boundary = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: end + 0.3, preferredTimescale: 600))], queue: .main) { [weak self] in
                    Task { @MainActor in if let self, self.playbackRequest == request { self.stop() } }
                }
            }
            isPlaying = true; seeking = true
            player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] success in
                Task { @MainActor in
                    guard let self, request == self.playbackRequest else { return }
                    self.seeking = false
                    guard success else { self.isPlaying = false; self.error = "Could not seek to this playback position."; return }
                    if self.isPlaying { self.player.playImmediately(atRate: self.speed) }
                }
            }
        } else if settings.speechService == .openRouter {
            playGenerated(text: text, transcript: transcript, settings: settings, clip: clip)
        } else {
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = settings.speechVoice
            self.utterance = utterance; speechTranscript = clip ? nil : transcript
            audioTranscript = nil
            activeSegmentID = segment?.id
            utterance.rate = Float(settings.rate); speech.speak(utterance); isPlaying = true
        }
    }
    private func playGenerated(text: String, transcript: Transcript?, settings: SettingsStore, clip: Bool) {
        let request = playbackRequest, directory = speechCache
        let model = settings.ttsModel, voice = settings.ttsVoice
        let segments = clip ? [] : transcript?.orderedSegments ?? []
        let paragraphs = segments.isEmpty ? [text] : segments.map(\.text)
        let ids = segments.map(\.id)
        player.replaceCurrentItem(with: nil); currentURL = nil; position = 0; duration = 0
        error = nil; isPlaying = true
        synthesisTask = Task { [weak self] in
            do {
                let client = try SpeechSynthesizer(key: APIKey.read(account: "openRouterTTS"), model: model, voice: voice)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let output = directory.appendingPathComponent("playback.m4a")
                let result = try await client.generate(paragraphs: paragraphs, directory: directory, to: output)
                try Task.checkCancellation()
                guard let self, self.playbackRequest == request else { return }
                self.generatedPlayback = true
                self.generatedRanges = Array(zip(ids, result.ranges))
                self.currentURL = output; self.duration = result.duration
                self.player.replaceCurrentItem(with: AVPlayerItem(url: output))
                self.synthesisTask = nil
                self.player.playImmediately(atRate: self.speed)
            } catch {
                guard let self, self.playbackRequest == request else { return }
                self.synthesisTask = nil; self.isPlaying = false
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
    private static func segmentID(at time: Double, in transcript: Transcript) -> UUID? {
        transcript.orderedSegments.first { segment in
            guard let start = segment.start, let end = segment.end else { return false }
            return time >= start && time < end
        }?.id
    }
    func toggle(text: String, transcript: Transcript, settings: SettingsStore) {
        if !isWaitingForAudio(transcript, settings: settings), transcriptID == transcript.id && (isPlaying || speech.isPaused || player.currentItem != nil) { toggleCurrent() }
        else { play(text: text, transcript: transcript, settings: settings, clip: false) }
    }
    // Reads cached state only: the reader's rows must not depend on the 10 Hz position tick.
    func isActive(_ segment: Segment, in transcript: Transcript) -> Bool { isPlaying && isCurrent(segment, in: transcript) }
    private func isCurrent(_ segment: Segment, in transcript: Transcript) -> Bool {
        transcriptID == transcript.id && activeSegmentID == segment.id
    }
    func toggleParagraph(_ segment: Segment, transcript: Transcript, settings: SettingsStore, readyAudio: URL? = nil) {
        if (!isWaitingForAudio(transcript, settings: settings) || readyAudio != nil), isCurrent(segment, in: transcript) { toggleCurrent() }
        else { play(text: segment.text, segment: segment, transcript: transcript, settings: settings, readyAudio: readyAudio) }
    }
    private func toggleCurrent() {
        if synthesisTask != nil { stop(); return }
        if isPlaying {
            player.pause()
            if speech.isSpeaking { speech.pauseSpeaking(at: .immediate) }
            isPlaying = false
        } else {
            if speech.isPaused { speech.continueSpeaking() }
            else { player.playImmediately(atRate: speed) }
            isPlaying = true
        }
    }
    func progress(in segment: Segment?) -> Double {
        guard let segment, segmentID == segment.id else { return 0 }
        if utterance != nil || generatedPlayback { return speechProgress }
        guard let range = PlaybackRange(start: segment.start ?? -1, end: segment.end ?? 0) else { return 0 }
        return range.fraction(at: position)
    }
    func canSeek(_ paragraph: PracticeParagraph, in transcript: Transcript) -> Bool {
        AudioStore.localURL(transcript.id) != nil && PlaybackRange(start: paragraph.segment?.start ?? -1, end: paragraph.segment?.end ?? 0) != nil
    }
    func seek(to fraction: Double, in paragraph: PracticeParagraph, transcript: Transcript, settings: SettingsStore) {
        guard canSeek(paragraph, in: transcript), let range = PlaybackRange(start: paragraph.segment?.start ?? -1, end: paragraph.segment?.end ?? 0) else { return }
        play(text: paragraph.text, segment: paragraph.segment, transcript: transcript, settings: settings, startAt: range.time(at: fraction))
    }
    func skip(_ seconds: Double) {
        guard currentURL != nil else { return }
        player.seek(to: CMTime(seconds: max(0, min(duration, position + seconds)), preferredTimescale: 600))
    }
    func changeSpeed() { speed = speed >= 1.5 ? 0.75 : speed + 0.25; if isPlaying { player.rate = speed } }
    func stop() {
        playbackRequest = UUID(); seeking = false
        synthesisTask?.cancel(); synthesisTask = nil; generatedRanges = []; generatedPlayback = false
        player.pause(); utterance = nil; speechTranscript = nil; speech.stopSpeaking(at: .immediate); isPlaying = false
        segmentID = nil; activeSegmentID = nil; audioTranscript = nil; transcriptID = nil; speechProgress = 0
        if let boundary { player.removeTimeObserver(boundary); self.boundary = nil }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in if self.utterance === utterance { self.stop() } }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString range: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard self.utterance === utterance else { return }
            if let segment = self.speechTranscript?.segment(atSpeechOffset: range.location) { self.segmentID = segment.id; self.activeSegmentID = segment.id }
            self.speechProgress = Double(range.location + range.length) / Double(max(1, utterance.speechString.utf16.count))
        }
    }
}
