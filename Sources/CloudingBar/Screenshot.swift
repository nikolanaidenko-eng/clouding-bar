import AppKit

/// Pick an area of the screen with the system's screenshot tool; the file
/// lands in ~/.cloudingbar/shots and its path is handed back. The first time,
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

    /// The picture itself pasted into the app in front: Claude Desktop's
    /// Design, Cowork and chats can't open a path typed there (owner, 29.10).
    /// What the clipboard held comes back a moment later, unless you've
    /// copied something since.
    static func paste(_ path: String) {
        guard let data = FileManager.default.contents(atPath: path) else { NSSound.beep(); return }
        let board = NSPasteboard.general
        // A password (marked concealed, as 1Password does) isn't put back:
        // its own clearing would no longer reach it (review, 29.10).
        let concealed = board.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")) == true
        let saved = concealed ? [] : board.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        board.clearContents()
        board.setData(data, forType: .png)
        if let tiff = NSImage(data: data)?.tiffRepresentation { board.setData(tiff, forType: .tiff) }
        // Clipboard managers keep it out of their history.
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let ours = board.changeCount
        KeySender.press("cmd+v")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard board.changeCount == ours else { return }
            board.clearContents()
            let items = saved.map { pairs -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in pairs { item.setData(data, forType: type) }
                return item
            }
            if !items.isEmpty { board.writeObjects(items) }
        }
    }
}
