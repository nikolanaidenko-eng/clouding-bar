import AppKit

/// Files dragged onto the widget (the pill, the panel or the island). They
/// wait there for the session it shows and go to its chat with the next
/// message written in the widget, or by themselves with Insert.
enum FileDrop {
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff]

    static func canRead(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    /// The dropped files. A picture with no file behind it (dragged out of
    /// a browser, say) is saved to ~/.cloudingbar/shots first.
    static func read(_ pasteboard: NSPasteboard) -> [URL] {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls
        }
        let png = pasteboard.data(forType: .png)
            ?? pasteboard.data(forType: .tiff).flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        guard let png else { return [] }
        let dir = Config.directory.appendingPathComponent("shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = dir.appendingPathComponent("drop-\(stamp).png")
        guard (try? png.write(to: url)) != nil else { return [] }
        return [url]
    }

    /// How a path is written for Claude: as is, in quotes if it has spaces.
    static func quoted(_ path: String) -> String {
        path.contains(where: \.isWhitespace) ? "\"\(path)\"" : path
    }

    /// The SF Symbol for a file: a picture, a folder or a document.
    static func symbol(_ path: String) -> String {
        var dir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &dir), dir.boolValue { return "folder" }
        let ext = (path as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp", "svg"].contains(ext) ? "photo" : "doc"
    }
}
