import AppKit

/// Terminal and iTerm2 tabs, by their tty (owner's request, 20.10): which
/// one is in front, and bringing the one a chat runs in forward. Asked by
/// AppleScript, off the main queue; macOS asks once to let Clouding Bar
/// control the terminal.
enum Terminals {
    static let terminal = "com.apple.Terminal"
    static let iterm = "com.googlecode.iterm2"

    static func supports(_ bundleID: String?) -> Bool { bundleID == terminal || bundleID == iterm }

    private static let queue = DispatchQueue(label: "cloudingbar.terminals", qos: .userInitiated)
    private static var busy = false

    /// The tty of the tab in front of that terminal; on the main queue.
    static func frontTTY(_ bundleID: String, completion: @escaping (String?) -> Void) {
        guard !busy else { return }
        busy = true
        let script = bundleID == iterm
            ? #"tell application id "com.googlecode.iterm2" to if (count of windows) > 0 then return tty of current session of current window"#
            : #"tell application id "com.apple.Terminal" to if (count of windows) > 0 then return tty of selected tab of front window"#
        queue.async {
            let tty = run(script)
            DispatchQueue.main.async {
                busy = false
                completion(tty.flatMap { $0.hasPrefix("/dev/") ? $0 : nil })
            }
        }
    }

    /// Brings the tab on `tty` forward in whichever terminal runs it;
    /// `completion` (main queue) says whether one was found.
    static func focus(tty: String, completion: @escaping (Bool) -> Void) {
        let running = [terminal, iterm].filter { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        guard !running.isEmpty else { completion(false); return }
        let safe = tty.replacingOccurrences(of: "\"", with: "")
        queue.async {
            var found = false
            for app in running where !found {
                let script = app == iterm ? """
                    tell application id "com.googlecode.iterm2"
                      repeat with w in windows
                        repeat with t in tabs of w
                          repeat with s in sessions of t
                            if tty of s is "\(safe)" then
                              select w
                              tell t to select
                              tell s to select
                              activate
                              return "yes"
                            end if
                          end repeat
                        end repeat
                      end repeat
                    end tell
                    """ : """
                    tell application id "com.apple.Terminal"
                      repeat with w in windows
                        repeat with t in tabs of w
                          if tty of t is "\(safe)" then
                            set selected of t to true
                            set index of w to 1
                            activate
                            return "yes"
                          end if
                        end repeat
                      end repeat
                    end tell
                    """
                found = run(script) == "yes"
            }
            DispatchQueue.main.async { completion(found) }
        }
    }

    /// osascript's answer, or nil (an error, no permission, 2 s gone).
    private static func run(_ script: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(2)
        while p.isRunning && Date() < deadline { usleep(10_000) }
        if p.isRunning { p.terminate(); return nil }
        guard p.terminationStatus == 0 else { return nil }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}
