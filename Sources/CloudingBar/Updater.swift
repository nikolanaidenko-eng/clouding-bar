import AppKit
import Security

/// Clouding Bar keeps itself up to date. Once a day it asks GitHub for the
/// newest release (UpdateCheck) — a plain request, nothing about you in it.
/// Install downloads that release, checks it (signed with Clouding Bar's
/// Developer ID, notarized by Apple, a newer version), puts it in place of
/// this copy and opens it; macOS keeps the permissions, the signature being
/// the same. Only in a release build: a build of your own stays yours.
final class Updater {
    enum State: Equatable {
        case idle, checking, upToDate, available(String), installing, failed(String)
    }

    static let team = "8RFNMA23CG"
    var onChange: ((State) -> Void)?
    private(set) var state: State = .idle {
        didSet { if state != oldValue { onChange?(state) } }
    }
    private(set) var release: UpdateCheck.Release?
    private var timer: Timer?
    private var stamp: URL { Self.stamp }
    private static var stamp: URL { Config.directory.appendingPathComponent("update-check.json") }

    /// The copy opened next checks a minute after launch, not a day after
    /// this one did (moved to Applications from the disk image).
    static func forgetLastCheck() { try? FileManager.default.removeItem(at: stamp) }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// This copy is a release: signed with Clouding Bar's Developer ID.
    static var isRelease: Bool { teamID(of: Bundle.main.bundleURL) == team }

    static func teamID(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// The daily check, while `enabled` says so: a minute after launch,
    /// then every hour it looks whether a day has passed.
    func start(enabled: @escaping () -> Bool) {
        guard Self.isRelease else { return }
        let tick = { [weak self] in
            guard let self, enabled(), UpdateCheck.due(lastCheck: self.lastCheck) else { return }
            self.check()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: tick)
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in tick() }
    }

    private var lastCheck: Date? {
        guard let data = try? Data(contentsOf: stamp),
              let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let t = (o["t"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: t)
    }

    /// Asks GitHub now (the daily check, or "Check now").
    func check() {
        guard state != .checking, state != .installing else { return }
        guard Self.isRelease else {
            state = .failed("A build of your own: it doesn't update itself")
            return
        }
        state = .checking
        var request = URLRequest(url: UpdateCheck.feed, timeoutInterval: 30)
        request.setValue("CloudingBar/\(Self.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard let data, error == nil, status == 200 || UpdateCheck.feed.isFileURL else {
                    self.state = .failed(status == 404 ? "No releases to be seen on GitHub" : "GitHub didn't answer")
                    DebugLog.note("update check: \(error?.localizedDescription ?? "HTTP \(status)")")
                    return
                }
                try? JSONSerialization.data(withJSONObject: ["t": Date().timeIntervalSince1970])
                    .write(to: self.stamp, options: .atomic)
                if let newest = UpdateCheck.newest(in: data), UpdateCheck.isNewer(newest.version, than: Self.version) {
                    self.release = newest
                    self.state = .available(newest.version)
                    DebugLog.note("update check: \(newest.version) is out")
                } else {
                    self.release = nil
                    self.state = .upToDate
                }
            }
        }.resume()
    }

    /// Downloads, checks and installs the release found, then opens it.
    func install() {
        guard let release, state != .installing else { return }
        let target = Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            fail("Can't write to \(parent.path): download it from GitHub instead", open: release.page)
            return
        }
        state = .installing
        DebugLog.note("update: downloading \(release.version)")
        URLSession.shared.downloadTask(with: release.dmg) { [weak self] file, _, error in
            guard let self else { return }
            let fm = FileManager.default
            let work = fm.temporaryDirectory.appendingPathComponent("clouding-bar-update-\(UUID().uuidString)")
            let dmg = work.appendingPathComponent("update.dmg")
            do {
                guard let file, error == nil else { throw Failure("the download failed") }
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                try fm.moveItem(at: file, to: dmg)
            } catch {
                DispatchQueue.main.async { self.fail("Download failed: \(error.localizedDescription)", open: nil) }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try Self.put(dmg: dmg, in: work, version: release.version, over: target) }
                try? fm.removeItem(at: work)
                DispatchQueue.main.async {
                    switch result {
                    case .success:
                        DebugLog.note("update: \(release.version) installed, reopening")
                        Self.relaunch(target)
                    case .failure(let error):
                        DebugLog.problem("update install", "update: \(release.version) not installed: \(error.localizedDescription)")
                        self.fail("Not installed: \(error.localizedDescription)", open: release.page)
                    }
                }
            }
        }.resume()
    }

    private func fail(_ message: String, open page: URL?) {
        state = .failed(message)
        DebugLog.note("update: \(message)")
        if let page { NSWorkspace.shared.open(page) }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Mounts the disk image, checks the app in it and swaps it in for
    /// `target` (the old one goes, the new one takes its exact place).
    private static func put(dmg: URL, in work: URL, version: String, over target: URL) throws {
        let fm = FileManager.default
        let mount = work.appendingPathComponent("mnt")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        // The disk image itself signed by us before it's even opened: the
        // system doesn't parse a stranger's image.
        guard run("/usr/bin/codesign", ["--verify", "-R=anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"",
                                        dmg.path]) else { throw Failure("the disk image isn't signed with Clouding Bar's Developer ID") }
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-quiet",
                                       "-mountpoint", mount.path, dmg.path]) else { throw Failure("the disk image didn't open") }
        defer { _ = run("/usr/bin/hdiutil", ["detach", "-quiet", "-force", mount.path]) }
        let app = mount.appendingPathComponent(target.lastPathComponent)
        try verify(app, version: version)

        let staged = target.deletingLastPathComponent().appendingPathComponent(".Clouding Bar update.app")
        let old = target.deletingLastPathComponent().appendingPathComponent(".Clouding Bar old.app")
        try? fm.removeItem(at: staged)
        try? fm.removeItem(at: old)
        guard run("/usr/bin/ditto", [app.path, staged.path]) else { throw Failure("couldn't copy it") }
        try verify(staged, version: version)
        try fm.moveItem(at: target, to: old)
        do {
            try fm.moveItem(at: staged, to: target)
        } catch {
            try? fm.moveItem(at: old, to: target) // put this one back
            throw error
        }
        try? fm.removeItem(at: old)
    }

    /// Signed with Clouding Bar's Developer ID, all of it intact, notarized
    /// by Apple, and the version that was offered.
    private static func verify(_ app: URL, version: String) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == version else { throw Failure("it isn't the version offered") }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
            + " and identifier \"\(Bundle.main.bundleIdentifier ?? "dev.cloudingbar.app")\""
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate
                                                            | kSecCSCheckNestedCode), requirement) == errSecSuccess
        else { throw Failure("it isn't signed with Clouding Bar's Developer ID") }
        guard run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) else {
            throw Failure("Apple hasn't notarized it")
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

    /// Opens the new copy a moment after this one quits.
    private static func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        NSApp.terminate(nil)
    }
}
