import Foundation

final class FileMeetingStore: MeetingStoring {
    var rootDirectory: URL
    private let fm = FileManager.default
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory
        try? fm.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    func directory(for meeting: Meeting) -> URL {
        rootDirectory.appendingPathComponent(meeting.folderName, isDirectory: true)
    }

    func listMeetings() throws -> [Meeting] {
        try fm.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        let contents = try fm.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try contents.compactMap { url -> Meeting? in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
            let meta = url.appendingPathComponent("meeting.json")
            guard fm.fileExists(atPath: meta.path) else { return nil }
            let data = try Data(contentsOf: meta)
            return try decoder.decode(Meeting.self, from: data)
        }
    }

    func createMeeting(title: String) throws -> Meeting {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let date = Date()
        let safeTitle = sanitize(title)
        var folderName = "\(formatter.string(from: date)) \(safeTitle)"
        var dir = rootDirectory.appendingPathComponent(folderName, isDirectory: true)
        var suffix = 2
        while fm.fileExists(atPath: dir.path) {
            folderName = "\(formatter.string(from: date)) \(safeTitle) \(suffix)"
            dir = rootDirectory.appendingPathComponent(folderName, isDirectory: true)
            suffix += 1
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let meeting = Meeting(
            id: UUID(),
            title: title,
            date: date,
            durationSeconds: 0,
            speakers: [],
            summaryProvider: nil,
            status: .created,
            tags: [],
            folderName: folderName,
            audio: nil
        )
        try save(meeting)
        return meeting
    }

    func deleteMeeting(_ meeting: Meeting) throws {
        let dir = directory(for: meeting)
        if fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
        }
    }

    func save(_ meeting: Meeting) throws {
        let dir = directory(for: meeting)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try encoder.encode(meeting)
        try data.write(to: dir.appendingPathComponent("meeting.json"), options: .atomic)
    }

    func loadTranscript(for meeting: Meeting) throws -> Transcript? {
        let url = directory(for: meeting).appendingPathComponent("transcript.json")
        guard fm.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(Transcript.self, from: Data(contentsOf: url))
    }

    func saveTranscript(_ transcript: Transcript, for meeting: Meeting) throws {
        let data = try encoder.encode(transcript)
        try data.write(to: directory(for: meeting).appendingPathComponent("transcript.json"), options: .atomic)
    }

    func saveSummary(_ summary: MeetingSummary, for meeting: Meeting) throws {
        let dir = directory(for: meeting)
        let data = try encoder.encode(summary)
        try data.write(to: dir.appendingPathComponent("summary.json"), options: .atomic)
        try summary.markdown.write(to: dir.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
    }

    func loadSummary(for meeting: Meeting) throws -> MeetingSummary? {
        let url = directory(for: meeting).appendingPathComponent("summary.json")
        guard fm.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(MeetingSummary.self, from: Data(contentsOf: url))
    }

    func renameSpeaker(meetingID: UUID, from: String, to: String) throws {
        guard var meeting = try listMeetings().first(where: { $0.id == meetingID }) else {
            throw StoreError.notFound
        }
        guard var transcript = try loadTranscript(for: meeting) else { return }
        transcript.blocks = transcript.blocks.map { block in
            var b = block
            if b.speaker == from { b.speaker = to }
            return b
        }
        transcript.speakers = transcript.speakers.map { $0 == from ? to : $0 }
        if !transcript.speakers.contains(to) { transcript.speakers.append(to) }
        meeting.speakers = transcript.speakers
        try saveTranscript(transcript, for: meeting)
        try save(meeting)
        let exporter = MultiFormatExporter()
        try exporter.export(transcript: transcript, meeting: meeting, formats: AppSettings.load().exportFormats)
    }

    func renameMeeting(meetingID: UUID, title: String) throws {
        guard var meeting = try listMeetings().first(where: { $0.id == meetingID }) else {
            throw StoreError.notFound
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        meeting.title = trimmed
        try save(meeting)
    }

    private func sanitize(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = title.components(separatedBy: invalid).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Meeting" : trimmed
    }

    enum StoreError: LocalizedError {
        case notFound
        var errorDescription: String? { "Meeting not found" }
    }
}
