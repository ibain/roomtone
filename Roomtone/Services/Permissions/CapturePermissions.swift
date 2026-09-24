import AppKit
import AVFoundation
import CoreGraphics
import Foundation

enum CapturePermissions {
    /// Only prompt once per process — repeat CGRequestScreenCaptureAccess() churns ViewBridge / Settings remotes.
    private static var didRequestScreenCaptureThisSession = false

    /// Ask macOS to list Roomtone under Screen & System Audio Recording.
    @discardableResult
    static func requestScreenCaptureAccess() -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }
        guard !didRequestScreenCaptureThisSession else {
            return false
        }
        didRequestScreenCaptureThisSession = true
        return CGRequestScreenCaptureAccess()
    }

    static var hasScreenCaptureAccess: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    static func ensureReadyForRecording() async throws {
        _ = requestScreenCaptureAccess()
        let micOK = await requestMicrophoneAccess()
        if !micOK {
            throw PermissionError.microphoneDenied
        }
        if !hasScreenCaptureAccess {
            throw PermissionError.screenCaptureDenied
        }
    }

    static func openScreenCaptureSettings() {
        // Prefer modern System Settings deep link (single open — avoids double ViewBridge sessions).
        openPrivacyPane(legacy: "Privacy_ScreenCapture", modern: "Privacy_ScreenCapture")
    }

    static func openMicrophoneSettings() {
        openPrivacyPane(legacy: "Privacy_Microphone", modern: "Privacy_Microphone")
    }

    private static func openPrivacyPane(legacy: String, modern: String) {
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(modern)",
            "x-apple.systempreferences:com.apple.preference.security?\(legacy)"
        ]
        for value in urls {
            if let url = URL(string: value) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    /// Map system / TCC errors into plain language for the UI.
    static func userFacingMessage(for error: Error) -> String {
        if let permission = error as? PermissionError {
            return permission.fullMessage
        }
        // Our own errors are already plain language, and the keyword matching
        // below would otherwise rewrite them into a permission complaint.
        if let capture = error as? DualTrackAudioCapturer.CaptureError {
            return capture.errorDescription ?? error.localizedDescription
        }

        let ns = error as NSError
        let blob = "\(ns.domain) \(ns.code) \(ns.localizedDescription)".lowercased()
        // ViewBridge cancellations are system UI disconnects (Settings panes) — not Roomtone failures.
        if ns.domain == "com.apple.ViewBridge" || blob.contains("viewbridge") {
            return "A system settings panel closed. If recording still fails, check Screen & System Audio Recording permission for Roomtone."
        }
        if blob.contains("tcc")
            || (blob.contains("screen") && blob.contains("declin"))
            || blob.contains("screencapturekit")
            || ns.domain.contains("ScreenCaptureKit")
            || ns.code == -3801 {
            return PermissionError.screenCaptureDenied.fullMessage
        }
        if blob.contains("microphone") || blob.contains("audio input") {
            return PermissionError.microphoneDenied.fullMessage
        }
        return error.localizedDescription
    }

    enum PermissionError: LocalizedError {
        case screenCaptureDenied
        case microphoneDenied

        var errorDescription: String? { title }
        var failureReason: String? { detail }
        var recoverySuggestion: String? { steps }

        var title: String {
            switch self {
            case .screenCaptureDenied:
                return "Roomtone needs permission to record meeting audio"
            case .microphoneDenied:
                return "Roomtone needs microphone access"
            }
        }

        var detail: String {
            switch self {
            case .screenCaptureDenied:
                return "macOS requires Screen & System Audio Recording so Roomtone can capture meeting audio through the system share picker. Roomtone records audio only — not video. Prefer Allow when macOS asks, or enable Roomtone in System Settings."
            case .microphoneDenied:
                return "Roomtone records your microphone on a separate track so your voice can be labeled in the transcript."
            }
        }

        var steps: String {
            switch self {
            case .screenCaptureDenied:
                return """
                1. Open System Settings
                2. Go to Privacy & Security → Screen & System Audio Recording
                3. Turn on Roomtone
                4. Quit Roomtone completely, then open it again
                """
            case .microphoneDenied:
                return """
                1. Open System Settings
                2. Go to Privacy & Security → Microphone
                3. Turn on Roomtone
                4. Try recording again
                """
            }
        }

        var fullMessage: String {
            "\(title)\n\n\(detail)\n\n\(steps)"
        }
    }
}
