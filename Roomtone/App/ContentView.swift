import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var searchText = ""
    @State private var meetingPendingDelete: Meeting?

    var body: some View {
        NavigationSplitView {
            List(selection: $appModel.selectedMeetingID) {
                Section("Meetings") {
                    ForEach(filteredMeetings) { meeting in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meeting.title)
                                    .font(.headline)
                                Text(meeting.date.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(meeting.status.rawValue)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 8)
                            Button {
                                meetingPendingDelete = meeting
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Delete meeting")
                        }
                        .contentShape(Rectangle())
                        .tag(Optional(meeting.id))
                        .contextMenu {
                            Button("Delete Meeting", role: .destructive) {
                                meetingPendingDelete = meeting
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            VStack(spacing: 0) {
                ConsentBanner()
                Divider()
                if showsRecordingSetup {
                    RecordingView()
                } else if let meeting = appModel.selectedMeeting {
                    // Processing + ready meetings use detail (banner while ASR runs).
                    MeetingDetailView(meeting: meeting, searchText: $searchText)
                } else {
                    RecordingView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        appModel.goHome()
                    } label: {
                        Label("Home", systemImage: "house.fill")
                    }
                    .help("Back to new recording")
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search transcript")
        .alert(
            Text(alertTitle),
            isPresented: Binding(
                get: { appModel.lastError != nil },
                set: { if !$0 { appModel.lastError = nil } }
            )
        ) {
            if showsPermissionSettingsButton {
                Button("Open System Settings") {
                    let message = appModel.lastError?.lowercased() ?? ""
                    if message.contains("microphone") {
                        CapturePermissions.openMicrophoneSettings()
                    } else {
                        CapturePermissions.openScreenCaptureSettings()
                    }
                }
            }
            Button("OK", role: .cancel) { appModel.lastError = nil }
        } message: {
            Text(appModel.lastError ?? "")
        }
        .confirmationDialog(
            "Delete this meeting?",
            isPresented: Binding(
                get: { meetingPendingDelete != nil },
                set: { if !$0 { meetingPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let meeting = meetingPendingDelete {
                    appModel.deleteMeeting(meeting)
                }
                meetingPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                meetingPendingDelete = nil
            }
        } message: {
            if let meeting = meetingPendingDelete {
                Text("“\(meeting.title)” and all of its audio, transcript, and summary files will be permanently removed.")
            }
        }
    }

    private var alertTitle: String {
        showsPermissionSettingsButton ? "Permission needed" : "Something went wrong"
    }

    private var showsPermissionSettingsButton: Bool {
        let message = appModel.lastError?.lowercased() ?? ""
        return message.contains("permission")
            || message.contains("microphone")
            || message.contains("screen & system audio")
    }

    /// Live capture only — processing belongs on the meeting detail screen.
    private var showsRecordingSetup: Bool {
        switch appModel.recordingState {
        case .preparing, .recording, .paused:
            return true
        case .idle, .processing:
            return false
        }
    }

    private var filteredMeetings: [Meeting] {
        guard !searchText.isEmpty else { return appModel.meetings }
        return appModel.meetings.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
        }
    }
}

struct ConsentBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
            Text("Recording on? Get consent from all participants (required in CA and other all-party consent regions). Audio stays local unless you opt into cloud AI.")
                .font(.callout)
            Spacer()
        }
        .padding(10)
        .background(Color.orange.opacity(0.15))
    }
}
