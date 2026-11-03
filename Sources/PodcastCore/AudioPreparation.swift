import Foundation
import AVFoundation

public enum AudioPreparation {
    public static func wav(from source: URL, to destination: URL) throws {
        if FileManager.default.fileExists(atPath: destination.path) { return }
        let input = try AVAudioFile(forReading: source)
        let duration = Double(input.length) / input.processingFormat.sampleRate
        guard duration.isFinite, duration > 0, duration < 7200 else {
            throw ImportError.service("MAI-Transcribe supports recordings shorter than two hours. Choose a shorter video part.")
        }
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192) else { throw ImportError.invalidResponse }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let output = try AVAudioFile(forWriting: temporary, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
            var ended = false
            while !ended {
                try Task.checkCancellation()
                var conversionError: NSError?
                var readError: Error?
                let status = converter.convert(to: outputBuffer, error: &conversionError) { count, state in
                    do {
                        guard input.framePosition < input.length else { state.pointee = .endOfStream; return nil }
                        let remaining = AVAudioFrameCount(min(AVAudioFramePosition(inputBuffer.frameCapacity), input.length - input.framePosition))
                        try input.read(into: inputBuffer, frameCount: min(count, remaining))
                        state.pointee = inputBuffer.frameLength == 0 ? .endOfStream : .haveData
                        return inputBuffer.frameLength == 0 ? nil : inputBuffer
                    } catch { readError = error; state.pointee = .endOfStream; return nil }
                }
                if let readError { throw readError }
                if let conversionError { throw conversionError }
                guard status != .error else { throw ImportError.invalidResponse }
                if outputBuffer.frameLength > 0 { try output.write(from: outputBuffer) }
                ended = status == .endOfStream
            }
        }
        try ReliableTransfer.commit(temporary, to: destination)
    }
    public struct Chunk: Sendable {
        public let file: URL
        public let offset: Double
        public let duration: Double
    }
    public static func chunks(from wav: URL, prefix: URL) throws -> [Chunk] {
        let seconds = 300
        let input = try AVAudioFile(forReading: wav)
        let rate = input.processingFormat.sampleRate
        let duration = Double(input.length) / rate
        guard rate == 16000, input.processingFormat.channelCount == 1, duration > 0, duration < 7200 else { throw ImportError.invalidResponse }
        if duration <= Double(seconds) { return [Chunk(file: wav, offset: 0, duration: duration)] }
        let frames = AVAudioFramePosition(Double(seconds) * rate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 8192) else { throw ImportError.invalidResponse }
        var chunks: [Chunk] = []
        for start in stride(from: AVAudioFramePosition(0), to: input.length, by: Int(frames)) {
            try Task.checkCancellation()
            let end = min(start + frames, input.length)
            let file = prefix.appendingPathExtension("part-\(chunks.count).wav")
            if !FileManager.default.fileExists(atPath: file.path) {
                let temporary = prefix.appendingPathExtension(UUID().uuidString + ".wav")
                defer { try? FileManager.default.removeItem(at: temporary) }
                input.framePosition = start
                do {
                    let output = try AVAudioFile(forWriting: temporary, settings: input.fileFormat.settings)
                    while input.framePosition < end {
                        try Task.checkCancellation()
                        try input.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, end - input.framePosition)))
                        guard buffer.frameLength > 0 else { throw ImportError.invalidResponse }
                        try output.write(from: buffer)
                    }
                }
                try ReliableTransfer.commit(temporary, to: file)
            }
            chunks.append(Chunk(file: file, offset: Double(start) / rate, duration: Double(end - start) / rate))
        }
        return chunks
    }
    public static func video(audio: URL, track: URL, to destination: URL) async throws {
        let composition = AVMutableComposition()
        let audioAsset = AVURLAsset(url: audio), videoAsset = AVURLAsset(url: track)
        for (asset, type) in [(audioAsset, AVMediaType.audio), (videoAsset, AVMediaType.video)] {
            guard let source = try await asset.loadTracks(withMediaType: type).first,
                  let target = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ImportError.invalidResponse }
            if type == .video { target.preferredTransform = try await source.load(.preferredTransform) }
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: try await asset.load(.duration)), of: source, at: .zero)
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw ImportError.invalidResponse }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        export.outputURL = temporary; export.outputFileType = .mp4
        await export.export()
        guard export.status == .completed else { throw export.error ?? ImportError.invalidResponse }
        try ReliableTransfer.commit(temporary, to: destination)
    }
}
