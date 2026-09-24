import Foundation
@MainActor
final class AppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var meetings: [Meeting] = []
    @Published var selectedMeetingID: Meeting.ID?
    @Published var recordingState: RecordingUIState = .idle
    @Published var lastError: String?

    let store: MeetingStoring
    let capturer: AudioCapturing
    let transcriber: Transcribing
    let summarizer: Summarizing
    let exporter: TranscriptExporting

    private var recordingSession: ActiveRecording?
    private var elapsedTimer: Timer?
    init(
        store: MeetingStoring? = nil,
        capturer: AudioCapturing? = nil,
        transcriber: Transcribing? = nil,
        summarizer: Summarizing? = nil,
        exporter: TranscriptExporting? = nil
    ) {
        var settings = AppSettings.load()
        settings.ai.apiKey = APIKeyStore.read()
        self.settings = settings
        self.store = store ?? FileMeetingStore(rootDirectory: settings.resolvedOutputDirectory)
        self.capturer = capturer ?? DualTrackAudioCapturer()
        self.transcriber = transcriber ?? FasterWhisperTranscriber()
        self.summarizer = summarizer ?? ProviderSummarizer()
        self.exporter = exporter ?? MultiFormatExporter()
        // Force-quit mid-picker can leave SCContentSharingPicker stuck.
        ContentSharingPickerCoordinator.shared.reset()

        let devices = DualTrackAudioCapturer.defaultEndpoints()
        RoomtoneLog.session("app launch")
        RoomtoneLog.write(
            "audio devices: input=\(devices.input?.summary ?? "none")"
            + " output=\(devices.output?.summary ?? "none")"
        )

        refreshMeetings()
    }

    var selectedMeeting: Meeting? {
        meetings.first { $0.id == selectedMeetingID }
    }

    func refreshMeetings() {
        do {
            meetings = try store.listMeetings().sorted { $0.date > $1.date }
            // Drop selection if that meeting was deleted; do not auto-jump to another.
            if let id = selectedMeetingID, !meetings.contains(where: { $0.id == id }) {
                selectedMeetingID = nil
            }
        } catch {
            lastError = CapturePermissions.userFacingMessage(for: error)
        }
    }

    func goHome() {
        selectedMeetingID = nil
    }

    func deleteMeeting(_ meeting: Meeting) {
        do {
            // Don't delete a meeting while it's actively recording/processing.
            if selectedMeetingID == meeting.id {
                switch recordingState {
                case .preparing, .recording, .paused, .processing:
                    lastError = "Stop the current recording before deleting this meeting."
                    return
                case .idle:
                    break
                }
            }
            try store.deleteMeeting(meeting)
            if selectedMeetingID == meeting.id {
                selectedMeetingID = nil
            }
            refreshMeetings()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func updateSettings(_ newSettings: AppSettings) {
        if newSettings.ai.apiKey != settings.ai.apiKey, !APIKeyStore.save(newSettings.ai.apiKey) {
            lastError = "Couldn't save the API key to the keychain."
        }
        settings = newSettings
        newSettings.save()
        applyAppearance()
        if let fileStore = store as? FileMeetingStore {
            fileStore.rootDirectory = newSettings.resolvedOutputDirectory
        }
        refreshMeetings()
    }

    func startRecording(title: String, microphoneID: String?) async {
        lastError = nil
        var created: Meeting?
        do {
            let meeting = try store.createMeeting(title: title.isEmpty ? "Meeting" : title)
            created = meeting
            selectedMeetingID = meeting.id
            recordingState = .preparing
            syncRecordingHUD()

            let session = try await capturer.start(
                configuration: CaptureConfiguration(
                    meetingDirectory: store.directory(for: meeting),
                    microphoneDeviceID: microphoneID,
                    sampleRate: settings.sampleRate
                )
            )
            recordingSession = session
            recordingState = .recording(elapsed: 0, micLevel: 0, systemLevel: 0)
            syncRecordingHUD()
            startElapsedTimer()
            refreshMeetings()
            // Timer ticks don't re-show HUD; ensure it's up after meeting list refresh.
            syncRecordingHUD()
        } catch is CancellationError {
            if let created {
                try? store.deleteMeeting(created)
            }
            selectedMeetingID = nil
            recordingState = .idle
            syncRecordingHUD()
            refreshMeetings()
        } catch let pickerError as ContentSharingPickerCoordinator.PickerError {
            if let created {
                try? store.deleteMeeting(created)
            }
            selectedMeetingID = nil
            recordingState = .idle
            syncRecordingHUD()
            refreshMeetings()
            if case .cancelled = pickerError {
                // User closed system picker — not an error alert.
            } else {
                lastError = pickerError.localizedDescription
            }
        } catch {
            if let created {
                try? store.deleteMeeting(created)
            }
            selectedMeetingID = nil
            recordingState = .idle
            syncRecordingHUD()
            refreshMeetings()
            lastError = CapturePermissions.userFacingMessage(for: error)
        }
    }

    func pauseRecording() {
        capturer.pause()
        if case .recording(let e, let m, let s) = recordingState {
            recordingState = .paused(elapsed: e, micLevel: m, systemLevel: s)
        }
        syncRecordingHUD()
        elapsedTimer?.invalidate()
    }

    func resumeRecording() {
        capturer.resume()
        if case .paused(let e, let m, let s) = recordingState {
            recordingState = .recording(elapsed: e, micLevel: m, systemLevel: s)
        }
        syncRecordingHUD()
        startElapsedTimer()
    }

    func stopRecording() async {
        // Only a live capture can be stopped, so repeat taps land here and
        // return. State is the guard: it cannot be left latched on.
        switch recordingState {
        case .recording, .paused:
            break
        case .idle, .preparing, .processing:
            return
        }
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        recordingState = .processing(stage: "Saving audio…")
        syncRecordingHUD()
        do {
            let result = try await capturer.stop()
            recordingState = .processing(stage: "Preparing transcript…")
            syncRecordingHUD()
            guard var meeting = selectedMeeting else { return }
            meeting.durationSeconds = result.durationSeconds
            meeting.status = .recorded
            meeting.audio = MeetingAudioFiles(
                system: "system.wav",
                microphone: "microphone.wav",
                combined: "combined.wav"
            )
            try store.save(meeting)
            recordingSession = nil
            refreshMeetings()

            await processMeeting(meetingID: meeting.id)
        } catch {
            recordingState = .idle
            syncRecordingHUD()
            lastError = CapturePermissions.userFacingMessage(for: error)
        }
    }

    /// HUD is AppKit-owned so SwiftUI view churn (refreshMeetings / detail swap) can't dismiss it.
    /// While recording/paused: show mini player, hide main window. Otherwise restore main.
    func syncRecordingHUD() {
        switch recordingState {
        case .recording, .paused:
            RecordingHUDPanelController.shared.setVisible(true, appModel: self)
            // Never hide main unless mini player is actually visible.
            if RecordingHUDPanelController.shared.isVisible {
                MainWindowHider.setMainWindowsVisible(false)
            } else {
                MainWindowHider.setMainWindowsVisible(true)
            }
        case .preparing:
            // Keep main visible during share picker.
            RecordingHUDPanelController.shared.setVisible(false, appModel: self)
            MainWindowHider.setMainWindowsVisible(true)
        case .idle, .processing:
            RecordingHUDPanelController.shared.setVisible(false, appModel: self)
            MainWindowHider.setMainWindowsVisible(true)
        }
    }

    func processMeeting(meetingID: Meeting.ID) async {
        guard var meeting = meetings.first(where: { $0.id == meetingID }) else { return }
        lastError = nil
        do {
            recordingState = .processing(stage: "Transcribing (first run may download the speech model)…")
            meeting.status = .transcribing
            try store.save(meeting)

            let transcript = try await transcriber.transcribe(
                meeting: meeting,
                options: TranscriptionOptions(
                    language: settings.transcriptionLanguage,
                    model: settings.transcriptionModel,
                    assignLocalMicAsYou: true
                )
            )
            try store.saveTranscript(transcript, for: meeting)
            meeting.status = .transcribed
            meeting.speakers = transcript.speakers
            try store.save(meeting)

            let formats = settings.exportFormats
            recordingState = .processing(stage: "Exporting…")
            try exporter.export(transcript: transcript, meeting: meeting, formats: formats)

            if settings.deleteRecordingsAfterTranscription, let audio = meeting.audio {
                let dir = store.directory(for: meeting)
                for name in [audio.system, audio.microphone, audio.combined] {
                    try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
                }
                meeting.audio = nil
                try store.save(meeting)
            }

            meeting.status = .ready
            if settings.ai.provider != .none {
                recordingState = .processing(stage: "Summarizing…")
                // Transcript is already saved; a failed summary must not mark the meeting failed.
                do {
                    let summary = try await summarizer.generateSummary(
                        transcript: transcript,
                        options: SummaryOptions(
                            provider: settings.ai.provider,
                            baseURL: settings.ai.baseURL,
                            model: settings.ai.model,
                            apiKey: settings.ai.apiKey
                        )
                    )
                    try store.saveSummary(summary, for: meeting)
                    meeting.status = .summarized
                    meeting.summaryProvider = settings.ai.provider.rawValue
                } catch {
                    lastError = "Summary failed: \(error.localizedDescription)"
                }
            }
            try store.save(meeting)
            recordingState = .idle
            syncRecordingHUD()
            refreshMeetings()
            selectedMeetingID = meetingID
        } catch {
            meeting.status = .failed
            try? store.save(meeting)
            recordingState = .idle
            syncRecordingHUD()
            lastError = CapturePermissions.userFacingMessage(for: error)
            refreshMeetings()
        }
    }

    func renameMeeting(meetingID: Meeting.ID, title: String) {
        do {
            try store.renameMeeting(meetingID: meetingID, title: title)
            refreshMeetings()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func renameSpeaker(meetingID: Meeting.ID, from old: String, to newName: String) {
        do {
            try store.renameSpeaker(meetingID: meetingID, from: old, to: newName)
            refreshMeetings()
        } catch {
            lastError = CapturePermissions.userFacingMessage(for: error)
        }
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let levels = self.capturer.currentLevels()
                switch self.recordingState {
                case .recording(let elapsed, _, _):
                    self.recordingState = .recording(
                        elapsed: elapsed + 0.1,
                        micLevel: levels.microphone,
                        systemLevel: levels.system
                    )
                default:
                    break
                }
            }
        }
    }
}

enum RecordingUIState: Equatable {
    case idle
    case preparing
    case recording(elapsed: TimeInterval, micLevel: Float, systemLevel: Float)
    case paused(elapsed: TimeInterval, micLevel: Float, systemLevel: Float)
    case processing(stage: String)
}
