import AppKit

// What's kept on disk and what's read from it: reports, the app's own copy,
// the update stamp, the limit's history, config.json, and Claude Code's and
// VS Code's settings. All in folders of the checks' own.

func runFileChecks() {
    let fm = FileManager.default

    // MARK: Reports

    withShortFolder("reports") { dir in
        let files = ReportFiles(folder: dir)
        check(files.saved().isEmpty && files.lastDetail() == nil, "reports: none yet")
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for i in 0..<25 { files.keep("report \(i)", now: start.addingTimeInterval(Double(i))) }
        let kept = files.saved()
        check(kept.count == 20, "reports: only the last 20 stay")
        let words = kept.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        check(words.first == "report 24" && words.last == "report 5", "reports: the newest first, the oldest gone")
        try? "other".write(to: dir.appendingPathComponent("offered"), atomically: true, encoding: .utf8)
        check(files.saved().count == 20, "reports: only reports count as reports")
        check(files.lastDetail() == "report 24", "reports: the last one kept, today's")
        try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-90_000)], ofItemAtPath: kept[0].path)
        check(files.lastDetail() == nil, "reports: from before today: not offered again")
    }
    withShortFolder("same-second") { dir in
        let files = ReportFiles(folder: dir)
        let moment = Date(timeIntervalSince1970: 1_800_000_000)
        files.keep("the first problem", now: moment)
        files.keep("another one in the same second", now: moment)
        knownBug(files.saved().count == 2, "ReportFiles.keep names a report by the second: two problems in one second keep only the last")
    }
    withShortFolder("offered") { dir in
        let files = ReportFiles(folder: dir)
        check(!files.wasOffered("1.0 crash"), "offers: none yet")
        files.noteOffered("1.0 crash")
        check(files.wasOffered("1.0 crash") && !files.wasOffered("1.1 crash"), "offers: once for each kind and version")
        check(!files.wasOffered("1.0"), "offers: a whole line, not part of one")
        for i in 0..<250 { files.noteOffered("kind \(i)") }
        check(files.wasOffered("kind 249") && files.wasOffered("kind 50") && !files.wasOffered("kind 49") && !files.wasOffered("1.0 crash"), "offers: the last 200")
        check(files.crashesSeen() == nil, "crashes: the first look: only from now on, not one from long ago")
        check(files.crashesSeen() != nil, "crashes: the next one, since then")
    }
    withShortFolder("crashes") { dir in
        func report(_ name: String, _ age: TimeInterval) {
            let url = dir.appendingPathComponent(name)
            try? "x".write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
        }
        let since = Date().addingTimeInterval(-3600)
        check(ReportFiles.newestCrash(in: dir, since: since) == nil, "crashes: none")
        report("CloudingBar-old.ips", 7200)
        check(ReportFiles.newestCrash(in: dir, since: since) == nil, "crashes: from before the last look: seen")
        report("CloudingBar-a.ips", 600)
        report("CloudingBar-b.ips", 60)
        report("Other-app.ips", 1)
        report("CloudingBar-c.txt", 1)
        check(ReportFiles.newestCrash(in: dir, since: since)?.lastPathComponent == "CloudingBar-b.ips", "crashes: the newest of ours, nothing else's")
        check(ReportFiles.newestCrash(in: dir.appendingPathComponent("nowhere"), since: since) == nil, "crashes: no such folder: none")
    }

    // MARK: Putting the app in place

    withShortFolder("swap") { dir in
        let target = dir.appendingPathComponent("Clouding Bar.app")
        let staged = dir.appendingPathComponent(".Clouding Bar move.app")
        let old = dir.appendingPathComponent(".Clouding Bar old.app")
        func app(_ url: URL, _ version: String) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            try? version.write(to: url.appendingPathComponent("v"), atomically: true, encoding: .utf8)
        }
        func version(_ url: URL) -> String? { try? String(contentsOf: url.appendingPathComponent("v"), encoding: .utf8) }

        app(staged, "new")
        check((try? AppSwap.put(staged, over: target, aside: old)) != nil && version(target) == "new" && !fm.fileExists(atPath: staged.path) && !fm.fileExists(atPath: old.path),
              "swap: none there yet: it takes the place")
        app(staged, "newer")
        check((try? AppSwap.put(staged, over: target, aside: old)) != nil && version(target) == "newer" && !fm.fileExists(atPath: old.path), "swap: an older one replaced, none left aside")
        app(old, "left from a crash")
        app(staged, "newest")
        check((try? AppSwap.put(staged, over: target, aside: old)) != nil && version(target) == "newest" && !fm.fileExists(atPath: old.path), "swap: one left aside before is no obstacle")

        // The new copy missing: the old one stays where it was.
        var failed = false
        do { try AppSwap.put(staged, over: target, aside: old) } catch { failed = !(error is AppSwap.OldStays) }
        check(failed && version(target) == "newest" && !fm.fileExists(atPath: old.path), "swap: the new one can't be moved in: the old one is back in its place")

        // The old one can't be moved: it isn't touched, the staged copy goes.
        let locked = dir.appendingPathComponent("locked")
        try? fm.createDirectory(at: locked, withIntermediateDirectories: true)
        let lockedTarget = locked.appendingPathComponent("Clouding Bar.app")
        app(lockedTarget, "installed")
        app(staged, "new")
        try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        var stayed = false
        do { try AppSwap.put(staged, over: lockedTarget, aside: locked.appendingPathComponent(".old.app")) } catch { stayed = error is AppSwap.OldStays }
        check(stayed && version(lockedTarget) == "installed" && !fm.fileExists(atPath: staged.path), "swap: the older one can't be moved aside: it stays, the copy goes")
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
    }
    do {
        let shared = URL(fileURLWithPath: "/Applications"), own = URL(fileURLWithPath: "/Users/me/Applications")
        func folder(exists: [String], writable: Bool) -> String {
            AppSwap.folder(name: "A.app", shared: shared, own: own, exists: { exists.contains($0) }, writable: { _ in writable }).path
        }
        check(folder(exists: [], writable: true) == "/Applications", "where it goes: the shared Applications")
        check(folder(exists: [], writable: false) == "/Users/me/Applications", "where it goes: your own when you can't write there")
        check(folder(exists: ["/Users/me/Applications/A.app"], writable: true) == "/Users/me/Applications", "where it goes: where a copy already is, never a second beside it")
        check(folder(exists: ["/Applications/A.app", "/Users/me/Applications/A.app"], writable: true) == "/Applications", "where it goes: two already: the shared one")
        check(folder(exists: ["/Applications/A.app"], writable: false) == "/Applications", "where it goes: one there, even if you can't write there")
        let plist: [String: Any] = ["images": [["system-entities": [["mount-point": "/Volumes/Clouding Bar"], ["dev-entry": "/dev/disk4"]]],
                                               ["system-entities": [["mount-point": "/Volumes/Other"]]], ["no entities": true]]]
        let data = (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
        check(AppSwap.mountPoints(hdiutilInfo: data) == ["/Volumes/Clouding Bar", "/Volumes/Other"], "disk images: where they're mounted, from hdiutil")
        check(AppSwap.mountPoints(hdiutilInfo: Data("not a plist".utf8)).isEmpty && AppSwap.mountPoints(hdiutilInfo: Data()).isEmpty, "disk images: nothing readable: none, so nothing's ejected")
    }

    // MARK: The update stamp

    withShortFolder("stamp") { dir in
        let url = dir.appendingPathComponent("update-check.json")
        check(UpdateStamp.read(url) == nil, "update stamp: never checked")
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        UpdateStamp.write(url, now: at)
        check(UpdateStamp.read(url) == at, "update stamp: when it was")
        check(UpdateCheck.due(lastCheck: UpdateStamp.read(url)) , "update stamp: long ago: due")
        UpdateStamp.write(url)
        check(!UpdateCheck.due(lastCheck: UpdateStamp.read(url)), "update stamp: just now: not due")
        for bad in ["not json", "{}", #"{"t":"today"}"#, "[1]"] {
            try? bad.write(to: url, atomically: true, encoding: .utf8)
            check(UpdateStamp.read(url) == nil, "update stamp: \(bad) reads as never")
        }
    }

    // MARK: The limit's history

    withShortFolder("history") { dir in
        withAppFolder(dir) { withHome(dir) {
            let file = dir.appendingPathComponent("limit-history.jsonl")
            let t = Date(timeIntervalSince1970: 1_900_000_000)
            LimitHistory.record(10, now: t)
            LimitHistory.record(10.4, now: t.addingTimeInterval(60))
            check(((try? String(contentsOf: file, encoding: .utf8)) ?? "").components(separatedBy: "\n").count == 2, "history: nothing new, nothing written")
            LimitHistory.record(11, now: t.addingTimeInterval(120))
            LimitHistory.record(11, now: t.addingTimeInterval(120 + 601))
            let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n")
            check(lines.count == 3 && lines[0].contains(#""p":10"#) && lines[2].contains(#""p":11"#), "history: on any change, else every 10 minutes")
            LimitHistory.record(12.6, now: t.addingTimeInterval(2000))
            let loaded = LimitHistory.load(since: t.addingTimeInterval(100))
            check(loaded.map(\.percent) == [11, 11, 13], "history: from then on, in order, rounded")
            try? "not json\n{\"t\":1900000300}\n{\"t\":\"x\",\"p\":1}\n{\"t\":1900000400,\"p\":44}\n".write(to: file, atomically: true, encoding: .utf8)
            check(LimitHistory.load(since: t).map(\.percent) == [44], "history: lines that don't read are skipped")

            // What Claude Desktop keeps, here in a home of the checks' own.
            check(LimitHistory.latestWeek() == nil, "history: no Claude Desktop: nothing of its")
            let folder = dir.appendingPathComponent("Library/Application Support/Claude")
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let desktop = folder.appendingPathComponent("plan-usage-history.json")
            let ms = t.timeIntervalSince1970 * 1000
            let samples = #"{"samples":[{"t":\#(Int(ms) + 5000),"u":{"fh":50,"sd":70}},{"t":\#(Int(ms)),"u":{"fh":20,"sd":30}},{"t":1,"u":{"fh":1}},{"u":{"fh":2,"sd":2}}]}"#
            try? samples.write(to: desktop, atomically: true, encoding: .utf8)
            check(LimitHistory.latestWeek()?.percent == 70, "history: Claude Desktop's newest weekly number")
            check(LimitHistory.load(since: t.addingTimeInterval(-1)).map(\.percent) == [20, 50, 44], "history: its 5-hour numbers join yours, in time order")
            try? "{}".write(to: desktop, atomically: true, encoding: .utf8)
            check(LimitHistory.latestWeek() == nil, "history: its file of another shape: nothing")
        } }
    }

    // MARK: config.json

    withShortFolder("config") { dir in
        withAppFolder(dir) {
            let url = Config.fileURL
            check(url.path.hasPrefix(dir.path) && Config.socketPath.hasPrefix(dir.path), "config: in the app's folder")
            check(Config.load().pillWidth == Config().pillWidth, "config: no file: the defaults")
            try? "not json".write(to: url, atomically: true, encoding: .utf8)
            check(Config.load().pillWidth == Config().pillWidth, "config: a file that doesn't read: the defaults")
            try? #"{"touchBarWidths":{"long":{"a":5,"b":5000,"c":300}},"widgetPosition":[12,34],"itemWidths":{"x":1,"y":9999,"z":100},"questionHoldSeconds":-5,"permissionHoldSeconds":-1,"appearance":"purple","buttonColors":"neon","pillRows":2,"touchBar":false}"#
                .write(to: url, atomically: true, encoding: .utf8)
            let c = Config.load()
            check(c.touchBarWidths["long"] == ["a": 24, "b": 800, "c": 300], "config: a block's width within what the bar can take")
            check(c.itemWidths == ["x": 20, "y": 600, "z": 100], "config: an item's within what the pill can take")
            check(c.widgetPosition == CGPoint(x: 12, y: 34), "config: where you put the widget")
            check(c.questionHoldSeconds == 0 && c.permissionHoldSeconds == 0, "config: never a negative wait")
            check(c.appearance == Config().appearance && c.buttonColors == Config().buttonColors, "config: a look it doesn't know: the default")
            check(c.pillRows == 2 && c.touchBar == "off", "config: the old on and off for the bar still read")
            try? #"{"widgetPosition":[12],"touchBar":"auto"}"#.write(to: url, atomically: true, encoding: .utf8)
            check(Config.load().widgetPosition == nil && Config.load().touchBar == "auto", "config: half a position is none")

            try? #"{"keep":"me","pillWidth":100}"#.write(to: url, atomically: true, encoding: .utf8)
            Config.save("pillWidth", 200)
            check(Config.load().pillWidth == 200 && ((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains("keep"), "config: one key set, everything else in the file kept")
            Config.save("pillWidth", NSNull())
            check(Config.load().pillWidth == Config().pillWidth && !((try? String(contentsOf: url, encoding: .utf8)) ?? "").contains("pillWidth"), "config: NSNull takes a key out")
            try? fm.removeItem(at: url)
            Config.save("doNotDisturb", true)
            check(Config.load().doNotDisturb, "config: no file yet: one is made")

            var buttons = Config()
            check(buttons.effectiveButtons.map(\.label) == ["summary", "compact"], "buttons: the defaults")
            buttons.officeURL = "https://example.com"
            check(buttons.effectiveButtons.last?.type == .link, "buttons: the office's link with them")
            buttons.skills = ["review"]
            check(buttons.effectiveButtons.last?.value == "review", "buttons: and your skills")
            let mine = ButtonSpec(label: "mine", type: .command, value: "/mine")
            let theirs = ButtonSpec(label: "theirs", type: .command, value: "/theirs")
            buttons.buttons = [mine]
            buttons.profiles = ["proj": [theirs]]
            check(buttons.effectiveButtons == [mine] && buttons.buttons(for: nil) == [mine] && buttons.buttons(for: "other") == [mine] && buttons.buttons(for: "proj") == [theirs],
                  "buttons: a project's own over the main list")
        }
    }

    // MARK: The debug log

    withShortFolder("log") { dir in
        withAppFolder(dir) {
            let log = dir.appendingPathComponent("debug.log")
            func logged() -> String { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
            DebugLog.note("first line")
            DebugLog.note("second line")
            check(logged().components(separatedBy: "\n").count == 3 && logged().contains("note: first line") && logged().contains("note: second line"), "log: lines added, not replaced")
            DebugLog.tap("a tap")
            check(logged().contains("a tap trusted=") && logged().contains("front="), "log: a tap, with whether macOS lets the keys through")
            var told: [String] = []
            DebugLog.onProblem = { kind, _ in told.append(kind) }
            let kind = "check-\(getpid())"
            DebugLog.problem(kind, "it broke")
            DebugLog.problem(kind, "it broke again")
            DebugLog.onProblem = nil
            check(told == [kind], "log: a problem offered once a run")
            check(logged().contains("problem: it broke") && !logged().contains("it broke again"), "log: and written once: one that goes on would fill the log")
        }
    }

    // MARK: Claude Desktop's own lists, in a home of the checks' own

    withShortFolder("homes") { dir in
        withHome(dir) {
            check(DesktopSessions.folder.path.hasPrefix(dir.path), "home: the checks' own, never yours")
            check(FileManager.default.homeDirectoryForCurrentUser.path == dir.path && NSHomeDirectory() == dir.path, "home: for all that asks")
        }
    }
}

func runSetupChecks() {
    let fm = FileManager.default
    withShortFolder("setup") { dir in
        withAppFolder(dir) {
            let settings = dir.appendingPathComponent("claude/settings.json")
            let vscode = dir.appendingPathComponent("Code/User/settings.json")
            setenv("CLOUDINGBAR_CLAUDE_SETTINGS", settings.path, 1)
            setenv("CLOUDINGBAR_VSCODE_SETTINGS", vscode.path, 1)
            setenv("CLOUDINGBAR_CODEX_HOME", dir.appendingPathComponent("codex").path, 1)
            try? fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            func read() -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(contentsOf: settings))) as? [String: Any] ?? [:] }
            func backups() -> [String] { ((try? fm.contentsOfDirectory(atPath: dir.appendingPathComponent("backups").path)) ?? []) }

            // MARK: Claude Code

            check(!Setup.isConnected, "connect: no settings yet")
            check((try? Setup.connect()) != nil && Setup.isConnected, "connect: no file: one is made")
            check(backups().isEmpty, "connect: nothing to back up")

            let garbage = "{ not plain json, // comments"
            try? garbage.write(to: settings, atomically: true, encoding: .utf8)
            var refused = false
            do { try Setup.connect() } catch { refused = (error as? Setup.SetupError) != nil && error.localizedDescription.contains("left alone") }
            check(refused && (try? String(contentsOf: settings, encoding: .utf8)) == garbage, "connect: a file it can't read is left as it is, and it says so")
            try? " \n\t ".write(to: settings, atomically: true, encoding: .utf8)
            check((try? Setup.connect()) != nil && Setup.isConnected, "connect: only spaces in it: as empty")

            let theirs = #"{"permissions":{"allow":["Bash"]},"theme":"dark","statusLine":{"type":"command","command":"/my/line.sh"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/my/hook.sh"}]},{"hooks":[{"type":"command","command":"/old/.claudebar/x"}]}],"PreToolUse":[{"hooks":[{"type":"command","command":"\#(NSHomeDirectory())/.claudebar/claudebar-hook"}]}]}}"#
            try? theirs.write(to: settings, atomically: true, encoding: .utf8)
            check((try? Setup.connect()) != nil, "connect: over what's there")
            let merged = read()
            check(merged["theme"] as? String == "dark" && (merged["permissions"] as? [String: Any])?["allow"] != nil, "connect: everything else in the file stays")
            let stop = ((merged["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]]) ?? []
            let stopCommands = stop.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }.compactMap { $0["command"] as? String }
            check(stopCommands.contains("/my/hook.sh") && stopCommands.contains(Setup.hook), "connect: your own hook stays beside ours")
            let pre = ((merged["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]]) ?? []
            let preHooks = pre.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            check(preHooks.count == 1 && preHooks[0]["command"] as? String == Setup.hook && preHooks[0]["timeout"] as? Int == 330, "connect: an older install's hook becomes ours, not a second one")
            check((merged["statusLine"] as? [String: Any])?["command"] as? String == Setup.statusLine && (merged["statusLine"] as? [String: Any])?["refreshInterval"] as? Int == 5, "connect: the status line is ours")
            check((try? String(contentsOf: dir.appendingPathComponent("statusline-original"), encoding: .utf8)) == "/my/line.sh", "connect: yours is kept, called through ours")
            let backupsFolder = dir.appendingPathComponent("backups")
            check(backups().contains { (try? String(contentsOf: backupsFolder.appendingPathComponent($0), encoding: .utf8)) == theirs }, "connect: the file backed up first, as it was")

            let oldBackups = backups().count
            let content = try? Data(contentsOf: settings)
            check((try? Setup.connect()) != nil && (try? Data(contentsOf: settings)) == content && backups().count == oldBackups, "connect again: nothing to change, nothing written")
            check((try? String(contentsOf: dir.appendingPathComponent("statusline-original"), encoding: .utf8)) == "/my/line.sh", "connect again: yours isn't overwritten with ours")

            // Through a link (dotfiles): the link stays.
            let real = dir.appendingPathComponent("dotfiles/settings.json")
            try? fm.createDirectory(at: real.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? "{}".write(to: real, atomically: true, encoding: .utf8)
            try? fm.removeItem(at: settings)
            try? fm.createSymbolicLink(at: settings, withDestinationURL: real)
            check((try? Setup.connect()) != nil && (try? fm.destinationOfSymbolicLink(atPath: settings.path)) == real.path, "connect: a link to your dotfiles stays a link")
            check(((try? String(contentsOf: real, encoding: .utf8)) ?? "").contains("hooks"), "connect: the file behind it is changed")
            try? fm.removeItem(at: settings)

            // Named by the second: connected twice in one, the first backup is gone.
            try? "{\"one\":1}".write(to: settings, atomically: true, encoding: .utf8)
            try? Setup.connect()
            try? "{\"two\":2}".write(to: settings, atomically: true, encoding: .utf8)
            try? Setup.connect()
            knownBug(backups().contains { (try? String(contentsOf: backupsFolder.appendingPathComponent($0), encoding: .utf8)) == "{\"one\":1}" },
                     "a settings backup is named by the second: two changes in one second keep only the last")
            try? fm.removeItem(at: settings)

            // MARK: Codex

            let codexHooks = Setup.codexHooksURL
            check(!Setup.hasCodex && !Setup.codexConnected, "Codex: not on this Mac")
            check((try? Setup.connectCodex()) != nil && Setup.codexHooksInFile && Setup.codexConnected, "Codex: connected")
            let hooksText = try? Data(contentsOf: codexHooks)
            check((try? Setup.connectCodex()) != nil && (try? Data(contentsOf: codexHooks)) == hooksText, "Codex again: entries already there are never touched")
            let codexGarbage = "{ nope"
            try? codexGarbage.write(to: codexHooks, atomically: true, encoding: .utf8)
            var codexRefused = false
            do { try Setup.connectCodex() } catch { codexRefused = true }
            check(codexRefused && (try? String(contentsOf: codexHooks, encoding: .utf8)) == codexGarbage && !Setup.codexHooksInFile, "Codex: a file it can't read is left as it is")
            let mineCodex = #"{"hooks":{"Stop":[{"hooks":[{"command":"/my/codex.sh"}]}]}}"#
            try? mineCodex.write(to: codexHooks, atomically: true, encoding: .utf8)
            check((try? Setup.connectCodex()) != nil, "Codex: over yours")
            let codexText = (try? String(contentsOf: codexHooks, encoding: .utf8)) ?? ""
            check(codexText.contains("/my/codex.sh") && Setup.codexHooksInFile, "Codex: yours stay, ours go after")
            let toml = dir.appendingPathComponent("codex/config.toml")
            func plugin(_ text: String) -> Bool {
                try? text.write(to: toml, atomically: true, encoding: .utf8)
                return Setup.codexPluginActive
            }
            check(plugin("[plugins.\"clouding-bar@clouding-bar\"]\nenabled = true\n"), "Codex plugin: on")
            check(plugin("[plugins.\"clouding-bar@clouding-bar\"]\nenabled=true # yes\n"), "Codex plugin: on, however it's written")
            check(!plugin("[plugins.\"clouding-bar@clouding-bar\"]\nenabled = false\n"), "Codex plugin: off")
            check(!plugin("[plugins.\"clouding-bar@other\"]\nenabled = true\n"), "Codex plugin: another marketplace's isn't ours")
            check(!plugin("[plugins.\"clouding-bar@clouding-bar\"]\n[other]\nenabled = true\n"), "Codex plugin: another section's enabled isn't ours")
            try? fm.removeItem(at: toml)
            try? fm.removeItem(at: codexHooks)
            _ = plugin("[plugins.\"clouding-bar@clouding-bar\"]\nenabled = true\n")
            check((try? Setup.connectCodex()) != nil && !fm.fileExists(atPath: codexHooks.path), "Codex: the plugin brings the hooks: no second set")
            try? fm.removeItem(at: toml)

            // MARK: VS Code

            check(!Setup.hasVSCode, "VS Code: not on this Mac")
            if case .none = Setup.wrapVSCodeIfFree() { check(true, "VS Code: not there: nothing done") } else { check(false, "VS Code: not there: nothing done") }
            try? fm.createDirectory(at: vscode.deletingLastPathComponent(), withIntermediateDirectories: true)
            func vs() -> String { (try? String(contentsOf: vscode, encoding: .utf8)) ?? "" }
            func isDone(_ s: Setup.VSCodeStep) -> Bool { if case .done = s { return true }; return false }
            check(isDone(Setup.wrapVSCodeIfFree()) && Setup.vscodeWrapped, "VS Code: no settings yet: set")
            if case .already = Setup.wrapVSCodeIfFree() { check(true, "VS Code: set already") } else { check(false, "VS Code: set already") }

            try? "{\n}\n".write(to: vscode, atomically: true, encoding: .utf8)
            try? Setup.wrapVSCode()
            check(vs() == "{\n    \"claudeCode.claudeProcessWrapper\": \"\(Setup.wrapper)\"\n}\n", "VS Code: an empty object: no comma")
            try? "{\n  // my comment\n  \"editor.fontSize\": 14, // keep\n}\n".write(to: vscode, atomically: true, encoding: .utf8)
            try? Setup.wrapVSCode()
            check(vs().contains("// my comment") && vs().contains("// keep") && vs().contains("\(Setup.wrapper)\",\n"), "VS Code: edited as text, your comments and layout stay")
            try? "{\"claudeCode.claudeProcessWrapper\" : \"/old/.claudebar/claudebar-wrapper.sh\"}".write(to: vscode, atomically: true, encoding: .utf8)
            check(isDone(Setup.wrapVSCodeIfFree()) && vs() == "{\"claudeCode.claudeProcessWrapper\": \"\(Setup.wrapper)\"}", "VS Code: an older install's wrapper replaced")
            let own = "{\"claudeCode.claudeProcessWrapper\": \"/my/wrapper.sh\"}"
            try? own.write(to: vscode, atomically: true, encoding: .utf8)
            if case .others = Setup.wrapVSCodeIfFree() { check(vs() == own, "VS Code: a wrapper of your own stays") } else { check(false, "VS Code: a wrapper of your own stays") }
            try? Setup.wrapVSCode()
            check(vs().contains(Setup.wrapper), "VS Code: Set Up in Settings replaces it, if you mean to")
            try? "".write(to: vscode, atomically: true, encoding: .utf8)
            try? Setup.wrapVSCode()
            check(vs() == "{\n    \"claudeCode.claudeProcessWrapper\": \"\(Setup.wrapper)\"\n}\n", "VS Code: an empty file: an object made")
            try? Data([0xFF, 0xFE, 0x00, 0x7B]).write(to: vscode)
            let notText = try? Data(contentsOf: vscode)
            var notRead = false
            do { try Setup.wrapVSCode() } catch { notRead = (error as? Setup.SetupError) != nil }
            check(notRead && (try? Data(contentsOf: vscode)) == notText, "VS Code: not text in UTF-8: left as it is")
            if case .failed = Setup.wrapVSCodeIfFree() { check(true, "VS Code: and Connect says it couldn't") } else { check(false, "VS Code: and Connect says it couldn't") }

            // A comment before the object, with a brace or the setting's name in it.
            try? "// my settings {\n{\n    \"editor.fontSize\": 14\n}\n".write(to: vscode, atomically: true, encoding: .utf8)
            try? Setup.wrapVSCode()
            knownBug(vs().hasPrefix("// my settings {\n{\n"),
                     "wrapVSCode takes the first { as the object's: a comment before it with a brace gets the setting inside the comment's line, outside the object")
            try? "{\n    // \"claudeCode.claudeProcessWrapper\": \"/off.sh\"\n    \"editor.fontSize\": 14\n}\n".write(to: vscode, atomically: true, encoding: .utf8)
            try? Setup.wrapVSCode()
            knownBug(vs().contains("\n    \"claudeCode.claudeProcessWrapper\": \"\(Setup.wrapper)\""),
                     "wrapVSCode edits a commented-out wrapper line: the setting stays in the comment, off, while vscodeWrapped says it's set")

            if let what = Setup.describe(.done) { check(what.contains("VS Code"), "VS Code: Connect says so") } else { check(false, "VS Code: Connect says so") }
            check(Setup.describe(.none) == nil && Setup.describe(.already) == nil, "VS Code: nothing to say")
            check(Setup.describe(.others)?.contains("of your own") == true && Setup.describe(.failed("why"))?.contains("why") == true, "VS Code: what it left, and why it couldn't")

            unsetenv("CLOUDINGBAR_CLAUDE_SETTINGS")
            unsetenv("CLOUDINGBAR_VSCODE_SETTINGS")
            setenv("CLOUDINGBAR_CODEX_HOME", ProcessInfo.processInfo.environment["CLOUDINGBAR_DIR"]! + "/no-codex", 1)
        }
    }
    setenv("CLOUDINGBAR_CODEX_HOME", ProcessInfo.processInfo.environment["CLOUDINGBAR_DIR"]! + "/no-codex", 1)
}

func runTextChecks() {
    let fm = FileManager.default

    // MARK: Dictated words

    check(VoiceText.join(" a ", "b ") == "a b" && VoiceText.join("", " b") == "b" && VoiceText.join("a", "  ") == "a" && VoiceText.join("", "") == "", "voice: what was heard and what's heard now")
    check(!VoiceText.startedOver("Ну, вот", after: "Ну вот"), "voice: a comma on second thought isn't a new start")
    check(VoiceText.startedOver("Другое", after: "Ну вот и всё на сегодня"), "voice: much shorter and different: it began again")
    check(!VoiceText.startedOver("Ну вот и", after: "Ну вот и всё"), "voice: shorter, the same start: a revision")
    check(!VoiceText.startedOver("Longer than it was", after: "Long"), "voice: longer: a revision")
    check(!VoiceText.startedOver("", after: "Long") && !VoiceText.startedOver("Long", after: ""), "voice: nothing on either side: no")
    check(VoiceText.startedOver("Abc", after: "Xbc and more") && !VoiceText.startedOver("Ab", after: "Ab and more"), "voice: the first letters decide, as many as it has up to 4")
    check(!VoiceText.startedOver("LOUD", after: "loud words"), "voice: case aside")
    check(VoiceText.glue("a", "b") == "a b" && VoiceText.glue("a ", "b") == "a b" && VoiceText.glue("a", " b") == "a b" && VoiceText.glue("", "b") == "b" && VoiceText.glue("a", "") == "a",
          "voice: a space only where none is")

    // MARK: Whose cookie

    check(ClaudeAICookie.isClaudeAI("claude.ai") && ClaudeAICookie.isClaudeAI(".claude.ai"), "cookie: claude.ai's")
    check(!ClaudeAICookie.isClaudeAI("evilclaude.ai") && !ClaudeAICookie.isClaudeAI("claude.ai.evil.com") && !ClaudeAICookie.isClaudeAI("sub.claude.ai")
          && !ClaudeAICookie.isClaudeAI("") && !ClaudeAICookie.isClaudeAI(".") && !ClaudeAICookie.isClaudeAI("..claude.ai"), "cookie: nobody else's, whatever it's called")

    // MARK: Terminals' answers

    let tabs = TerminalTabs.parse("/dev/ttys001\tFirst tab\n/dev/ttys002\twith\ttab inside\nnot a tty\ttitle\n/dev/ttys003\t\n/dev/ttys004\n\n")
    check(tabs.map(\.tty) == ["/dev/ttys001", "/dev/ttys002"] && tabs.map(\.title) == ["First tab", "with\ttab inside"], "tabs: tty and title; anything else isn't one")
    check(TerminalTabs.parse("").isEmpty, "tabs: none")
    check(TerminalTabs.frontTTY("/dev/ttys003") == "/dev/ttys003" && TerminalTabs.frontTTY("error") == nil && TerminalTabs.frontTTY(nil) == nil, "tabs: only a device counts as the one in front")
    check(TerminalTabs.safe("/dev/ttys00\" & do shell script \"x") == "/dev/ttys00 & do shell script x", "tabs: nothing in a tty can close AppleScript's string")

    // MARK: Stats in words

    check(StatsText.duration(0) == "0 min" && StatsText.duration(59) == "59 min" && StatsText.duration(60) == "1 h" && StatsText.duration(61) == "1 h 1 min" && StatsText.duration(125) == "2 h 5 min",
          "stats: durations")
    var summary = StatsSummary()
    check(StatsText.subline(summary, rangeName: "this week") == "Nothing yet this week", "stats: nothing yet")
    summary.favoriteModel = "Opus 5.5"
    summary.peakHour = 14
    summary.busiestWeekday = 3
    check(StatsText.subline(summary, rangeName: "x") == "Mostly Opus 5.5 · peak hour 14:00 · busiest on Tuesdays", "stats: the favourite, the hour, the day")
    summary.favoriteModel = nil
    summary.busiestWeekday = 1
    check(StatsText.subline(summary, rangeName: "x") == "peak hour 14:00 · busiest on Sundays", "stats: only what's known; 1 is Sunday")

    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, in cal: Calendar) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))! }
    let sunday = date(2026, 11, 1, in: utc), monday = date(2026, 11, 2, in: utc)
    let toSunday = StatsText.gridDays(weeks: 26, now: sunday, calendar: utc)
    check(toSunday.count == 26 && toSunday.allSatisfy { $0.count == 7 }, "stats grid: 26 weeks of 7")
    check(toSunday.last?.allSatisfy { $0 != nil } == true, "stats grid: on a Sunday, the whole week")
    let toMonday = StatsText.gridDays(weeks: 26, now: monday, calendar: utc)
    check(toMonday.last?.filter { $0 != nil }.count == 1, "stats grid: on a Monday, just that day of the week")
    check(toMonday.dropLast().allSatisfy { $0.allSatisfy { $0 != nil } }, "stats grid: every earlier week whole")
    var weekOne = utc
    weekOne.firstWeekday = 1
    check(StatsText.gridDays(weeks: 1, now: sunday, calendar: weekOne)[0][0].map { utc.component(.weekday, from: $0) } == 2, "stats grid: its weeks begin on Monday, whatever the calendar says")
    var paris = Calendar(identifier: .gregorian)
    paris.timeZone = TimeZone(identifier: "Europe/Paris")!
    // The clocks went back on 25.10.2026: a day of 25 hours in the grid.
    let overChange = StatsText.gridDays(weeks: 3, now: date(2026, 11, 1, in: paris), calendar: paris).flatMap { $0 }.compactMap { $0 }
    check(overChange.count == 21 && zip(overChange, overChange.dropFirst()).allSatisfy { paris.dateComponents([.day], from: $0, to: $1).day == 1 }, "stats grid: a day apart each, across a change of clocks")
    let newYear = StatsText.gridDays(weeks: 2, now: date(2027, 1, 3, in: utc), calendar: utc).flatMap { $0 }
    check(newYear.count == 14 && newYear.allSatisfy { $0 != nil }, "stats grid: across a new year")

    // MARK: Dropped files and colours

    check(FileDrop.quoted("/a/b.png") == "/a/b.png" && FileDrop.quoted("/a b/c.png") == "\"/a b/c.png\"", "files: a path as written for Claude")
    check(FileDrop.symbol("/x/a.PNG") == "photo" && FileDrop.symbol("/x/a.heic") == "photo" && FileDrop.symbol("/x/a.txt") == "doc" && FileDrop.symbol("/x/noext") == "doc", "files: a picture or a document, by its name")
    withShortFolder("drop") { dir in
        withAppFolder(dir) {
            check(FileDrop.symbol(dir.path) == "folder", "files: a folder")
            let board = NSPasteboard(name: NSPasteboard.Name("cloudingbar-check-\(getpid())"))
            board.clearContents()
            check(!FileDrop.canRead(board) && FileDrop.read(board).isEmpty, "files: nothing on the pasteboard")
            let file = dir.appendingPathComponent("a file.txt")
            try? "x".write(to: file, atomically: true, encoding: .utf8)
            board.clearContents()
            board.writeObjects([file as NSURL])
            check(FileDrop.canRead(board) && FileDrop.read(board).map(\.path) == [file.path], "files: as they are")
            board.clearContents()
            board.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
            let saved = FileDrop.read(board)
            check(FileDrop.canRead(board) && saved.count == 1 && saved[0].path.hasPrefix(dir.appendingPathComponent("shots").path)
                  && saved[0].pathExtension == "png" && (try? Data(contentsOf: saved[0])) == Data([0x89, 0x50, 0x4E, 0x47]),
                  "files: a picture with no file behind it, saved first")
            board.clearContents()
            board.setString("just words", forType: .string)
            check(!FileDrop.canRead(board) && FileDrop.read(board).isEmpty, "files: words aren't files")
            board.releaseGlobally()
        }
    }
    check(Palette.meterColor(0) == Palette.meter && Palette.meterColor(69.9) == Palette.meter && Palette.meterColor(70) == Palette.warning
          && Palette.meterColor(89.9) == Palette.warning && Palette.meterColor(90) == Palette.critical && Palette.meterColor(150) == Palette.critical, "meter: blue, orange at 70, red at 90")
    let hex = NSColor(hex: 0x102030).usingColorSpace(.sRGB)
    check(hex.map { abs($0.redComponent - 16 / 255) < 0.001 && abs($0.greenComponent - 32 / 255) < 0.001 && abs($0.blueComponent - 48 / 255) < 0.001 && $0.alphaComponent == 1 } == true, "colour: from its hex")

    // MARK: Keys, read and never pressed

    check(KeySender.keyName(for: 53) == "esc" && KeySender.keyName(for: 36) == "return" && KeySender.keyName(for: 51) == "delete", "keys: the short name, of two for one key")
    check(KeySender.keyName(for: 0) == "a" && KeySender.keyName(for: 200) == nil, "keys: a letter; none for what it doesn't know")
    check(KeySender.keyCode(for: "ESC") == 53 && KeySender.keyCode(for: "nope") == nil, "keys: by name, whatever its case")
    func recorded(_ flags: NSEvent.ModifierFlags, _ code: UInt16) -> String? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code).flatMap(HotKeys.combo(from:))
    }
    check(recorded([.control, .option], 8) == "ctrl+opt+c" && recorded([.shift, .command], 0) == "shift+cmd+a", "shortcut: recorded in one order")
    check(recorded([], 8) == nil, "shortcut: a bare key would steal normal typing")
    check(recorded([.command], 200) == nil, "shortcut: a key it doesn't know")
    check(HotKeys.carbon("ctrl+opt+c") != nil && HotKeys.carbon("c") == nil && HotKeys.carbon("ctrl+nope") == nil && HotKeys.carbon("") == nil, "shortcut: read back; a bare or unknown key isn't one")

    // MARK: Dates as they come, and small words

    let micro = ClaudeAIChats.date("2026-10-30T12:00:05.123456+00:00")
    check(micro.map { abs($0.timeIntervalSince1970 - 1793361605.123) < 0.01 } == true, "dates: microseconds cut to milliseconds")
    check(ClaudeAIChats.date("2026-10-30T12:00:05Z") != nil && ClaudeAIChats.date("2026-10-30T12:00:05.5Z") != nil, "dates: with fractions or none")
    check(ClaudeAIChats.date("yesterday") == nil && ClaudeAIChats.date("not.a.date") == nil && ClaudeAIChats.date(5) == nil && ClaudeAIChats.date(nil) == nil, "dates: none from what isn't one")
    let codexMicro = CodexRollout.date("2026-10-30T12:00:05.876641+00:00")
    check(codexMicro.map { abs($0.timeIntervalSince1970 - 1793361605.876) < 0.01 } == true, "Codex's dates: microseconds cut too")
    check(CodexRollout.date("2026-10-30T12:00:05.123Z") != nil && CodexRollout.date("2026-10-30T12:00:05Z") != nil, "Codex's dates: with fractions or none")
    check(CodexRollout.date("nope") == nil && CodexRollout.date("a.b") == nil && CodexRollout.date("2026.") == nil, "Codex's dates: none from what isn't one")
    check(ModelChoice.label(model: nil, effort: "high") == nil && ModelChoice.label(model: "Opus", effort: nil) == "Opus" && ModelChoice.label(model: "Opus", effort: "high") == "Opus · high",
          "model label: the model, and its effort if any")

    // MARK: What the transcript says, read as it's written

    withShortFolder("watch") { dir in
        let watcher = TranscriptWatcher()
        let file = dir.appendingPathComponent("t.jsonl")
        func poll() -> TranscriptWatcher.Update? {
            var got: TranscriptWatcher.Update?
            var done = false
            watcher.poll([(id: "t", path: file.path)]) { got = $0.first; done = true }
            spin(5) { done }
            return got
        }
        let patch = #"{"type":"user","toolUseResult":{"structuredPatch":[{"lines":["+a","+b","-c"," d"]},{"lines":["-e"]}]}}"#
        let created = #"{"type":"user","toolUseResult":{"type":"create","content":"one\ntwo\nthree"}}"#
        try? (patch + "\n" + created + "\n").write(to: file, atomically: true, encoding: .utf8)
        let lines = poll()
        check(lines?.linesAdded == 5 && lines?.linesRemoved == 2, "transcript: ±lines from an edit's hunks and a new file")
        let handle = try? FileHandle(forWritingTo: file)
        _ = try? handle?.seekToEnd()
        try? handle?.write(contentsOf: Data((#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}"# + "\n").utf8))
        try? handle?.close()
        check(poll()?.interrupted == true, "transcript: you stopped the turn")
        check(fm.fileExists(atPath: file.path), "transcript: only read")
    }

    // MARK: A short name, without asking anyone

    do {
        let namer = ShortNamer()
        var asked = false
        namer.ask = { _ in asked = true; return nil }
        let waits = Session(id: "wait-name")
        waits.firstPrompt = "Please fix the login flow"
        waits.firstPromptAt = Date()
        namer.consider([waits])
        check(!asked, "short name: a message alone waits a moment for Claude Code's title")
        let noWords = Session(id: "no-words")
        namer.consider([noWords])
        check(!asked, "short name: nothing to make one from")
    }
}
