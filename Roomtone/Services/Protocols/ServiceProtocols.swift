import Foundation

struct AudioSourceOption: Identifiable, Hashable {
    var id: String
    var name: String
    var kind: Kind

    enum Kind: String, Hashable {
        case application
        case display
        case microphone
    }
}

struct CaptureConfiguration {
    var meetingDirectory: URL
    var microphoneDeviceID: String?
    var sampleRate: Double
}

struct ActiveRecording {
    var startedAt: Date
}

struct CaptureResult {
    var durationSeconds: TimeInterval
    var systemURL: URL
    var microphoneURL: URL
    var combinedURL: URL
}

struct AudioLevels {
    var microphone: Float
    var system: Float
}

@MainActor
protocol AudioCapturing: AnyObject {
    func availableMicrophones() -> [AudioSourceOption]
    func start(configuration: CaptureConfiguration) async throws -> ActiveRecording
    func pause()
    func resume()
    func stop() async throws -> CaptureResult
    func currentLevels() -> AudioLevels
}

struct TranscriptionOptions {
    var language: String
    var model: WhisperModel
    var assignLocalMicAsYou: Bool
}

protocol Transcribing: AnyObject {
    func transcribe(meeting: Meeting, options: TranscriptionOptions) async throws -> Transcript
}

struct SummaryOptions {
    var provider: AIProvider
    var baseURL: String
    var model: String
    var apiKey: String
}

protocol Summarizing: AnyObject {
    func generateSummary(transcript: Transcript, options: SummaryOptions) async throws -> MeetingSummary
}

protocol MeetingStoring: AnyObject {
    func listMeetings() throws -> [Meeting]
    func createMeeting(title: String) throws -> Meeting
    func save(_ meeting: Meeting) throws
    func deleteMeeting(_ meeting: Meeting) throws
    func loadTranscript(for meeting: Meeting) throws -> Transcript?
    func saveTranscript(_ transcript: Transcript, for meeting: Meeting) throws
    func saveSummary(_ summary: MeetingSummary, for meeting: Meeting) throws
    func loadSummary(for meeting: Meeting) throws -> MeetingSummary?
    func renameSpeaker(meetingID: UUID, from: String, to: String) throws
    func renameMeeting(meetingID: UUID, title: String) throws
    func directory(for meeting: Meeting) -> URL
}

protocol TranscriptExporting: AnyObject {
    func export(transcript: Transcript, meeting: Meeting, formats: [ExportFormat]) throws
}
