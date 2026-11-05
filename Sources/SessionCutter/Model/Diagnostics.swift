import AppKit
import Foundation

/// A plain text log of what recording and playback actually did, in
/// `~/Movies/Session Cutter/session-cutter.log`. Short lines, newest last —
/// the file to send along when something does not work.
enum Diagnostics {
    static var fileURL: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Movies")
        return movies.appendingPathComponent("Session Cutter/session-cutter.log")
    }

    private static let queue = DispatchQueue(label: "SessionCutter.log")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func log(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        queue.async {
            let url = fileURL
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    /// The error and everything underneath it, which is where AVFoundation
    /// keeps the useful part.
    static func describe(_ error: Error?) -> String {
        guard let error else { return "kein Fehlerobjekt" }
        var parts: [String] = []
        var current: NSError? = error as NSError
        while let next = current {
            parts.append("\(next.domain) \(next.code): \(next.localizedDescription)")
            current = next.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: " ← ")
    }

    @MainActor
    static func reveal() {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        } else {
            NSWorkspace.shared.open(fileURL.deletingLastPathComponent())
        }
    }
}
