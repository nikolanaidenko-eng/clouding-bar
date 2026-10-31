import AppKit

/// Crashes and errors the app caught (owner, 31.10): kept in
/// ~/.cloudingbar/reports, and offered once for each kind and version. Nothing
/// leaves this Mac until you've read the report, pasted it into a GitHub issue
/// in your browser and submitted it. There's no server.
final class Problems: NSObject {
    /// A line each about this Mac and how the app is set up.
    var about: () -> [String] = { [] }
    /// Whether to offer on its own (Settings → General → App).
    var offers: () -> Bool = { true }
    var stopOffers: () -> Void = {}

    private var card: NSPanel?
    /// What the card on screen is about.
    private var cardDetail: String?
    /// Told already since launch: one that goes on isn't kept over and over.
    private var told: Set<String> = []
    /// The report on screen, and what it's made of: the box redoes it.
    private var reportView: NSTextView?
    private var reportDetail: String?
    private let folder = Config.directory.appendingPathComponent("reports")
    private var offered: URL { folder.appendingPathComponent("offered") }
    private var crashSeen: URL { folder.appendingPathComponent("crash-seen") }
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }

    func start() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        DebugLog.onProblem = { [weak self] kind, text in
            DispatchQueue.main.async { self?.caught(kind: kind, text: text) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.lookForCrash() }
    }

    // MARK: Caught

    private func caught(kind: String, text: String) {
        guard told.insert(kind).inserted else { return }
        let detail = ProblemReport.scrub(text)
        keep(detail)
        let key = "\(version) \(kind)"
        let known = (try? String(contentsOf: offered, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        // Not with Do not disturb on: asked the next time it comes up.
        guard !known.contains(key), offers() else { return }
        try? (known + [key]).suffix(200).joined(separator: "\n").write(to: offered, atomically: true, encoding: .utf8)
        showCard(detail)
    }

    /// The newest crash macOS wrote down for this app since it last looked.
    /// The first time, only from now on: not one from long ago.
    private func lookForCrash() {
        let fm = FileManager.default
        let since = (try? fm.attributesOfItem(atPath: crashSeen.path))?[.modificationDate] as? Date
        fm.createFile(atPath: crashSeen.path, contents: nil)
        guard let since else { return }
        let reports = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = (try? fm.contentsOfDirectory(at: reports, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = files
            .filter { $0.lastPathComponent.hasPrefix("CloudingBar-") && $0.pathExtension == "ips" }
            .map { (url: $0, at: (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .filter { $0.at > since }
            .max { $0.at < $1.at }
        guard let newest, let ips = try? String(contentsOf: newest.url, encoding: .utf8),
              let crash = ProblemReport.crash(ips: ips) else { return }
        DebugLog.note("problem: a crash found in the system's reports")
        caught(kind: crash.kind, text: crash.text)
    }

    /// On this Mac, the last 20.
    private func keep(_ detail: String) {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? detail.write(to: folder.appendingPathComponent(stamp + ".txt"), atomically: true, encoding: .utf8)
        for old in savedReports().dropFirst(20) { try? FileManager.default.removeItem(at: old) }
    }

    /// Newest first (their names sort by time).
    private func savedReports() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "txt" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    // MARK: Offered

    /// A small card in the screen's corner: it takes no focus from what you're typing.
    private func showCard(_ detail: String) {
        card?.orderOut(nil)
        cardDetail = detail
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 92),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false

        let back = NSVisualEffectView(frame: panel.contentRect(forFrameRect: panel.frame))
        back.material = .hudWindow
        back.state = .active
        back.wantsLayer = true
        back.layer?.cornerRadius = 12
        back.layer?.masksToBounds = true

        let label = NSTextField(wrappingLabelWithString: "Clouding Bar caught a problem. It's kept on this Mac; nothing goes unless you send it.")
        label.font = .systemFont(ofSize: 12)
        label.frame = NSRect(x: 14, y: 42, width: 292, height: 40)
        let review = NSButton(title: "Review…", target: self, action: #selector(reviewFromCard))
        review.bezelStyle = .rounded
        review.keyEquivalent = ""
        let later = NSButton(title: "Not Now", target: self, action: #selector(closeCard))
        later.bezelStyle = .rounded
        review.sizeToFit()
        later.sizeToFit()
        review.frame.origin = NSPoint(x: 320 - 12 - review.frame.width, y: 10)
        later.frame.origin = NSPoint(x: review.frame.minX - 6 - later.frame.width, y: 10)
        [label, review, later].forEach(back.addSubview)
        panel.contentView = back

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 12, y: visible.maxY - panel.frame.height - 12))
        }
        panel.orderFrontRegardless()
        card = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self, weak panel] in
            if let panel, self?.card === panel { self?.closeCard() }
        }
    }

    @objc private func closeCard() {
        card?.orderOut(nil)
        card = nil
    }

    @objc private func reviewFromCard() {
        let detail = cardDetail
        closeCard()
        review(detail: detail, offered: true)
    }

    /// From the menu: anytime, a problem or not (a crash report wouldn't have
    /// caught Cowork showing nothing).
    func reportNow() {
        review(detail: lastDetail(), offered: false)
    }

    /// The last one kept, if it's from today.
    private func lastDetail() -> String? {
        guard let file = savedReports().first,
              let at = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              Date().timeIntervalSince(at) < 86400 else { return nil }
        return try? String(contentsOf: file, encoding: .utf8)
    }

    /// All that would go, in full, for you to change; you're the one who sends it.
    private func review(detail: String?, offered: Bool) {
        reportDetail = detail
        let alert = NSAlert()
        alert.messageText = "Report a problem"
        alert.informativeText = "This is all of it: change or delete anything. Chats' names and words are left out. Copy and Open GitHub puts it on your clipboard and opens a new public issue in your browser: paste it there and submit. Nothing goes until you do."
        alert.addButton(withTitle: "Copy and Open GitHub…")
        alert.addButton(withTitle: "Copy")
        alert.addButton(withTitle: "Cancel")
        let (accessory, view) = reportBox(report(claudeAI: false))
        reportView = view
        alert.accessoryView = accessory
        if offered {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't offer reports on their own"
        }
        NSApp.activate(ignoringOtherApps: true)
        let answer = alert.runModal()
        if alert.suppressionButton?.state == .on { stopOffers() }
        if answer == .alertFirstButtonReturn || answer == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(view.string, forType: .string)
        }
        if answer == .alertFirstButtonReturn, let url = ProblemReport.issueURL(repo: UpdateCheck.repo, version: version) {
            NSWorkspace.shared.open(url)
        }
        reportView = nil
    }

    private func report(claudeAI: Bool) -> String {
        let log = (try? String(contentsOf: Config.directory.appendingPathComponent("debug.log"), encoding: .utf8)) ?? ""
        let lines = about().filter { claudeAI || !$0.contains("claude.ai") }
        return ProblemReport.text(detail: reportDetail, about: lines, log: ProblemReport.safeLog(log, claudeAI: claudeAI), claudeAI: claudeAI)
    }

    /// The report's text, and the box that adds what's about claude.ai.
    func reportBox(_ text: String) -> (NSView, NSTextView) {
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 306))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 26, width: 520, height: 280))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let view = NSTextView(frame: scroll.bounds)
        view.autoresizingMask = [.width]
        view.isVerticallyResizable = true
        view.isRichText = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        view.string = text
        scroll.documentView = view
        let include = NSButton(checkboxWithTitle: "Include claude.ai details (public: shows you signed in to it)", target: self, action: #selector(includeClaudeAI(_:)))
        include.frame = NSRect(x: 0, y: 0, width: 520, height: 18)
        box.addSubview(scroll)
        box.addSubview(include)
        return (box, view)
    }

    /// Made again from the start: what you'd changed in it goes.
    @objc private func includeClaudeAI(_ box: NSButton) {
        reportView?.string = report(claudeAI: box.state == .on)
    }
}
