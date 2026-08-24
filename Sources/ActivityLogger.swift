import AppKit
import Foundation

final class ActivityLogger {
    static let shared = ActivityLogger()

    private let queue = DispatchQueue(label: "com.zhangjing.RStudioHub.ActivityLogger")
    private let logDirectory: URL
    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()
    private let fileDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private let maxLogBytes: UInt64 = 2 * 1024 * 1024

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        logDirectory = base.appendingPathComponent("RStudioHub/logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        rotateIfNeeded()
    }

    var currentLogURL: URL {
        logDirectory.appendingPathComponent("\(fileDateFormatter.string(from: Date())).log")
    }

    func log(_ message: String) {
        queue.async {
            self.write(message)
        }
    }

    func logSync(_ message: String) {
        write(message)
    }

    func revealInFinder() {
        let url = currentLogURL
        if !FileManager.default.fileExists(atPath: url.path) {
            logSync("log file created")
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func write(_ message: String) {
        rotateIfNeeded()
        let line = "[\(timestampFormatter.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let url = currentLogURL
        if FileManager.default.fileExists(atPath: url.path) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            }
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func rotateIfNeeded() {
        let url = currentLogURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64,
              size > maxLogBytes else {
            return
        }

        let backup = logDirectory.appendingPathComponent("\(fileDateFormatter.string(from: Date()))-old.log")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.moveItem(at: url, to: backup)
    }
}
