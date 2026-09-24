import Foundation

final class MultiFormatExporter: TranscriptExporting {
    func export(transcript: Transcript, meeting: Meeting, formats: [ExportFormat]) throws {
        let dir = FileMeetingStore(rootDirectory: AppSettings.load().resolvedOutputDirectory).directory(for: meeting)
        for format in formats {
            let filename = format == .markdown ? "transcript.md" : "transcript.\(format.fileExtension)"
            let url = dir.appendingPathComponent(filename)
            let body = render(transcript: transcript, format: format)
            try body.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func render(transcript: Transcript, format: ExportFormat) -> String {
        switch format {
        case .markdown:
            return transcript.blocks.map { b in
                "### \(Self.ts(b.start)) – \(Self.ts(b.end)) · \(b.speaker)\n\n\(b.text)\n"
            }.joined(separator: "\n")
        case .txt:
            return transcript.blocks.map { b in
                "[\(Self.ts(b.start))] \(b.speaker): \(b.text)"
            }.joined(separator: "\n")
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = (try? encoder.encode(transcript)) ?? Data("{}".utf8)
            return String(data: data, encoding: .utf8) ?? "{}"
        case .srt:
            return transcript.blocks.enumerated().map { idx, b in
                """
                \(idx + 1)
                \(Self.srt(b.start)) --> \(Self.srt(b.end))
                \(b.speaker): \(b.text)
                """
            }.joined(separator: "\n\n")
        case .vtt:
            let cues = transcript.blocks.map { b in
                "\(Self.vtt(b.start)) --> \(Self.vtt(b.end))\n\(b.speaker): \(b.text)"
            }.joined(separator: "\n\n")
            return "WEBVTT\n\n\(cues)\n"
        }
    }

    private static func ts(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    private static func srt(_ t: TimeInterval) -> String {
        let totalMs = Int((t * 1000).rounded())
        let h = totalMs / 3_600_000
        let m = (totalMs % 3_600_000) / 60_000
        let s = (totalMs % 60_000) / 1000
        let ms = totalMs % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    private static func vtt(_ t: TimeInterval) -> String {
        let totalMs = Int((t * 1000).rounded())
        let h = totalMs / 3_600_000
        let m = (totalMs % 3_600_000) / 60_000
        let s = (totalMs % 60_000) / 1000
        let ms = totalMs % 1000
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}
