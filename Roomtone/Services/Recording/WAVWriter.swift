import Foundation
import AVFoundation
import AudioToolbox

/// Streams Float32 mono PCM into a 16-bit PCM WAV file.
final class WAVWriter {
    private let fileURL: URL
    private let sampleRate: Double
    private var audioFile: AVAudioFile?
    private let format: AVAudioFormat
    /// Frames committed to the file — used to keep mic/system on one wall-clock timeline.
    private(set) var framesWritten: AVAudioFramePosition = 0

    init(fileURL: URL, sampleRate: Double) throws {
        self.fileURL = fileURL
        self.sampleRate = sampleRate
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw WAVWriterError.badFormat
        }
        self.format = format
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        audioFile = try AVAudioFile(forWriting: fileURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func write(buffer: AVAudioPCMBuffer) throws {
        guard let audioFile else { return }
        // Same format as file → write directly. Rate mismatch used to throw and leave system.wav empty.
        if buffer.format.channelCount == 1,
           buffer.format.commonFormat == .pcmFormatFloat32,
           abs(buffer.format.sampleRate - sampleRate) < 0.5 {
            try audioFile.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
            return
        }
        guard let mono = Self.convertToFileFormat(buffer, target: format) else {
            throw WAVWriterError.badFormat
        }
        try audioFile.write(from: mono)
        framesWritten += AVAudioFramePosition(mono.frameLength)
    }

    func write(samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else { return }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                channel.update(from: src.baseAddress!, count: samples.count)
            }
        }
        try write(buffer: buffer)
    }

    /// Insert digital silence so this track's timeline matches wall clock / peer track.
    func padToFrameCount(_ target: AVAudioFramePosition) throws {
        let need = target - framesWritten
        guard need > 0 else { return }
        try writeSilence(frameCount: AVAudioFrameCount(need))
    }

    func writeSilence(frameCount: AVAudioFrameCount) throws {
        guard frameCount > 0 else { return }
        let chunk: AVAudioFrameCount = 8192
        var remaining = frameCount
        while remaining > 0 {
            let n = min(chunk, remaining)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else {
                throw WAVWriterError.badFormat
            }
            buffer.frameLength = n
            if let channel = buffer.floatChannelData?[0] {
                for i in 0..<Int(n) { channel[i] = 0 }
            }
            try write(buffer: buffer)
            remaining -= n
        }
    }

    func close() {
        audioFile = nil
    }

    static func mixMonoFiles(systemURL: URL, microphoneURL: URL, outputURL: URL, sampleRate: Double) throws {
        let systemFile = try AVAudioFile(forReading: systemURL)
        let micFile = try AVAudioFile(forReading: microphoneURL)
        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { throw WAVWriterError.badFormat }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let outFile = try AVAudioFile(forWriting: outputURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)

        let capacity: AVAudioFrameCount = 32768
        guard let sysBuf = AVAudioPCMBuffer(pcmFormat: systemFile.processingFormat, frameCapacity: capacity),
              let micBuf = AVAudioPCMBuffer(pcmFormat: micFile.processingFormat, frameCapacity: capacity),
              let mixBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            throw WAVWriterError.badFormat
        }

        while true {
            sysBuf.frameLength = 0
            micBuf.frameLength = 0
            try? systemFile.read(into: sysBuf)
            try? micFile.read(into: micBuf)
            let frames = max(sysBuf.frameLength, micBuf.frameLength)
            if frames == 0 { break }
            mixBuf.frameLength = frames
            let out = mixBuf.floatChannelData![0]
            let sys = sysBuf.floatChannelData.map { $0[0] }
            let mic = micBuf.floatChannelData.map { $0[0] }
            for i in 0..<Int(frames) {
                let s = i < Int(sysBuf.frameLength) ? (sys?[i] ?? 0) : 0
                let m = i < Int(micBuf.frameLength) ? (mic?[i] ?? 0) : 0
                // Average + soft clip
                let mixed = max(-1, min(1, (s + m) * 0.5))
                out[i] = mixed
            }
            try outFile.write(from: mixBuf)
        }
    }

    private static func convertToFileFormat(_ buffer: AVAudioPCMBuffer, target: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format.channelCount == 1,
           buffer.format.commonFormat == .pcmFormatFloat32,
           abs(buffer.format.sampleRate - target.sampleRate) < 0.5 {
            return buffer
        }

        guard let converter = AVAudioConverter(from: buffer.format, to: target) else {
            return toMonoFloat32(buffer, sampleRate: target.sampleRate)
        }

        let ratio = target.sampleRate / max(buffer.format.sampleRate, 1)
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error || out.frameLength == 0 {
            return toMonoFloat32(buffer, sampleRate: target.sampleRate)
        }
        return out
    }

    private static func toMonoFloat32(_ buffer: AVAudioPCMBuffer, sampleRate: Double) -> AVAudioPCMBuffer? {
        guard abs(buffer.format.sampleRate - sampleRate) < 0.5 else { return nil }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return nil }
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else { return nil }
        out.frameLength = buffer.frameLength
        let dst = out.floatChannelData![0]
        let frames = Int(buffer.frameLength)
        if buffer.format.commonFormat == .pcmFormatFloat32, let src = buffer.floatChannelData {
            let channels = Int(buffer.format.channelCount)
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += src[c][i] }
                dst[i] = sum / Float(max(channels, 1))
            }
        } else if buffer.format.commonFormat == .pcmFormatInt16, let src = buffer.int16ChannelData {
            let channels = Int(buffer.format.channelCount)
            for i in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += Float(src[c][i]) / Float(Int16.max) }
                dst[i] = sum / Float(max(channels, 1))
            }
        } else {
            return nil
        }
        return out
    }

    enum WAVWriterError: LocalizedError {
        case badFormat
        var errorDescription: String? { "Unsupported audio format" }
    }
}
