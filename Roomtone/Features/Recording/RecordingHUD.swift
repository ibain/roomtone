import AppKit
import SwiftUI

/// Compact always-on-top HUD while recording — time, meters, stop.
struct RecordingHUDView: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Group {
            switch appModel.recordingState {
            case .recording(let elapsed, let mic, let system):
                hudContent(elapsed: elapsed, mic: mic, system: system, paused: false)
            case .paused(let elapsed, let mic, let system):
                hudContent(elapsed: elapsed, mic: mic, system: system, paused: true)
            default:
                Color.clear.frame(width: 260, height: 96)
            }
        }
        .padding(12)
        .frame(width: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.red, lineWidth: 4)
        }
        .padding(6)
    }

    @ViewBuilder
    private func hudContent(elapsed: TimeInterval, mic: Float, system: Float, paused: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(paused ? Color.orange : Color.red)
                    .frame(width: 8, height: 8)
                Text(Self.format(elapsed))
                    .font(.system(.title3, design: .monospaced).weight(.medium))
                Spacer(minLength: 8)
                if paused {
                    Button("Resume") { appModel.resumeRecording() }
                        .controlSize(.small)
                } else {
                    Button("Pause") { appModel.pauseRecording() }
                        .controlSize(.small)
                }
                // No `.destructive` role — can eat first click / confirm on panels.
                // Repeat taps are dropped by AppModel, not by view state: this
                // panel outlives a recording, so a latch here stays stuck.
                Button("Stop") {
                    Task { await appModel.stopRecording() }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }

            compactMeter(title: "Mic", level: mic)
            compactMeter(title: "System", level: system)
        }
    }

    private func compactMeter(title: String, level: Float) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.2))
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: max(3, geo.size.width * CGFloat(min(max(level, 0), 1))))
                }
            }
            .frame(height: 6)
        }
    }

    private static func format(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

/// Optional SwiftUI hook — prefers AppModel.syncRecordingHUD, but keeps old call sites compiling.
struct RecordingHUDController: View {
    @EnvironmentObject private var appModel: AppModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onChange(of: hudShouldShow) { _, show in
                DispatchQueue.main.async {
                    RecordingHUDPanelController.shared.setVisible(show, appModel: appModel)
                }
            }
            .onAppear {
                RecordingHUDPanelController.shared.setVisible(hudShouldShow, appModel: appModel)
            }
    }

    private var hudShouldShow: Bool {
        switch appModel.recordingState {
        case .recording, .paused:
            return true
        case .idle, .preparing, .processing:
            return false
        }
    }
}

enum MainWindowHider {
    private static let hudID = NSUserInterfaceItemIdentifier("roomtone.recording-hud")

    @MainActor
    static func setMainWindowsVisible(_ visible: Bool) {
        for window in NSApp.windows {
            if window.identifier == hudID { continue }
            if let panel = window as? NSPanel, panel.isFloatingPanel { continue }
            if visible {
                window.orderFront(nil)
            } else {
                window.orderOut(nil)
            }
        }
        if visible {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    static var recordingHUDIdentifier: NSUserInterfaceItemIdentifier { hudID }
}

/// Floating HUD: nonactivating (stays above) but canBecomeKey so Stop works on first click.
private final class RecordingHUDPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// AppKit panel — stays on top, draggable, excluded from screen capture.
@MainActor
final class RecordingHUDPanelController {
    static let shared = RecordingHUDPanelController()

    private var panel: RecordingHUDPanel?
    private var hostingView: NSHostingView<AnyView>?

    var isVisible: Bool { panel?.isVisible == true }

    func setVisible(_ visible: Bool, appModel: AppModel) {
        if visible {
            show(appModel: appModel)
        } else {
            hide()
        }
    }

    private func show(appModel: AppModel) {
        let size = NSSize(width: 296, height: 118)
        let root = AnyView(RecordingHUDView().environmentObject(appModel))

        if let hostingView {
            hostingView.rootView = root
        } else {
            let hosting = NSHostingView(rootView: root)
            hosting.frame = NSRect(origin: .zero, size: size)

            let panel = RecordingHUDPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.identifier = MainWindowHider.recordingHUDIdentifier
            panel.isFloatingPanel = true
            panel.becomesKeyOnlyIfNeeded = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.title = "Roomtone"
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.sharingType = .none
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.contentView = hosting

            self.panel = panel
            self.hostingView = hosting
        }

        positionOnActiveScreen(size: size)
        // After system share picker, app often isn't key — orderFrontRegardless is required.
        NSApp.activate(ignoringOtherApps: true)
        panel?.orderFrontRegardless()
    }

    private func positionOnActiveScreen(size: NSSize) {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSApp.keyWindow?.screen
            ?? NSScreen.main
        guard let screen else { return }
        let visible = screen.visibleFrame
        panel.setFrame(
            NSRect(
                x: visible.maxX - size.width - 24,
                y: visible.maxY - size.height - 24,
                width: size.width,
                height: size.height
            ),
            display: true
        )
    }

    private func hide() {
        panel?.orderOut(nil)
    }
}
