import AppKit
import ApplicationServices

/// Appends to ~/.claudebar/debug.log: one line per tap on the bar, so a
/// button that "does nothing" can be told apart (no line = the tap never
/// reached us; trusted=false = macOS is blocking the keystrokes), plus what
/// happened to each permission or question.
enum DebugLog {
    /// Also written once at launch ("launch trusted=…"), so a rebuild that
    /// lost the Accessibility permission shows up without pressing anything.
    static func tap(_ action: String) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        append("\(Date()) \(action) trusted=\(AXIsProcessTrusted()) front=\(front)\n")
    }

    static func note(_ text: String) {
        append("\(Date()) note: \(text)\n")
    }

    private static func append(_ line: String) {
        let url = Config.directory.appendingPathComponent("debug.log")
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
