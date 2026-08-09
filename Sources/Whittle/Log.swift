import Foundation
import os

/// Logs to both the unified system log and ~/Library/Logs/Whittle.log.
/// Never log secrets (API keys) or photo contents — statuses, timings,
/// model names, and error text only.
enum Log {
    private static let logger = Logger(subsystem: "com.surendran.whittle", category: "app")
    private static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Whittle.log")
    private static let queue = DispatchQueue(label: "whittle.log")

    static func info(_ message: String) { write("INFO", message) }
    static func error(_ message: String) { write("ERROR", message) }

    private static func write(_ level: String, _ message: String) {
        logger.log("\(level, privacy: .public): \(message, privacy: .public)")
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(level) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }
}
