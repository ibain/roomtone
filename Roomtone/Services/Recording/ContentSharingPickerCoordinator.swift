import Foundation
import ScreenCaptureKit

/// Presents Apple's system content picker so we don't "bypass" it (Sequoia scary monthly dialog).
/// Window or full-screen display both grant capture; capturer then records system audio broadly.
@MainActor
final class ContentSharingPickerCoordinator: NSObject, SCContentSharingPickerObserver {
    static let shared = ContentSharingPickerCoordinator()

    private var continuation: CheckedContinuation<SCContentFilter, Error>?
    private var isPresenting = false
    /// Keep picker active while SCStream runs — some macOS builds tie filter audio rights to session.
    private var sessionActive = false

    enum PickerError: LocalizedError {
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                return "Meeting audio selection was cancelled."
            case .failed(let message):
                return message
            }
        }
    }

    /// Clear stuck picker state after force-quit / failed launch.
    func reset() {
        continuation = nil
        isPresenting = false
        sessionActive = false
        let picker = SCContentSharingPicker.shared
        picker.isActive = false
        picker.remove(self)
    }

    func pickFilter() async throws -> SCContentFilter {
        if isPresenting || continuation != nil {
            reset()
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.isPresenting = true

            let picker = SCContentSharingPicker.shared
            var config = SCContentSharingPickerConfiguration()
            // Window + full display. Avoid present(using: .display) — blue wash / no Share button.
            // Plain present() shows the normal picker chrome with both modes.
            config.allowedPickerModes = [.singleDisplay, .singleWindow]
            picker.defaultConfiguration = config
            picker.configuration = config
            picker.maximumStreamCount = 1
            picker.add(self)
            picker.isActive = true
            picker.present()
        }
    }

    /// Call when recording stops / aborts so Control Center picker session ends.
    func endSession() {
        let pending = continuation
        continuation = nil
        isPresenting = false
        sessionActive = false
        let picker = SCContentSharingPicker.shared
        picker.isActive = false
        picker.remove(self)
        pending?.resume(throwing: PickerError.cancelled)
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        Task { @MainActor in
            self.finish(picker: picker, result: .success(filter), keepSession: true)
        }
    }

    nonisolated func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        Task { @MainActor in
            self.finish(picker: picker, result: .failure(PickerError.cancelled), keepSession: false)
        }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor in
            let picker = SCContentSharingPicker.shared
            self.finish(
                picker: picker,
                result: .failure(PickerError.failed(error.localizedDescription)),
                keepSession: false
            )
        }
    }

    private func finish(
        picker: SCContentSharingPicker,
        result: Result<SCContentFilter, Error>,
        keepSession: Bool
    ) {
        // Idempotent — Apple may call cancel/update more than once.
        guard let continuation else {
            if !keepSession {
                picker.isActive = false
            }
            return
        }
        self.continuation = nil
        isPresenting = false
        if keepSession {
            sessionActive = true
        } else {
            sessionActive = false
            picker.isActive = false
            picker.remove(self)
        }
        continuation.resume(with: result)
    }
}
