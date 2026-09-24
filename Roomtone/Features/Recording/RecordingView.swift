import AppKit
import SwiftUI

struct RecordingView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var title = ""
    @State private var microphones: [AudioSourceOption] = []
    @State private var selectedMicID: String?
    @State private var didLoadSources = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Roomtone")
                    .font(.largeTitle.weight(.semibold))
                Text("Local meeting recorder — dual-track, privacy-first.")
                    .foregroundStyle(.secondary)

                GroupBox("New recording") {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Meeting title", text: $title)

                        Picker("Microphone", selection: $selectedMicID) {
                            Text("Select…").tag(String?.none)
                            ForEach(microphones) { mic in
                                Text(mic.name).tag(Optional(mic.id))
                            }
                        }

                        Text("macOS asks what to share — pick a window or entire screen. Laptop screen is fine even if Zoom is on another monitor; Roomtone still captures system audio broadly.")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        LabeledContent("Output folder") {
                            Text(appModel.settings.outputDirectoryPath)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        recordingControls
                    }
                    .padding(4)
                }

                if case .processing(let stage) = appModel.recordingState {
                    ProcessingBanner(stage: stage)
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .task { await loadSources() }
    }

    @ViewBuilder
    private var recordingControls: some View {
        switch appModel.recordingState {
        case .idle, .preparing:
            Button {
                Task {
                    await appModel.startRecording(
                        title: title,
                        microphoneID: selectedMicID
                    )
                }
            } label: {
                Label(
                    appModel.recordingState == .preparing ? "Choose meeting audio…" : "Start Recording",
                    systemImage: "record.circle"
                )
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(selectedMicID == nil || appModel.recordingState == .preparing)

        case .recording(let elapsed, let mic, let system), .paused(let elapsed, let mic, let system):
            VStack(alignment: .leading, spacing: 10) {
                Text(Self.format(elapsed))
                    .font(.system(.title, design: .monospaced))
                LevelMeter(title: "Microphone", level: mic)
                LevelMeter(title: "System", level: system)
                HStack {
                    if case .paused = appModel.recordingState {
                        Button("Resume") { appModel.resumeRecording() }
                    } else {
                        Button("Pause") { appModel.pauseRecording() }
                    }
                    Button("Stop", role: .destructive) {
                        Task { await appModel.stopRecording() }
                    }
                }
            }

        case .processing:
            EmptyView()
        }
    }

    private func loadSources() async {
        if didLoadSources { return }
        microphones = appModel.capturer.availableMicrophones()
        selectedMicID = microphones.first(where: { $0.id == "default" })?.id ?? microphones.first?.id
        didLoadSources = true
    }

    private static func format(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

struct LevelMeter: View {
    let title: String
    let level: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(4, geo.size.width * CGFloat(min(max(level, 0), 1))))
                }
            }
            .frame(height: 8)
        }
    }
}
