import AppKit

/// Wires everything together:
///  - messages from hooks, the status line and claudebar-tap arrive on the
///    socket and update the session model (SessionStore)
///  - permissions and questions wait here for an answer from the bar, and
///    go back to Claude's own UI the moment the bar can't answer them
///  - the Touch Bar takes over while an app from terminalBundleIDs is in
///    front and a Claude Code session is alive
///  - a menu bar item for status and quitting
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = Config.load()
    private let store = SessionStore()
    private var server: SocketServer?
    private lazy var touchBar = TouchBarController(fullWidth: config.hideControlStrip)
    private let typing = TypingInput()
    private let frontWindow = FrontWindow()
    private var statusItem: NSStatusItem?
    private let touchBarStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let touchBarToggleItem = NSMenuItem(title: "Show on Touch Bar", action: nil, keyEquivalent: "")

    private var requests: [PendingRequest] = []
    /// The question whose "Other…" answer is being typed.
    private var typingFor: PendingRequest?
    private var typingText = ""

    private var frontApp: NSRunningApplication?
    private var frontTitle: String?
    private var touchBarPresent = TouchBarDetector.hasTouchBar
    private var ticks = 0
    private var refreshQueued = false
    private var lastActiveId: String?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        setUpMenuBarItem()
        KeySender.ensureTrusted()
        DebugLog.tap("launch")

        store.load()
        store.onChange = { [weak self] in self?.setNeedsRefresh() }

        let server = SocketServer(path: Config.socketPath) { [weak self] message, responder in
            self?.handle(message, responder: responder)
        }
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("ClaudeBar: could not open the socket — \(error.localizedDescription)")
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontmostAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        frontApp = NSWorkspace.shared.frontmostApplication

        touchBar.barView.onAction = { [weak self] in self?.perform($0) }
        typing.onChange = { [weak self] text in self?.typingChanged(text) }
        typing.onSubmit = { [weak self] _ in self?.perform(.send) }
        typing.onCancel = { [weak self] in self?.stopTyping() }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.everySecond() }
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    // MARK: - Socket messages

    private func handle(_ message: Inbound, responder: Responder?) {
        store.apply(message)
        if let responder {
            accept(message, responder)
        } else if let id = message.sessionId {
            switch message.event {
            case "Stop", "UserPromptSubmit", "SessionEnd":
                // Claude moved on, so whatever it asked was answered elsewhere.
                for r in requests where r.sessionId == id { finish(r, "\(message.event ?? "") → dropped") }
            case "PostToolUse", "PostToolUseFailure":
                // The tool ran, so it was answered in Claude's own UI. (A
                // question's input comes back with the answers added.)
                for r in requests where r.sessionId == id && r.toolName == message.toolName
                    && (r.kind == .question || NSDictionary(dictionary: r.toolInput).isEqual(to: message.toolInput)) {
                    finish(r, "ran (answered in Claude) → dropped")
                }
            default:
                break
            }
        }
        setNeedsRefresh()
    }

    /// A permission or question arrived. Decide at once whether the bar can
    /// take it; if not, hand it straight back to Claude's own UI.
    private func accept(_ message: Inbound, _ responder: Responder) {
        guard let request = PendingRequest(message, responder: responder) else {
            responder.pass()
            return
        }
        let what = request.kind == .permission ? "permission \(request.toolName)" : "question"
        let hold: Double
        if request.hostAnswersInParallel {
            // VS Code shows its own dialog at the same time and takes the
            // first answer, so the bar can keep offering it at no cost.
            // Questions come from PermissionRequest here; their PreToolUse
            // goes straight through so nothing ever waits on the bar.
            hold = request.viaPermission ? config.permissionHoldSeconds : 0
        } else {
            // Claude may be waiting on us: only while the bar is in view,
            // and briefly. A question's PermissionRequest comes after its
            // PreToolUse was already handled.
            let blocking = request.kind == .permission || !request.viaPermission
            hold = blocking && barShouldShow ? config.questionHoldSeconds : 0
        }
        guard hold > 0 else {
            DebugLog.note("\(what) (\(request.viaPermission ? "PermissionRequest" : "PreToolUse")) → Claude")
            responder.pass()
            return
        }
        request.holdUntil = Date().addingTimeInterval(hold)
        responder.hold(hold)
        responder.onClose = { [weak self, weak request] in
            guard let self, let request else { return }
            self.finish(request, "\(what): hook closed (answered in Claude or stopped)", reply: false)
        }
        requests.append(request)
        DebugLog.note("\(what) on the bar, hold \(Int(hold)) s")
    }

    /// Takes a request off the bar. Unless `reply` is false, the hook is
    /// told "no decision" so Claude's own UI takes over.
    private func finish(_ request: PendingRequest, _ why: String, reply: Bool = true) {
        guard requests.contains(where: { $0 === request }) else { return }
        requests.removeAll { $0 === request }
        if reply { request.responder.pass() }
        if typingFor === request { stopTyping() }
        DebugLog.note(why)
        setNeedsRefresh()
    }

    /// Interaction renews a blocking request's hold.
    private func extendHold(_ request: PendingRequest) {
        guard !request.hostAnswersInParallel else { return }
        let hold = config.questionHoldSeconds
        request.holdUntil = Date().addingTimeInterval(hold)
        request.responder.hold(hold)
    }

    // MARK: - Timer

    private func everySecond() {
        ticks += 1
        if store.account.expireIfNeeded() { setNeedsRefresh() }

        let now = Date()
        for r in requests where (r.holdUntil ?? .distantFuture) <= now {
            finish(r, (r.kind == .question ? "question" : "permission") + " → Claude (hold over)")
        }
        if let app = frontApp, isTerminal(app) {
            frontWindow.readTitle(of: app) { [weak self] title in
                guard let self, title != self.frontTitle else { return }
                self.frontTitle = title
                self.setNeedsRefresh()
            }
        }
        if ticks % 2 == 0 { store.pollTranscripts() }
        if ticks % 10 == 0 {
            let gone = Set(store.prune())
            for r in requests where r.sessionId.map(gone.contains) ?? false { finish(r, "session gone → dropped") }
        }
        refresh() // the reset countdown ticks
    }

    // MARK: - Front app

    @objc private func frontmostAppChanged(_ note: Notification) {
        frontApp = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        frontTitle = nil
        refresh()
        if let app = frontApp, isTerminal(app) {
            frontWindow.readTitle(of: app) { [weak self] title in
                self?.frontTitle = title
                self?.setNeedsRefresh()
            }
        }
    }

    private func isTerminal(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier else { return false }
        return config.terminalBundleIDs.contains(id)
    }

    private var touchBarEnabled: Bool {
        switch config.touchBar {
        case "off": return false
        case "on": return true
        default: return touchBarPresent
        }
    }

    private var barShouldShow: Bool {
        guard touchBarEnabled, SystemModalTouchBar.isSupported,
              let app = frontApp, isTerminal(app) else { return false }
        return !store.alive.isEmpty
    }

    // MARK: - What the bar shows

    private func setNeedsRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    private func refresh() {
        refreshQueued = false
        guard barShouldShow else {
            // Claude may be waiting on these; a hidden bar can't answer them.
            for r in requests where !r.hostAnswersInParallel {
                finish(r, (r.kind == .question ? "question" : "permission") + " → Claude (bar hidden)")
            }
            touchBar.hide()
            return
        }

        let active = store.activeSession(windowTitle: frontTitle)
        if active?.id != lastActiveId {
            lastActiveId = active?.id
            DebugLog.note("active session: \(active?.projectName ?? "none") (\(active?.id.prefix(8) ?? "-"))")
        }
        var model = BarModel()
        model.buttons = config.effectiveButtons
        model.sessionPercent = store.account.sessionPercent
        model.resetCountdown = store.account.resetCountdown
        model.contextPercent = active?.contextPercent(windowOverride: config.contextWindowSize)
        model.activity = activity(of: active)

        if let request = currentRequest(active: active) {
            model.activity = .wait
            switch request.kind {
            case .permission:
                let s = request.summary
                model.mode = .permission(verb: s.verb, detail: s.detail)
            case .question:
                if typingFor === request {
                    model.mode = .typing(text: typingText)
                } else if let q = request.current {
                    model.mode = .question(text: q.text, options: q.options,
                                           multiSelect: q.multiSelect, picked: request.picked)
                }
            }
        } else if let active, let percent = model.contextPercent {
            if percent < config.contextWarnPercent {
                active.contextSnoozedUntil = nil // warn again next time it fills up
            } else if percent >= (active.contextSnoozedUntil ?? 0) {
                model.mode = .contextWarning
            }
        }
        touchBar.show(model)
    }

    /// The request the bar shows: the one being typed, else the active
    /// session's oldest, else the oldest of all.
    private func currentRequest(active: Session?) -> PendingRequest? {
        if let typingFor { return typingFor }
        return requests.first { $0.sessionId == active?.id } ?? requests.first
    }

    private func activity(of session: Session?) -> Activity {
        guard let session else { return .sleep }
        if session.waitingNotice || requests.contains(where: { $0.sessionId == session.id }) { return .wait }
        return session.activity
    }

    // MARK: - Taps

    private func perform(_ action: BarAction) {
        let active = store.activeSession(windowTitle: frontTitle)
        let request = currentRequest(active: active)

        switch action {
        case .esc:
            if let request {
                DebugLog.tap("esc → Claude's own UI (\(request.kind == .question ? "question" : "permission"))")
                finish(request, "handed to Claude by esc")
            } else {
                DebugLog.tap("esc")
                KeySender.tap(KeySender.escape)
            }

        case let .button(i):
            let buttons = config.effectiveButtons
            guard buttons.indices.contains(i) else { return }
            let spec = buttons[i]
            DebugLog.tap("button \(spec.label)")
            run(spec)

        case .allow, .always, .deny:
            guard let request, request.kind == .permission else { return }
            let name: String
            let output: [String: Any]
            switch action {
            case .allow: name = "allow"; output = PendingRequest.allow()
            case .always: name = "always"; output = request.always()
            default: name = "deny"; output = PendingRequest.deny()
            }
            DebugLog.tap("\(name) \(request.toolName)")
            answer(request, output)

        case let .option(i):
            guard let request, let q = request.current, q.options.indices.contains(i) else { return }
            if q.multiSelect {
                if request.picked.contains(i) { request.picked.remove(i) } else { request.picked.insert(i) }
                DebugLog.tap("toggle \(q.options[i])")
                extendHold(request)
                setNeedsRefresh()
            } else {
                DebugLog.tap("option \(q.options[i])")
                advance(request, with: q.options[i])
            }

        case .sendPicked:
            guard let request, let q = request.current, !request.picked.isEmpty else { return }
            let labels = request.picked.sorted().map { q.options[$0] }
            DebugLog.tap("send \(labels.joined(separator: ", "))")
            advance(request, with: labels.joined(separator: ", "))

        case .other:
            guard let request, request.kind == .question else { return }
            DebugLog.tap("other")
            typingFor = request
            typingText = ""
            typing.begin()
            extendHold(request)
            setNeedsRefresh()

        case .send:
            guard let request = typingFor else { return }
            let text = typingText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            DebugLog.tap("send typed answer")
            stopTyping()
            var answer = text
            if let q = request.current, q.multiSelect, !request.picked.isEmpty {
                answer = (request.picked.sorted().map { q.options[$0] } + [text]).joined(separator: ", ")
            }
            advance(request, with: answer)

        case .mic:
            DebugLog.tap("dictate")
            if let request = typingFor { extendHold(request) }
            typing.startDictation()

        case .compact:
            DebugLog.tap("compact (context warning)")
            active?.contextSnoozedUntil = 101 // until it drops below the threshold
            KeySender.type(config.compactCommand, pressReturn: true)
            setNeedsRefresh()

        case .later:
            DebugLog.tap("later (context warning)")
            if let active, let p = active.contextPercent(windowOverride: config.contextWindowSize) {
                active.contextSnoozedUntil = p + 5
            }
            setNeedsRefresh()
        }
    }

    private func run(_ spec: ButtonSpec) {
        switch spec.type {
        case .phrase, .command:
            KeySender.type(spec.value, pressReturn: true)
        case .key:
            if !KeySender.press(spec.value) { NSSound.beep() }
        case .link:
            guard let url = URL(string: spec.value) else { NSSound.beep(); return }
            NSWorkspace.shared.open(url)
        }
    }

    private func answer(_ request: PendingRequest, _ output: [String: Any]) {
        guard requests.contains(where: { $0 === request }) else { return }
        requests.removeAll { $0 === request }
        request.responder.answer(output)
        if typingFor === request { stopTyping() }
        DebugLog.note("answered from the bar")
        setNeedsRefresh()
    }

    /// Records the answer to the current question; sends them all after
    /// the last one.
    private func advance(_ request: PendingRequest, with answer: String) {
        if request.answerCurrent(answer) {
            self.answer(request, request.answerOutput())
        } else {
            extendHold(request)
            setNeedsRefresh()
        }
    }

    private func typingChanged(_ text: String) {
        typingText = text
        if let request = typingFor { extendHold(request) }
        setNeedsRefresh()
    }

    private func stopTyping() {
        typing.end()
        typingFor = nil
        typingText = ""
        setNeedsRefresh()
    }

    // MARK: - Menu bar

    private func setUpMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MascotView.menuBarImage()
        item.button?.setAccessibilityLabel("Clouding Bar")

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Clouding Bar", action: nil, keyEquivalent: ""))
        menu.addItem(touchBarStatusItem)
        touchBarToggleItem.target = self
        touchBarToggleItem.action = #selector(toggleTouchBar)
        menu.addItem(touchBarToggleItem)
        menu.addItem(.separator())
        let reload = NSMenuItem(title: "Reload Config", action: #selector(reloadConfig), keyEquivalent: "")
        reload.target = self
        menu.addItem(reload)
        let folder = NSMenuItem(title: "Open Config Folder", action: #selector(openConfigFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Clouding Bar",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        touchBarPresent = TouchBarDetector.hasTouchBar
        touchBarStatusItem.title = touchBarPresent ? "Touch Bar: found" : "Touch Bar: not found"
        touchBarToggleItem.state = touchBarEnabled ? .on : .off
    }

    @objc private func toggleTouchBar() {
        let value = touchBarEnabled ? "off" : (touchBarPresent ? "auto" : "on")
        config.touchBar = value
        Config.save("touchBar", value)
        DebugLog.tap("touchBar \(value)")
        refresh()
    }

    @objc private func reloadConfig() {
        config = Config.load()
        refresh()
    }

    @objc private func openConfigFolder() {
        NSWorkspace.shared.open(Config.directory)
    }
}
