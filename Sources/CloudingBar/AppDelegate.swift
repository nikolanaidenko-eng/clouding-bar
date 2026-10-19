import AppKit

/// Wires everything together:
///  - messages from hooks, the status line and cloudingbar-tap arrive on the
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
    private lazy var tour = TourWindow(openSettings: { [weak self] in self?.openSettings() })
    private lazy var drawer = DrawerController(model: model)
    private let voice = VoiceInput()
    private let rightOption = RightOptionHold()
    private var voiceMessageShown = false
    private var voiceOfflineCache: (language: String, offline: Bool)?
    private var shownCardId: UUID?
    private let hotKeys = HotKeys()
    private var queue: [AppModel.QueueItem] = []
    private var queueSentAt: Date?
    /// Files dropped on the widget, by session id, waiting for its chat.
    private var attachments: [String: [String]] = [:]
    /// The Touch Bar shows the model picker or the subagents; either closes
    /// by itself when left alone.
    private enum BarPanel { case models, agents }
    private var barPanel: BarPanel?
    private var barPickerClose: DispatchWorkItem?
    /// Picked on the bar, until Claude confirms it.
    private var barPendingModel: String?
    private var barPendingEffort: String?
    private var branchCache: [String: (branch: String?, at: Date)] = [:]
    private let liveLimit = ClaudeAILimit()
    private var coworkSeen: [String: Date] = [:]
    private var coworkFolders: (list: [String], at: Date) = ([], .distantPast)

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
            // The pre-rename socket name, for taps and hooks started before.
            let old = Config.directory.appendingPathComponent("claudebar.sock").path
            unlink(old)
            symlink("cloudingbar.sock", old)
        } catch {
            NSLog("Clouding Bar: could not open the socket — \(error.localizedDescription)")
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
        model.showTour = { [weak self] in self?.showTour() }
        setUpClaudeCode()
        // The first time: connecting to Claude Code if it isn't yet, then
        // the tour, once everything is up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            if !self.model.claudeConnected && !self.config.setupDeclined { self.offerSetup() }
            if !self.config.tourShown {
                self.showTour()
                self.setConfig("tourShown", true)
            }
        }

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
        if store.codexAccount.expireIfNeeded() { setNeedsRefresh() }

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
        let account = active?.entrypoint == "codex" ? store.codexAccount : store.account
        bar.sessionPercent = account.sessionPercent
        bar.resetCountdown = account.resetCountdown
        bar.contextPercent = active?.contextPercent(windowOverride: config.contextWindowSize)
        bar.activity = activity(of: active)
        bar.quiet = config.doNotDisturb
        bar.shows = Set(config.touchBarShows)
        bar.modelLabel = ModelChoice.label(model: active?.modelName, effort: active?.effort)
        bar.modelAlias = barPendingModel ?? ModelChoice.alias(of: active?.model)
        bar.effort = barPendingEffort ?? active?.effort
        bar.agents = (active?.agents ?? []).map { a in
            ([a.type] + [a.task ?? a.doing].compactMap { $0 }).joined(separator: " · ")
        }

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
        // The model picker or the subagents, opened from their buttons; a
        // request takes the bar over and closes them.
        if let panel = barPanel {
            if currentRequest(active: active) == nil && active != nil {
                bar.mode = panel == .models ? .models : .agents
            } else {
                closeBarPicker()
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
        case .widget:
            DebugLog.tap("widget button")
            drawer.toggle()

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

        case .dictate:
            DebugLog.tap("dictate (bar)")
            model.voiceToggle()

        case .screenshot:
            DebugLog.tap("screenshot (bar)")
            takeScreenshot()

        case .compact:
            DebugLog.tap("compact (context warning)")
            active?.contextSnoozedUntil = 101 // until it drops below the threshold
            KeySender.type(config.compactCommand, pressReturn: true)
            setNeedsRefresh()

        case .models:
            // Codex switches models its own way: no Claude picker there.
            guard active?.entrypoint != "codex" else { NSSound.beep(); return }
            DebugLog.tap("model picker (bar)")
            barPanel = .models
            closeBarPickerLater()
            setNeedsRefresh()

        case .agents:
            DebugLog.tap("subagents (bar)")
            barPanel = .agents
            closeBarPickerLater(after: 20)
            setNeedsRefresh()

        case let .pickModel(alias):
            barPendingModel = alias
            switchModel("/model " + alias)
            closeBarPickerLater()

        case let .pickEffort(level):
            barPendingEffort = level
            switchModel("/effort " + level)
            closeBarPickerLater()

        case .closePanel:
            closeBarPicker()

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
        let islandItem = NSMenuItem(title: "Show or Hide the Island", action: #selector(toggleIsland), keyEquivalent: "")
        islandItem.target = self
        menu.addItem(islandItem)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let tourItem = NSMenuItem(title: "Take the Tour…", action: #selector(showTour), keyEquivalent: "")
        tourItem.target = self
        menu.addItem(tourItem)
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

    /// The Touch Bar character button's job, for Macs without one.
    @objc private func toggleIsland() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.drawer.toggle() }
    }

    @objc private func openSettings() {
        model.openAtLogin = LoginItem.isEnabled
        refreshSetupStatus()
        settings.show()
    }

    // MARK: - Connecting to Claude Code

    private func setUpClaudeCode() {
        Setup.updateHelpers() // the hook programs from this app, if they're newer
        refreshSetupStatus()
        model.connectClaude = { [weak self] in
            DebugLog.tap("connect to Claude Code")
            do {
                try Setup.connect()
                self?.model.setupMessage = nil
            } catch {
                self?.model.setupMessage = error.localizedDescription
            }
            self?.refreshSetupStatus()
        }
        model.connectCodex = { [weak self] in
            DebugLog.tap("connect to Codex")
            do {
                try Setup.connectCodex()
                self?.model.setupMessage = "Done. Now open Codex once and run /hooks to trust Clouding Bar's hooks — Codex runs them only after that."
            } catch {
                self?.model.setupMessage = "Codex's hooks.json couldn't be changed: \(error.localizedDescription)"
            }
            self?.refreshSetupStatus()
        }
        model.wrapVSCode = { [weak self] in
            DebugLog.tap("VS Code wrapper")
            do {
                try Setup.wrapVSCode()
                self?.model.setupMessage = "Done. New Claude chats in VS Code report the 5-hour limit."
            } catch {
                self?.model.setupMessage = "VS Code's settings couldn't be changed: \(error.localizedDescription)"
            }
            self?.refreshSetupStatus()
        }
    }

    private func refreshSetupStatus() {
        model.claudeConnected = Setup.isConnected
        model.hasCodex = Setup.hasCodex
        model.codexConnected = Setup.codexConnected
        model.hasVSCode = Setup.hasVSCode
        model.vscodeWrapped = Setup.vscodeWrapped
    }

    /// The first launch of a download: ask before touching Claude Code's settings.
    private func offerSetup() {
        let alert = NSAlert()
        alert.messageText = "Connect Clouding Bar to Claude Code?"
        alert.informativeText = "Clouding Bar adds a small hook and a status line to ~/.claude/settings.json, so Claude Code can tell it what it's doing and ask you through it. Your settings are merged, never replaced, and backed up first. Nothing leaves this Mac."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            model.connectClaude()
            if let message = model.setupMessage {
                let failed = NSAlert()
                failed.messageText = "Couldn't connect"
                failed.informativeText = message
                failed.runModal()
            }
        } else {
            setConfig("setupDeclined", true)
        }
    }

    @objc private func showTour() {
        DebugLog.tap("tour")
        tour.show()
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
        // A Codex session in front: Codex's own limits (a different account).
        let isCodex = active?.entrypoint == "codex"
        let account = isCodex ? store.codexAccount : store.account
        set(\.agentName, isCodex ? "Codex" : nil)
        set(\.sessionPercent, account.sessionPercent)
        set(\.resetShort, account.resetCountdown)
        set(\.resetLong, account.resetLong)
        set(\.limitAge, account.updatedAt.map { AppModel.ago($0) })
        set(\.weekPercent, account.weekPercent)
        set(\.weekReset, account.weekResetLong)
        set(\.contextPercent, active?.contextPercent(windowOverride: config.contextWindowSize))
        set(\.tokensIn, active?.tokensIn)
        set(\.tokensOut, active?.tokensOut)
        set(\.cost, active?.costUSD)
        set(\.modelName, active?.modelName)
        set(\.modelId, active?.model)
        set(\.effort, active?.effort)
        set(\.linesAdded, active?.linesAdded ?? 0)
        set(\.linesRemoved, active?.linesRemoved ?? 0)
        set(\.branch, config.metrics.contains("git") ? active?.cwd.flatMap(branch(at:)) : nil)
        set(\.agents, active?.runningAgents ?? 0)
        set(\.agentRows, (active?.agents ?? []).enumerated().map { i, a in
            AppModel.AgentRow(id: a.toolUseId ?? a.agentId ?? "\(i)", type: a.type, task: a.task, doing: a.doing,
                              elapsed: AppModel.elapsed(since: a.started), background: a.background)
        })
        set(\.isAPI, store.account.sessionPercent == nil && active?.costUSD != nil)
        set(\.queue, queue)
        set(\.attachments, active.flatMap { attachments[$0.id] } ?? [])
        set(\.chatInFront, active != nil && store.session(inWindow: frontTitle)?.id == active?.id)
        // The widget's buttons; the bar has its own switch for them.
        set(\.buttons, config.widgetHides.contains("buttons") ? [] : currentButtons(active))
        set(\.knownProjects, Array(Set(alive.compactMap(\.projectName))).sorted())

        let waitingIds = Set(requests.compactMap(\.sessionId))
        let rows = alive.map { s -> AppModel.SessionRow in
            let waiting = waitingIds.contains(s.id) || s.waitingNotice
            let state = waiting ? "Needs your OK"
                : s.activity == .work ? "Working · \(AppModel.duration(since: s.activitySince))"
                : "Idle · \(AppModel.duration(since: s.lastSeen))"
            // Where it runs, under its name: "Cowork · Idle · 12 min".
            let source: String
            switch s.entrypoint {
            case "cowork": source = "Cowork"
            case "claude-vscode": source = "VS Code"
            case "cli": source = "Terminal"
            case "claude-desktop": source = "Desktop"
            case "codex": source = "Codex"
            default: source = "Claude Code"
            }
            let status = source + " · " + state
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

    /// Brings that session's VS Code window to the front, then its own
    /// conversation (two can share a window). Only if no window shows the
    /// project does it open one — in a new window, never in place of yours.
    private func openSession(_ id: String) {
        guard let session = store.sessions[id] else { NSSound.beep(); return }
        DebugLog.tap("open session \(session.projectName ?? id)")
        if session.entrypoint == "cowork" {
            // Cowork lives in the Claude desktop app; it has no link to one task.
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first {
                app.activate(options: [])
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
            return
        }
        guard let cwd = session.cwd else { NSSound.beep(); return }
        let raised = session.projectName.map(raiseVSCodeWindow(showing:)) ?? false
        if !raised {
            guard let path = cwd.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "vscode://file" + path + "?windowId=_blank") else { NSSound.beep(); return }
            NSWorkspace.shared.open(url)
        }
        // The Claude extension opens a conversation by its id.
        guard session.entrypoint == "claude-vscode",
              let url = URL(string: "vscode://anthropic.claude-code/open?session=\(id)") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (raised ? 0.3 : 2.5)) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Finds the VS Code window whose title names the project and raises it.
    private func raiseVSCodeWindow(showing project: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.VSCode").first
        else { return false }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        for window in windows {
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
                  let text = title as? String else { continue }
            let parts = text.components(separatedBy: " — ").flatMap { $0.components(separatedBy: " - ") }
                .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " (Workspace)", with: "") }
            guard parts.contains(project) else { continue }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            app.activate(options: [])
            return true
        }
        return false
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
                KeySender.afterModifiersUp { self?.run(spec) }
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
            // Dropped files go along, after the words.
            let files = active.flatMap { self.attachments.removeValue(forKey: $0.id) } ?? []
            let full = ([text] + files.map(FileDrop.quoted)).filter { !$0.isEmpty }.joined(separator: " ")
            guard !full.isEmpty else { return }
            self.queue.append(.init(text: full, sessionId: active?.id, project: active?.projectName))
            DebugLog.tap("queue add (\(self.queue.count))" + (files.isEmpty ? "" : " with \(files.count) file(s)"))
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
        model.dropFiles = { [weak self] urls in self?.attach(urls) ?? false }
        model.removeAttachment = { [weak self] path in
            guard let self, let active = self.store.activeSession(windowTitle: self.frontTitle) else { return }
            self.attachments[active.id]?.removeAll { $0 == path }
            if self.attachments[active.id]?.isEmpty == true { self.attachments[active.id] = nil }
            self.refresh()
        }
        model.insertAttachments = { [weak self] in self?.insertAttachments() }
        model.setModel = { [weak self] alias in self?.switchModel("/model " + alias) }
        model.setEffort = { [weak self] level in self?.switchModel("/effort " + level) }
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

    /// /model or /effort, typed into the chat in front like a button's
    /// command. Claude Code switches at once and notes it in the transcript.
    private func switchModel(_ command: String) {
        DebugLog.tap(command)
        widget.releaseKey()
        KeySender.type(command, pressReturn: true)
        setNeedsRefresh()
    }

    /// The bar's picker closes 12 s after the last tap (the subagents, 20 s).
    private func closeBarPickerLater(after seconds: Double = 12) {
        barPickerClose?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.closeBarPicker() }
        barPickerClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func closeBarPicker() {
        barPickerClose?.cancel()
        guard barPanel != nil || barPendingModel != nil || barPendingEffort != nil else { return }
        barPanel = nil
        barPendingModel = nil
        barPendingEffort = nil
        setNeedsRefresh()
    }

    /// Files dropped on the widget wait for the session it shows.
    private func attach(_ urls: [URL]) -> Bool {
        guard let active = store.activeSession(windowTitle: frontTitle) else { return false }
        attachments = attachments.filter { store.sessions[$0.key] != nil } // sessions gone
        var list = attachments[active.id] ?? []
        for url in urls where !list.contains(url.path) { list.append(url.path) }
        attachments[active.id] = list
        DebugLog.tap("dropped \(urls.count) file(s) for \(active.projectName ?? active.id), \(list.count) waiting")
        refresh()
        return true
    }

    /// Insert: the paths go into the chat in front right away, without
    /// Enter, like a screenshot's. Only into that session's own chat.
    private func insertAttachments() {
        guard let active = store.activeSession(windowTitle: frontTitle),
              store.session(inWindow: frontTitle)?.id == active.id,
              let files = attachments.removeValue(forKey: active.id), !files.isEmpty else { NSSound.beep(); return }
        DebugLog.tap("insert \(files.count) file(s) into \(active.projectName ?? active.id)")
        widget.releaseKey()
        KeySender.type(files.map(FileDrop.quoted).joined(separator: " ") + " ")
        refresh()
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
            guard self.config.coworkMode != "off" else {
                self.model.coworkMessage = "Pick Thresholds or Every reply first."
                return
            }
            do {
                let zip = try Cowork.makePlugin(mode: self.config.coworkMode)
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
        liveLimit.onWeek = { [weak self] percent, resets in
            self?.store.account.applyWeek(used: percent, resetsAt: resets)
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

    /// Every folder that may hold Cowork's status: the ones connected in
    /// Claude Desktop (looked up every minute) plus one picked by hand.
    private var watchedCoworkFolders: [String] {
        if Date().timeIntervalSince(coworkFolders.at) > 60 {
            coworkFolders = (Cowork.connectedFolders(), Date())
        }
        var list = coworkFolders.list
        if let extra = config.coworkFolder, !list.contains(extra) { list.append(extra) }
        return list
    }

    /// Picks up new status lines from the Cowork plugin.
    private func readCowork() {
        guard config.coworkMode != "off" else { return }
        let folders = watchedCoworkFolders
        model.coworkFolders = folders.map { URL(fileURLWithPath: $0).lastPathComponent }
        var newest: Cowork.Status?
        for folder in folders {
            let url = Cowork.statusURL(folder: folder)
            guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  let status = Cowork.read(folder: folder) else { continue }
            // Inside Cowork's machine the folder name means nothing; the Mac
            // folder the status landed in is the project.
            let named = Cowork.Status(session: status.session, project: URL(fileURLWithPath: folder).lastPathComponent,
                                      contextTokens: status.contextTokens, contextWindow: status.contextWindow,
                                      model: status.model, time: status.time)
            if mtime != coworkSeen[folder] {
                coworkSeen[folder] = mtime
                store.apply(cowork: named)
                DebugLog.note("cowork status: \(status.project ?? "?") \(status.contextTokens) tokens")
            }
            if newest == nil || named.time > newest!.time { newest = named }
        }
        if let s = newest {
            let pct = Int((Double(s.contextTokens) / Double(max(1, s.contextWindow)) * 100).rounded())
            model.coworkLast = "\(AppModel.ago(s.time)) · \(s.project ?? "Cowork") \(pct)%"
        }
    }
}
