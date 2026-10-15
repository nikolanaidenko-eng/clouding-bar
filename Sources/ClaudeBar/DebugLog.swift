import AppKit
import ApplicationServices

/// Appends one line per button tap to ~/.claudebar/debug.log, so a button
/// that "does nothing" can be told apart: no line = the tap never reached
/// us; trusted=false = macOS is blocking the keystrokes.
enum DebugLog {
    /// Also written once at launch ("launch trusted=…"), so a rebuild that
    /// lost the Accessibility permission shows up without pressing anything.
    static func tap(_ action: String) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        let line = "\(Date()) \(action) trusted=\(AXIsProcessTrusted()) front=\(front)\n"
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
