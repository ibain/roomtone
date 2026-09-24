import Foundation

/// Appends to `~/Library/Logs/Roomtone/roomtone.log` as well as stdout.
///
/// Recording failures are reported by users hours later, and `print` only
/// survives while Xcode is attached, so a capture that fails in the wild leaves
/// nothing behind to read.
enum RoomtoneLog {
    private static let queue = DispatchQueue(label: "com.ibain.roomtone.log")
    private static let maxBytes = 2 * 1024 * 1024

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Roomtone", isDirectory: true)
            .appendingPathComponent("roomtone.log")
    }

    static func write(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)"
        print(line)
        queue.async { append(line + "\n") }
    }

    /// Marks a run boundary so a user can find "the recording I just tried".
    static func session(_ message: String) {
        write("────── \(message)")
    }

    private static func append(_ text: String) {
        let url = fileURL
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            rotateIfNeeded(url)
            guard let data = text.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } else {
                try data.write(to: url)
            }
        } catch {
            // Logging must never break a recording.
        }
    }

    private static func rotateIfNeeded(_ url: URL) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values?.fileSize, size > maxBytes else { return }
        let previous = url.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: url, to: previous)
    }
}
