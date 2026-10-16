import AppKit

/// Pick an area of the screen with the system's screenshot tool; the file
/// lands in ~/.claudebar/shots and its path is handed back. The first time,
/// macOS asks to allow Screen Recording for Clouding Bar.
enum Screenshot {
    static func take(_ done: @escaping (String?) -> Void) {
        let dir = Config.directory.appendingPathComponent("shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let path = dir.appendingPathComponent("shot-\(stamp).png").path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", path] // interactive area, no sound
        process.terminationHandler = { _ in
            let ok = FileManager.default.fileExists(atPath: path) // Esc leaves no file
            DispatchQueue.main.async { done(ok ? path : nil) }
        }
        do { try process.run() } catch { done(nil) }
    }
}
