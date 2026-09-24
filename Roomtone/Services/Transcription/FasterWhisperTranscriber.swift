import Foundation

/// Offline transcription via the Python faster-whisper sidecar (`Scripts/asr/transcribe.py`).
/// Falls back to a dual-track heuristic stub when the sidecar is unavailable (dev UX).
final class FasterWhisperTranscriber: Transcribing {
    private let scriptURL: URL
    private let store = FileMeetingStore(rootDirectory: AppSettings.load().resolvedOutputDirectory)

    init(scriptURL: URL? = nil) {
        if let scriptURL {
            self.scriptURL = scriptURL
        } else {
            // Prefer repo-relative script when running from Xcode / derived sources
            let env = ProcessInfo.processInfo.environment["ROOMTONE_ASR_SCRIPT"]
            if let env, !env.isEmpty {
                self.scriptURL = URL(fileURLWithPath: env)
            } else if let found = Self.findRepoScript() {
                self.scriptURL = found
            } else {
                self.scriptURL = Bundle.main.bundleURL
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Scripts/asr/transcribe.py")
            }
        }
    }

    func transcribe(meeting: Meeting, options: TranscriptionOptions) async throws -> Transcript {
        let dir = FileMeetingStore(rootDirectory: AppSettings.load().resolvedOutputDirectory).directory(for: meeting)
        let combined = dir.appendingPathComponent("combined.wav")
        let mic = dir.appendingPathComponent("microphone.wav")
        let system = dir.appendingPathComponent("system.wav")
        let outJSON = dir.appendingPathComponent("asr-raw.json")

        if FileManager.default.fileExists(atPath: scriptURL.path) {
            try await runSidecar(
                audioURL: combined,
                micURL: mic,
                systemURL: system,
                outputURL: outJSON,
                language: options.language,
                model: options.model.rawValue
            )
            let data = try Data(contentsOf: outJSON)
            let raw = try JSONDecoder().decode(SidecarTranscript.self, from: data)
            return raw.toTranscript(assignLocalMicAsYou: options.assignLocalMicAsYou)
        }

        // Dev fallback: produce a placeholder so the rest of the pipeline is testable.
        return Transcript(
            blocks: [
                TranscriptBlock(
                    start: 0,
                    end: max(1, meeting.durationSeconds),
                    speaker: "Me",
                    text: "[Transcription sidecar not installed. Run Scripts/asr/setup.sh then retry Process.]"
                )
            ],
            speakers: ["Me"],
            language: options.language
        )
    }

    private func runSidecar(
        audioURL: URL,
        micURL: URL,
        systemURL: URL,
        outputURL: URL,
        language: String,
        model: String
    ) async throws {
        let interpreter = try Self.resolveInterpreter(scriptURL: scriptURL)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = interpreter
            process.arguments = [
                scriptURL.path,
                "--audio", audioURL.path,
                "--mic", micURL.path,
                "--system", systemURL.path,
                "--output", outputURL.path,
                "--language", language,
                "--model", model
            ]
            let err = Pipe()
            process.standardError = err
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "ASR failed"
                    cont.resume(throwing: TranscribeError.sidecarFailed(msg))
                }
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: error)
            }
        }
    }


    /// The ASR virtualenv, or an explicit override. Never a bare `python3`:
    /// a stray interpreter can hold a numpy that segfaults on import, which no
    /// amount of `except ImportError` inside the sidecar can survive.
    private static func resolveInterpreter(scriptURL: URL) throws -> URL {
        let override = ProcessInfo.processInfo.environment["ROOMTONE_ASR_PYTHON"]
        if let override, !override.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: override) else {
                throw TranscribeError.interpreterUnusable(override)
            }
            return URL(fileURLWithPath: override)
        }
        let venvPython = scriptURL
            .deletingLastPathComponent()
            .appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: venvPython.path) else {
            throw TranscribeError.environmentMissing(venvPython.path)
        }
        return venvPython
    }

    private static func findRepoScript() -> URL? {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = url.appendingPathComponent("Scripts/asr/transcribe.py")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            url = url.deletingLastPathComponent()
        }
        // Checkout this build came from (Xcode runs the app from DerivedData).
        if let root = Bundle.main.object(forInfoDictionaryKey: "RoomtoneSourceRoot") as? String,
           !root.isEmpty {
            let candidate = URL(fileURLWithPath: root).appendingPathComponent("Scripts/asr/transcribe.py")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    enum TranscribeError: LocalizedError {
        case sidecarFailed(String)
        case environmentMissing(String)
        case interpreterUnusable(String)
        var errorDescription: String? {
            switch self {
            case .sidecarFailed(let m):
                return m
            case .environmentMissing(let path):
                return """
                Transcription environment missing at \(path).
                Run Scripts/asr/setup.sh, then retry Process.
                """
            case .interpreterUnusable(let path):
                return "ROOMTONE_ASR_PYTHON is not an executable file: \(path)"
            }
        }
    }
}

private struct SidecarTranscript: Decodable {
    struct Segment: Decodable {
        var start: Double
        var end: Double
        var text: String
        var speaker: String?
    }
    var segments: [Segment]
    var language: String?

    func toTranscript(assignLocalMicAsYou: Bool) -> Transcript {
        let mappedBlocks = segments.map { seg -> TranscriptBlock in
            let raw = seg.speaker ?? "Me"
            let mapped = Self.mapSpeaker(raw, assignLocalMicAsYou: assignLocalMicAsYou)
            return TranscriptBlock(
                start: seg.start,
                end: seg.end,
                speaker: mapped,
                text: seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        // Safety net if sidecar didn't merge (older script). Remotes tolerate longer pauses.
        let blocks = Self.mergeAdjacent(mappedBlocks)
        let speakers = Array(Set(blocks.map(\.speaker))).sorted()
        return Transcript(blocks: blocks, speakers: speakers, language: language)
    }

    private static func mapSpeaker(_ raw: String, assignLocalMicAsYou: Bool) -> String {
        switch raw {
        case "SPEAKER_LOCAL", "You", "Speaker 1", "Me":
            return "Me"
        default:
            return assignLocalMicAsYou && raw == "Me" ? "Me" : raw
        }
    }

    private static func mergeGap(for speaker: String) -> TimeInterval {
        speaker == "Me" ? 2.0 : 3.0
    }

    private static func mergeAdjacent(_ blocks: [TranscriptBlock]) -> [TranscriptBlock] {
        guard var current = blocks.first else { return [] }
        var out: [TranscriptBlock] = []
        for next in blocks.dropFirst() {
            let gap = next.start - current.end
            if next.speaker == current.speaker, gap <= mergeGap(for: current.speaker) {
                current = TranscriptBlock(
                    start: current.start,
                    end: max(current.end, next.end),
                    speaker: current.speaker,
                    text: [current.text, next.text].filter { !$0.isEmpty }.joined(separator: " ")
                )
            } else {
                out.append(current)
                current = next
            }
        }
        out.append(current)
        return out
    }
}
