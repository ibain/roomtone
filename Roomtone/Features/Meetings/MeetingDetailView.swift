import SwiftUI
import AppKit

struct MeetingDetailView: View {
    @EnvironmentObject private var appModel: AppModel
    let meeting: Meeting
    @Binding var searchText: String
    @State private var transcript: Transcript?
    @State private var summary: MeetingSummary?
    @State private var confirmDelete = false
    @State private var confirmReprocess = false
    @FocusState private var focusedSpeaker: String?
    @State private var didCopyTranscript = false
    @State private var isEditingTitle = false
    @State private var titleDraft = ""
    /// Draft name per current speaker label (keyed by original speaker id in list).
    @State private var speakerDrafts: [String: String] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        if isEditingTitle {
                            TextField("Meeting title", text: $titleDraft)
                                .font(.title.weight(.semibold))
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 480)
                                .onSubmit { commitTitleRename() }
                        } else {
                            HStack(spacing: 8) {
                                Text(meeting.title)
                                    .font(.title.weight(.semibold))
                                    .onTapGesture(count: 2) { beginTitleEdit() }
                                Button {
                                    beginTitleEdit()
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.borderless)
                                .help("Rename meeting")
                            }
                        }
                        Text(meeting.date.formatted(date: .complete, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button("Reprocess…") { confirmReprocess = true }
                            .disabled(!canReprocess)
                        Divider()
                        Button("Delete Meeting…", role: .destructive) { confirmDelete = true }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                            .labelStyle(.iconOnly)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More actions")
                }

                if case .processing(let stage) = appModel.recordingState {
                    ProcessingBanner(stage: stage)
                }

                if let summary {
                    GroupBox("Meeting Summary") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(summary.overview)
                            if !summary.actionItems.isEmpty {
                                Text("Action Items").font(.headline)
                                ForEach(summary.actionItems, id: \.self) { Text("• \($0)") }
                            }
                            if !summary.keyDecisions.isEmpty {
                                Text("Key Decisions").font(.headline)
                                ForEach(summary.keyDecisions, id: \.self) { Text("• \($0)") }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                GroupBox("Speakers") {
                    VStack(alignment: .leading, spacing: 8) {
                        if meeting.speakers.isEmpty {
                            Text("No speakers yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            // Commits on Return or when focus leaves the field.
                            ForEach(meeting.speakers, id: \.self) { speaker in
                                TextField(
                                    "Speaker name",
                                    text: Binding(
                                        get: { speakerDrafts[speaker] ?? speaker },
                                        set: { speakerDrafts[speaker] = $0 }
                                    )
                                )
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedSpeaker, equals: speaker)
                                .onSubmit { commitSpeakerRename(from: speaker) }
                            }
                            Text("Edit a name and press Return to rename.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                GroupBox {
                    if let transcript {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            ForEach(filteredBlocks(transcript)) { block in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(block.speaker)
                                            .font(.caption.weight(.semibold))
                                        Text(Self.shortTs(block.start))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(block.text)
                                }
                                .id(block.id)
                            }
                        }
                    } else {
                        Text("No transcript yet.")
                            .foregroundStyle(.secondary)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("Transcript")
                        Spacer(minLength: 8)
                        Button {
                            copyFullTranscript()
                        } label: {
                            Label(
                                didCopyTranscript ? "Copied" : "Copy",
                                systemImage: didCopyTranscript ? "checkmark" : "doc.on.doc"
                            )
                        }
                        .buttonStyle(.borderless)
                        .disabled(transcript == nil || transcript?.blocks.isEmpty == true)
                        .help("Copy full transcript for pasting into another AI tool")
                    }
                }
            }
            .padding(24)
        }
        .onAppear {
            reload()
            syncSpeakerDrafts()
            titleDraft = meeting.title
        }
        .onChange(of: meeting.id) { _, _ in
            reload()
            syncSpeakerDrafts()
            titleDraft = meeting.title
            isEditingTitle = false
        }
        .onChange(of: meeting.status) { _, _ in
            // Reprocess updates files in place — same meeting id, must reload.
            reload()
            syncSpeakerDrafts()
        }
        .onChange(of: meeting.speakers) { _, _ in
            reload()
            syncSpeakerDrafts()
        }
        .onChange(of: meeting.title) { _, newTitle in
            if !isEditingTitle {
                titleDraft = newTitle
            }
        }
        .onChange(of: focusedSpeaker) { old, new in
            if let old, old != new, canRenameSpeaker(from: old) {
                commitSpeakerRename(from: old)
            }
        }
        .onChange(of: appModel.recordingState) { _, state in
            if case .idle = state {
                reload()
                syncSpeakerDrafts()
            }
        }
        .confirmationDialog("Delete this meeting?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                appModel.deleteMeeting(meeting)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("“\(meeting.title)” and all of its audio, transcript, and summary files will be permanently removed.")
        }
        .confirmationDialog("Reprocess this meeting?", isPresented: $confirmReprocess, titleVisibility: .visible) {
            Button("Reprocess") {
                Task { await appModel.processMeeting(meetingID: meeting.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The transcript is regenerated from the saved audio. Speaker names you changed will be reset.")
        }
    }

    /// Needs the WAVs (gone if “Delete recordings after transcription” is on) and no active job.
    private var canReprocess: Bool {
        meeting.audio != nil && appModel.recordingState == .idle
    }

    private func beginTitleEdit() {
        titleDraft = meeting.title
        isEditingTitle = true
    }

    private func commitTitleRename() {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isEditingTitle = false
        guard !trimmed.isEmpty, trimmed != meeting.title else {
            titleDraft = meeting.title
            return
        }
        appModel.renameMeeting(meetingID: meeting.id, title: trimmed)
    }

    private func syncSpeakerDrafts() {
        var next: [String: String] = [:]
        for speaker in meeting.speakers {
            next[speaker] = speakerDrafts[speaker] ?? speaker
        }
        speakerDrafts = next
    }

    private func canRenameSpeaker(from speaker: String) -> Bool {
        let newName = (speakerDrafts[speaker] ?? speaker)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !newName.isEmpty && newName != speaker
    }

    private func commitSpeakerRename(from speaker: String) {
        let newName = (speakerDrafts[speaker] ?? speaker)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != speaker else { return }
        appModel.renameSpeaker(meetingID: meeting.id, from: speaker, to: newName)
        speakerDrafts[speaker] = nil
        speakerDrafts[newName] = newName
        reload()
    }

    private func reload() {
        transcript = try? appModel.store.loadTranscript(for: meeting)
        summary = try? appModel.store.loadSummary(for: meeting)
    }

    private func filteredBlocks(_ transcript: Transcript) -> [TranscriptBlock] {
        guard !searchText.isEmpty else { return transcript.blocks }
        return transcript.blocks.filter {
            $0.text.localizedCaseInsensitiveContains(searchText)
                || $0.speaker.localizedCaseInsensitiveContains(searchText)
        }
    }

    /// Full transcript (ignores search filter) — paste-friendly for external AI summary.
    private func copyFullTranscript() {
        guard let transcript, !transcript.blocks.isEmpty else { return }
        let lines = transcript.blocks.map { block in
            "\(block.speaker) [\(Self.ts(block.start)) – \(Self.ts(block.end))]\n\(block.text)"
        }
        let header = "\(meeting.title)\n\(meeting.date.formatted(date: .complete, time: .shortened))\n"
        let payload = header + "\n" + lines.joined(separator: "\n\n")
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(payload, forType: .string)
        didCopyTranscript = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopyTranscript = false
        }
    }

    /// m:ss under an hour, h:mm:ss after.
    private static func shortTs(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    private static func ts(_ t: TimeInterval) -> String {
        let total = Int(t.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}
