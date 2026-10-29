import AppKit

/// A copy opened straight from its disk image (AppPlace) offers to move
/// itself to Applications: copies itself there, opens that copy once this
/// one has quit and ejects the image. A copy already in Applications that
/// isn't older is opened instead; an older one is replaced.
enum MoveToApplications {
    private static var here: URL { Bundle.main.bundleURL }

    static var needed: Bool {
        let readOnly = (try? here.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return AppPlace.needsMove(path: here.path, readOnlyVolume: readOnly)
    }

    /// Asks, and on yes moves and quits. On no, or when moving fails, this
    /// copy carries on.
    static func offer() {
        let folder = applicationsFolder()
        let target = folder.appendingPathComponent(here.lastPathComponent)
        let installed = version(at: target)
        let replace = AppPlace.replaces(installed: installed, with: Updater.version)
        DebugLog.note("move to Applications: running from \(here.path), \(installed.map { "\($0) in \(folder.path)" } ?? "none in \(folder.path)")")

        let alert = NSAlert()
        if replace {
            alert.messageText = "Move Clouding Bar to Applications?"
            alert.informativeText = "It's running from the disk image: from there it can't update itself, and it's gone once the disk image is ejected. It copies itself to \(folder.path), opens from there and ejects the disk image."
                + (installed.map { " The older copy there (\($0)) is replaced." } ?? "")
            alert.addButton(withTitle: "Move to Applications")
        } else {
            alert.messageText = "Open Clouding Bar from Applications?"
            alert.informativeText = "This copy runs from the disk image, so it can't update itself. \(folder.path) already has Clouding Bar \(installed ?? ""): that one opens, and the disk image is ejected."
            alert.addButton(withTitle: "Open from Applications")
        }
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            DebugLog.tap("move to Applications: not now")
            return
        }
        // Any other copy still running (another image's, the one replaced)
        // would hold the socket beside the new one: two clouds (review).
        quitOthers(keeping: replace ? nil : target)
        do {
            if replace { try copy(to: target) }
        } catch {
            DebugLog.note("move to Applications: \(error.localizedDescription)")
            let failed = NSAlert()
            failed.messageText = "Couldn't move it"
            failed.informativeText = "\(error.localizedDescription) Drag Clouding Bar from the disk image into Applications yourself."
            failed.runModal()
            return
        }
        DebugLog.tap(replace ? "move to Applications: moved" : "move to Applications: opening the one there")
        Updater.forgetLastCheck()
        reopen(target)
    }

    /// Where a copy already is (never a second one beside it), else
    /// /Applications, or ~/Applications when you can't write to it
    /// (CLOUDINGBAR_APPLICATIONS stands in for it in tests).
    private static func applicationsFolder() -> URL {
        if let dir = ProcessInfo.processInfo.environment["CLOUDINGBAR_APPLICATIONS"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        let fm = FileManager.default
        let shared = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let own = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        if let existing = [shared, own].first(where: { fm.fileExists(atPath: $0.appendingPathComponent(here.lastPathComponent).path) }) {
            return existing
        }
        if fm.isWritableFile(atPath: shared.path) { return shared }
        try? fm.createDirectory(at: own, withIntermediateDirectories: true)
        return own
    }

    private static func version(at app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }

    /// Copied beside the target first and checked, so a failed copy leaves
    /// the old one in place. Without the quarantine flag: copied by this app,
    /// not by Finder, it would otherwise be translocated and read-only again
    /// (`ditto --noqtn` keeps it on a plain copy: checked 29.10).
    private static func copy(to target: URL) throws {
        let fm = FileManager.default
        let staged = target.deletingLastPathComponent().appendingPathComponent(".Clouding Bar move.app")
        try? fm.removeItem(at: staged)
        guard run("/usr/bin/ditto", [here.path, staged.path]) else {
            try? fm.removeItem(at: staged)
            throw Failure("The copy didn't come out whole.")
        }
        run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path]) else {
            try? fm.removeItem(at: staged)
            throw Failure("The copy didn't come out whole.")
        }
        // The older copy moved aside, not deleted, until the new one is in
        // its place (as Updater.put does): a failed move puts it back.
        let old = target.deletingLastPathComponent().appendingPathComponent(".Clouding Bar old.app")
        let hadOne = fm.fileExists(atPath: target.path)
        if hadOne {
            try? fm.removeItem(at: old)
            do {
                try fm.moveItem(at: target, to: old)
            } catch {
                try? fm.removeItem(at: staged)
                throw Failure("The older copy in \(target.deletingLastPathComponent().path) can't be replaced.")
            }
        }
        do {
            try fm.moveItem(at: staged, to: target)
        } catch {
            if hadOne { try? fm.moveItem(at: old, to: target) }
            try? fm.removeItem(at: staged)
            throw error
        }
        if hadOne { try? fm.removeItem(at: old) }
    }

    /// Every other running copy (but the one `keeping`, opened next): asked
    /// to quit, then made to.
    private static func quitOthers(keeping: URL?) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != getpid() && (keeping == nil || $0.bundleURL?.standardizedFileURL != keeping?.standardizedFileURL) }
        guard !running.isEmpty else { return }
        DebugLog.note("move to Applications: quitting \(running.compactMap { $0.bundleURL?.path })")
        running.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(5)
        while running.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        running.filter { !$0.isTerminated }.forEach { $0.forceTerminate() }
    }

    /// Opens the copy in Applications once this one has quit (≤10 s), then
    /// ejects the image this one ran from.
    private static func reopen(_ app: URL) {
        let volume = (try? here.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path
        let image = AppPlace.imageToEject(path: here.path, volume: volume, images: mountedImages()) ?? ""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", """
            n=0; while kill -0 "$2" 2>/dev/null && [ $n -lt 50 ]; do sleep 0.2; n=$((n+1)); done
            /usr/bin/open "$0"
            [ -z "$1" ] || for i in 1 2 3 4 5; do /usr/bin/hdiutil detach -quiet "$1" && break; sleep 1; done
            """, app.path, image, String(getpid())]
        try? p.run()
        NSApp.terminate(nil)
    }

    /// Where disk images are mounted, from hdiutil: a read-only stick or
    /// share under /Volumes is never ejected (review).
    private static func mountedImages() -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["info", "-plist"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return [] }
        return (info["images"] as? [[String: Any]] ?? []).flatMap { image in
            (image["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["mount-point"] as? String }
        }
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
