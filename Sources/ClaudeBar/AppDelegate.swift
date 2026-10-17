import AppKit

/// Wires everything together:
///  - messages from hooks, the status line and claudebar-tap arrive on the
///    socket and update the session model (SessionStore)
///  - permissions and questions wait here for an answer from the bar, and
///    go back to Claude's own UI the moment the bar can't answer them
///  - the Touch Bar takes over while an app from terminalBundleIDs is in
///    front and a Claude Code session is alive
///  - the floating widget and the settings window read AppModel, which
///    refresh() fills from the same state
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
    private let templatesItem = NSMenuItem(title: "Templates", action: nil, keyEquivalent: "")

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
    /// A session whose request was picked in the widget's sessions list.
    private var preferredRequestSession: String?

    private let model = AppModel()
    private lazy var widget = WidgetController(model: model)
    private lazy var settings = SettingsWindow(model: model)
    private let voice = VoiceInput()
    private let rightOption = RightOptionHold()
    private var voiceMessageShown = false
    private var voiceOfflineCache: (language: String, offline: Bool)?
    private var shownCardId: UUID?
    private let hotKeys = HotKeys()
    private var queue: [AppModel.QueueItem] = []
    private var queueSentAt: Date?
    private var branchCache: [String: (branch: String?, at: Date)] = [:]
    private let liveLimit = ClaudeAILimit()
    private var coworkSeen: Date?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        setUpMenuBarItem()
        setUpMainMenu()
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

        setUpModel()
        setUpVoice()
        loadQueue()
        setUpCowork()

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
            hold = blocking && canShowRequests ? config.questionHoldSeconds : 0
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
        if ticks % 2 == 0 {
            store.pollTranscripts()
            readCowork()
        }
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

    /// Somewhere a request can be answered: the Touch Bar or the widget.
    private var canShowRequests: Bool {
        barShouldShow || (config.widget && widget.isVisible)
    }

    // MARK: - What the bar shows

    private func setNeedsRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    private func refresh() {
        refreshQueued = false
        let active = store.activeSession(windowTitle: frontTitle)
        if active?.id != lastActiveId {
            lastActiveId = active?.id
            DebugLog.note("active session: \(active?.projectName ?? "none") (\(active?.id.prefix(8) ?? "-"))")
        }

        if config.widget { widget.show() } else { widget.hide() }
        updateModel(active: active)
        widget.update()
        updateHotKeys(active)
        dispatchQueue()

        guard barShouldShow else {
            if typingFor != nil { stopTyping() }
            if !canShowRequests {
                // Claude may be waiting on these, and nothing can answer them.
                for r in requests where !r.hostAnswersInParallel {
                    finish(r, (r.kind == .question ? "question" : "permission") + " → Claude (bar and widget hidden)")
                }
            }
            touchBar.hide()
            return
        }

        var bar = BarModel()
        bar.buttons = currentButtons(active)
        bar.sessionPercent = store.account.sessionPercent
        bar.resetCountdown = store.account.resetCountdown
        bar.contextPercent = active?.contextPercent(windowOverride: config.contextWindowSize)
        bar.activity = activity(of: active)
        bar.quiet = config.doNotDisturb

        if let request = currentRequest(active: active) {
            bar.activity = .wait
            switch request.kind {
            case .permission:
                let s = request.summary
                bar.mode = .permission(verb: s.verb, detail: s.detail)
            case .question:
                if typingFor === request {
                    bar.mode = .typing(text: typingText)
                } else if let q = request.current {
                    bar.mode = .question(text: q.text, options: q.options,
                                         multiSelect: q.multiSelect, picked: request.picked)
                }
            }
        } else if let active, let percent = bar.contextPercent {
            if percent < config.contextWarnPercent {
                active.contextSnoozedUntil = nil // warn again next time it fills up
            } else if percent >= (active.contextSnoozedUntil ?? 0) {
                if config.autoCompact {
                    autoCompact(active)
                } else if config.contextWarning && !config.doNotDisturb {
                    bar.mode = .contextWarning
                }
            }
        }
        touchBar.show(bar)
    }

    private func currentButtons(_ active: Session?) -> [ButtonSpec] {
        config.buttons(for: active?.projectName)
    }

    /// The request the bar shows: the one being typed, else the active
    /// session's oldest, else the oldest of all.
    private func currentRequest(active: Session?) -> PendingRequest? {
        if let typingFor { return typingFor }
        if let id = preferredRequestSession, let r = requests.first(where: { $0.sessionId == id }) { return r }
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
            let buttons = currentButtons(active)
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
        widget.releaseKey() // keystrokes go to your editor, not the widget
        switch spec.type {
        case .screenshot:
            takeScreenshot()
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
        menu.addItem(templatesItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let resetItem = NSMenuItem(title: "Reset Widget Position", action: #selector(resetWidgetPosition), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)
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

    /// The app has no menu bar of its own, but text fields (the settings
    /// window, the widget) only get ⌘V, ⌘C, ⌘X, ⌘A, ⌘Z through an Edit
    /// menu; ⌘W closes the settings window.
    private func setUpMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit Clouding Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    func menuWillOpen(_ menu: NSMenu) {
        touchBarPresent = TouchBarDetector.hasTouchBar
        touchBarStatusItem.title = touchBarPresent ? "Touch Bar: found" : "Touch Bar: not found"
        touchBarToggleItem.state = touchBarEnabled ? .on : .off
        // Template phrases, typed into the app in front without Enter.
        templatesItem.isHidden = !config.templatesEnabled || config.templates.isEmpty
        let sub = NSMenu()
        for t in config.templates {
            let item = NSMenuItem(title: t, action: #selector(menuTemplate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = t
            sub.addItem(item)
        }
        templatesItem.submenu = sub
    }

    @objc private func menuTemplate(_ sender: NSMenuItem) {
        guard let t = sender.representedObject as? String else { return }
        // Let the menu close and focus return to the app in front first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.insertTemplate(t) }
    }

    @objc private func toggleTouchBar() {
        let value = touchBarEnabled ? "off" : (touchBarPresent ? "auto" : "on")
        config.touchBar = value
        Config.save("touchBar", value)
        DebugLog.tap("touchBar \(value)")
        refresh()
    }

    @objc private func openSettings() {
        model.openAtLogin = LoginItem.isEnabled
        settings.show()
    }

    @objc private func resetWidgetPosition() {
        setConfig("widgetPosition", NSNull())
        widget.resetPosition()
    }

    @objc private func reloadConfig() {
        config = Config.load()
        refresh()
    }

    @objc private func openConfigFolder() {
        NSWorkspace.shared.open(Config.directory)
    }

    // MARK: - Widget and settings

    private func setUpModel() {
        model.perform = { [weak self] in self?.perform($0) }
        model.answerText = { [weak self] in self?.answerTyped($0) }
        model.openSession = { [weak self] in self?.openSession($0) }
        model.showRequest = { [weak self] id in
            self?.preferredRequestSession = id
            self?.refresh()
        }
        model.setConfig = { [weak self] key, value in self?.setConfig(key, value) }
        model.setOpenAtLogin = { [weak self] on in
            LoginItem.set(on)
            self?.model.openAtLogin = LoginItem.isEnabled
        }
        model.voice = { [weak self] down in down ? self?.voiceBegin() : self?.voice.stop() }
        model.voiceToggle = { [weak self] in
            guard let self else { return }
            if self.model.listening {
                self.voice.stop()
            } else {
                // Tap-to-talk: ends by itself after a 2 s pause.
                self.voiceBegin(stopAfterPause: 2)
            }
        }
        model.resetWidgetPosition = { [weak self] in self?.resetWidgetPosition() }
        model.openAtLogin = LoginItem.isEnabled
    }

    private func setConfig(_ key: String, _ value: Any) {
        Config.save(key, value)
        config = Config.load()
        DebugLog.note("setting \(key) changed")
        refresh()
    }

    /// Fills AppModel; only what changed is assigned, so SwiftUI redraws
    /// only what it must.
    private func updateModel(active: Session?) {
        let m = model
        func set<T: Equatable>(_ key: ReferenceWritableKeyPath<AppModel, T>, _ value: T) {
            if m[keyPath: key] != value { m[keyPath: key] = value }
        }
        let request = currentRequest(active: active)
        let alive = store.alive
        set(\.config, config)
        set(\.touchBarPresent, touchBarPresent)
        set(\.hasNotch, WidgetController.hasNotch(NSScreen.screens.first))
        set(\.hasSession, !alive.isEmpty)
        set(\.activity, request != nil ? .wait : activity(of: active))
        set(\.project, active?.projectName)
        set(\.sessionPercent, store.account.sessionPercent)
        set(\.resetShort, store.account.resetCountdown)
        set(\.resetLong, store.account.resetLong)
        set(\.limitAge, store.account.updatedAt.map { AppModel.ago($0) })
        set(\.contextPercent, active?.contextPercent(windowOverride: config.contextWindowSize))
        set(\.tokensIn, active?.tokensIn)
        set(\.tokensOut, active?.tokensOut)
        set(\.cost, active?.costUSD)
        set(\.modelName, active?.modelName)
        set(\.effort, active?.effort)
        set(\.linesAdded, active?.linesAdded ?? 0)
        set(\.linesRemoved, active?.linesRemoved ?? 0)
        set(\.branch, config.metrics.contains("git") ? active?.cwd.flatMap(branch(at:)) : nil)
        set(\.agents, active?.runningAgents ?? 0)
        set(\.isAPI, store.account.sessionPercent == nil && active?.costUSD != nil)
        set(\.queue, queue)
        set(\.buttons, currentButtons(active))
        set(\.knownProjects, Array(Set(alive.compactMap(\.projectName))).sorted())

        let waitingIds = Set(requests.compactMap(\.sessionId))
        let rows = alive.map { s -> AppModel.SessionRow in
            let waiting = waitingIds.contains(s.id) || s.waitingNotice
            let status = waiting ? "Needs your OK"
                : s.activity == .work ? "Working · \(AppModel.duration(since: s.activitySince))"
                : "Idle · \(AppModel.duration(since: s.lastSeen))"
            return AppModel.SessionRow(id: s.id, name: s.projectName ?? "Claude", status: status,
                                       activity: waiting ? .wait : s.activity,
                                       context: s.contextPercent(windowOverride: config.contextWindowSize),
                                       waiting: waiting)
        }
        .sorted { a, b in a.waiting != b.waiting ? a.waiting : a.name < b.name }
        set(\.sessions, rows)

        let card = request.map(card(for:))
        if card?.id != shownCardId {
            shownCardId = card?.id
            m.otherDraft = ""
        }
        set(\.request, card)

        if voiceOfflineCache?.language != config.voiceLanguage {
            voiceOfflineCache = (config.voiceLanguage, VoiceInput.worksOffline(config.voiceLanguage))
        }
        set(\.voiceOffline, voiceOfflineCache?.offline ?? true)
    }

    private func card(for r: PendingRequest) -> AppModel.RequestCard {
        let project = r.sessionId.flatMap { store.sessions[$0]?.projectName }
        var card = AppModel.RequestCard(id: r.id, kind: r.kind == .permission ? .permission : .question, project: project)
        if r.kind == .permission {
            let s = r.summary
            card.verb = s.verb
            // The widget has room for the whole command.
            card.detail = r.toolName == "Bash" ? (r.toolInput["command"] as? String ?? s.detail) : s.detail
        } else if let q = r.current {
            card.question = q.text
            card.options = q.options
            card.descriptions = q.descriptions
            card.multiSelect = q.multiSelect
            card.picked = r.picked
            card.index = r.index
            card.count = r.questions.count
        }
        return card
    }

    /// "Other" answered in the widget.
    private func answerTyped(_ text: String) {
        let active = store.activeSession(windowTitle: frontTitle)
        guard let request = currentRequest(active: active), request.kind == .question else { return }
        DebugLog.tap("widget: send typed answer")
        var answer = text
        if let q = request.current, q.multiSelect, !request.picked.isEmpty {
            answer = (request.picked.sorted().map { q.options[$0] } + [text]).joined(separator: ", ")
        }
        model.otherDraft = ""
        advance(request, with: answer)
    }

    private func openSession(_ id: String) {
        guard store.sessions[id]?.entrypoint != "cowork", let cwd = store.sessions[id]?.cwd,
              let path = cwd.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "vscode://file" + path) else { NSSound.beep(); return }
        DebugLog.tap("open session \(store.sessions[id]?.projectName ?? id)")
        NSWorkspace.shared.open(url)
    }

    // MARK: - Voice

    private func setUpVoice() {
        rightOption.onStart = { [weak self] in self?.voiceBegin() }
        rightOption.onEnd = { [weak self] in self?.voice.stop() }
        rightOption.start()
        voice.onPartial = { [weak self] text in self?.model.heard = text }
        voice.onLog = { DebugLog.note("voice: \($0)") }
        voice.onMessage = { [weak self] message in
            guard let self else { return }
            DebugLog.note(message)
            self.voiceMessageShown = true
            self.model.heard = message
        }
        voice.onFinal = { [weak self] text in
            guard let self else { return }
            if let text {
                self.deliverVoice(text)
            } else if !self.voiceMessageShown {
                DebugLog.note("voice: nothing recognized")
                self.voiceMessageShown = true
                self.model.heard = "Didn't catch that — hold right ⌥ and speak"
            }
            if self.voiceMessageShown {
                // Leave the message up long enough to read.
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    self.voiceMessageShown = false
                    self.model.listening = false
                    self.model.heard = ""
                    self.widget.update()
                }
            } else {
                self.model.listening = false
                self.model.heard = ""
                self.widget.update()
            }
        }
    }

    private func voiceBegin(stopAfterPause: TimeInterval? = nil) {
        guard !voice.isRunning, !model.listening else { return }
        DebugLog.tap(stopAfterPause == nil ? "voice (hold ⌥)" : "voice (mic)")
        voice.stopAfterPause = stopAfterPause
        model.listening = true
        model.heard = ""
        widget.update()
        if let request = typingFor ?? currentRequest(active: nil), request.kind == .question { extendHold(request) }
        voice.start(language: config.voiceLanguage, allowServer: config.voiceAllowServer)
    }

    /// Dictated text goes where you'd type it: the bar's answer field, the
    /// widget's "Other" field, or else the app in front — without Enter.
    private func deliverVoice(_ text: String) {
        if typing.isActive {
            typing.insert(text)
        } else if model.request?.kind == .question, widget.state.mode == .panel {
            model.otherDraft = model.otherDraft.isEmpty ? text : model.otherDraft + " " + text
        } else {
            widget.releaseKey()
            KeySender.type(text)
        }
        DebugLog.note("voice: \(text.count) characters into " + (typing.isActive ? "the Touch Bar answer" : model.request?.kind == .question && widget.state.mode == .panel ? "the widget's Other field" : NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"))
    }

    // MARK: - Stage 3: hotkeys, templates, queue, auto-compact, screenshot

    /// Global shortcuts for the buttons the bar shows now.
    private func updateHotKeys(_ active: Session?) {
        let shortcuts = currentButtons(active).compactMap { spec -> (combo: String, action: () -> Void)? in
            guard let combo = spec.hotkey else { return nil }
            return (combo, { [weak self] in
                DebugLog.tap("hotkey \(spec.label)")
                self?.run(spec)
            })
        }
        hotKeys.set(shortcuts)
    }

    /// {project}, {branch}, {clipboard}, {date} filled in.
    private func expand(_ template: String) -> String {
        let active = store.activeSession(windowTitle: frontTitle)
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd"
        return template
            .replacingOccurrences(of: "{project}", with: active?.projectName ?? "")
            .replacingOccurrences(of: "{branch}", with: active?.cwd.flatMap(branch(at:)) ?? "")
            .replacingOccurrences(of: "{clipboard}", with: NSPasteboard.general.string(forType: .string) ?? "")
            .replacingOccurrences(of: "{date}", with: date.string(from: Date()))
    }

    private func insertTemplate(_ template: String) {
        DebugLog.tap("template")
        widget.releaseKey()
        KeySender.type(expand(template)) // no Enter: read it over first
    }

    private func branch(at cwd: String) -> String? {
        if let c = branchCache[cwd], Date().timeIntervalSince(c.at) < 5 { return c.branch }
        let b = Git.branch(at: cwd)
        branchCache[cwd] = (b, Date())
        return b
    }

    /// Context over the threshold, Claude idle, its window in front: /compact.
    private func autoCompact(_ session: Session) {
        guard session.activity == .sleep, !session.waitingNotice,
              !requests.contains(where: { $0.sessionId == session.id }),
              store.session(inWindow: frontTitle)?.id == session.id,
              Date().timeIntervalSince(session.activitySince) > 2 else { return }
        session.contextSnoozedUntil = 101 // until it drops below the threshold
        DebugLog.note("auto-compact \(session.projectName ?? session.id)")
        widget.releaseKey()
        KeySender.type(config.compactCommand, pressReturn: true)
    }

    private var queueURL: URL { Config.directory.appendingPathComponent("queue.json") }

    private func loadQueue() {
        if let data = try? Data(contentsOf: queueURL),
           let items = try? JSONDecoder().decode([AppModel.QueueItem].self, from: data) {
            queue = items
        }
        model.addToQueue = { [weak self] text in
            guard let self else { return }
            let active = self.store.activeSession(windowTitle: self.frontTitle)
            self.queue.append(.init(text: text, sessionId: active?.id, project: active?.projectName))
            DebugLog.tap("queue add (\(self.queue.count))")
            self.saveQueue()
            self.refresh()
        }
        model.removeFromQueue = { [weak self] id in
            self?.queue.removeAll { $0.id == id }
            self?.saveQueue()
            self?.refresh()
        }
        model.insertTemplate = { [weak self] in self?.insertTemplate($0) }
        model.takeScreenshot = { [weak self] in self?.takeScreenshot() }
        model.changeModel = { [weak self] in
            DebugLog.tap("change model")
            self?.widget.releaseKey()
            KeySender.type("/model", pressReturn: true)
        }
    }

    private func saveQueue() {
        if let data = try? JSONEncoder().encode(queue) { try? data.write(to: queueURL, options: .atomic) }
    }

    /// Sends the next queued request once its session has finished a
    /// reply and its window is in front (it's typed, like a button).
    private func dispatchQueue() {
        guard config.taskQueue, let next = queue.first else { return }
        guard let session = next.sessionId.flatMap({ store.sessions[$0] }) else {
            queue.removeFirst() // its session is gone
            saveQueue()
            return
        }
        guard session.activity == .sleep, !session.waitingNotice,
              !requests.contains(where: { $0.sessionId == session.id }),
              store.session(inWindow: frontTitle)?.id == session.id,
              Date().timeIntervalSince(session.activitySince) > 1.5,
              Date().timeIntervalSince(queueSentAt ?? .distantPast) > 10 else { return }
        queue.removeFirst()
        saveQueue()
        queueSentAt = Date()
        DebugLog.note("queue: sent to \(session.projectName ?? session.id), \(queue.count) left")
        widget.releaseKey()
        KeySender.type(next.text, pressReturn: true)
    }

    private func takeScreenshot() {
        DebugLog.tap("screenshot")
        widget.releaseKey()
        Screenshot.take { [weak self] path in
            guard let path else { return } // cancelled
            self?.widget.releaseKey()
            KeySender.type(path + " ")
            DebugLog.note("screenshot → path typed")
        }
    }

    // MARK: - Cowork and the claude.ai limit

    private func setUpCowork() {
        model.chooseCoworkFolder = { [weak self] in
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Use This Folder"
            panel.message = "Pick the folder you connected in Cowork"
            NSApp.activate(ignoringOtherApps: true)
            if panel.runModal() == .OK, let url = panel.url {
                self?.setConfig("coworkFolder", url.path)
            }
        }
        model.makeCoworkPlugin = { [weak self] in
            guard let self else { return }
            guard let folder = self.config.coworkFolder, self.config.coworkMode != "off" else {
                self.model.coworkMessage = "Pick a mode and the connected folder first."
                return
            }
            do {
                let zip = try Cowork.makePlugin(mode: self.config.coworkMode, folder: folder)
                NSWorkspace.shared.activateFileViewerSelecting([zip])
                self.model.coworkMessage = "Saved to Downloads. Upload clouding-bar-cowork.zip in Claude Desktop → Settings → Plugins."
                DebugLog.note("cowork plugin made (\(self.config.coworkMode))")
            } catch {
                self.model.coworkMessage = "Couldn't make it: \(error.localizedDescription)"
            }
        }
        liveLimit.onUpdate = { [weak self] percent, resets in
            self?.store.account.apply(used: percent, resetsAt: resets)
            self?.setNeedsRefresh()
        }
        liveLimit.onState = { [weak self] state in
            self?.model.liveLimitState = state
            DebugLog.note("claude.ai limit: \(state)")
        }
        model.saveLiveKey = { [weak self] key in
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, ClaudeAILimit.saveKey(trimmed) else { return }
            DebugLog.tap("claude.ai limit on")
            self?.model.hasLiveKey = true
            self?.model.liveLimitState = "Checking…"
            self?.liveLimit.start()
        }
        model.removeLiveKey = { [weak self] in
            ClaudeAILimit.deleteKey()
            self?.liveLimit.stop()
            self?.model.hasLiveKey = false
            self?.model.liveLimitState = "Off"
            DebugLog.tap("claude.ai limit off, key removed")
        }
        model.hasLiveKey = ClaudeAILimit.hasKey
        if model.hasLiveKey {
            model.liveLimitState = "Checking…"
            liveLimit.start()
        }
    }

    /// Picks up a new status line from the Cowork plugin.
    private func readCowork() {
        guard config.coworkMode != "off", let folder = config.coworkFolder else { return }
        let url = Cowork.statusURL(folder: folder)
        guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return }
        if mtime != coworkSeen, let status = Cowork.read(folder: folder) {
            coworkSeen = mtime
            store.apply(cowork: status)
            DebugLog.note("cowork status: \(status.project ?? "?") \(status.contextTokens) tokens")
        }
        if let s = Cowork.read(folder: folder) {
            let pct = Int((Double(s.contextTokens) / Double(max(1, s.contextWindow)) * 100).rounded())
            model.coworkLast = "\(AppModel.ago(s.time)) · \(s.project ?? "Cowork") \(pct)%"
        }
    }
}
