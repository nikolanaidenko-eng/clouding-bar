import AppKit

/// Where it all meets:
///  - messages from hooks, the status line and cloudingbar-tap arrive on the
///    socket and update the session model (SessionStore)
///  - permissions and questions wait here for an answer from the bar, and
///    go back to Claude's own UI the moment the bar can't answer them
///  - the Touch Bar takes over while an app from terminalBundleIDs is in
///    front and a Claude Code session is alive
///  - the floating widget and the settings window read AppModel, which
///    refresh() fills from the same state
///  - Cloud in the menu bar: settings, the tour, updates, quitting
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var config = Config.load()
    private let store = SessionStore()
    private var server: SocketServer?
    private let touchBar = TouchBarController()
    private let typing = TypingInput()
    private let frontWindow = FrontWindow()
    /// Cloud in the menu bar.
    private var menuBarCloud: NSStatusItem?
    private let touchBarStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let updateItem = NSMenuItem(title: "Check for Updates…", action: nil, keyEquivalent: "")
    private let problems = Problems()
    private var localCoworkTimer: Timer?
    private let updater = Updater()
    private let touchBarToggleItem = NSMenuItem(title: "Show on Touch Bar", action: nil, keyEquivalent: "")
    private let templatesItem = NSMenuItem(title: "Commands", action: nil, keyEquivalent: "")

    private var requests: [PendingRequest] = []
    /// The question whose "Other…" answer is being typed.
    private var typingFor: PendingRequest?
    private var typingText = ""

    private var frontApp: NSRunningApplication?
    private var frontTitle: String?
    /// Terminal or iTerm in front: the tty of its tab in front.
    private var frontTTY: String?
    private var touchBarPresent = TouchBarDetector.hasTouchBar
    private var ticks = 0
    private var refreshQueued = false
    private var lastActiveId: String?
    /// The request on show and since when: a tap or key answers only the one
    /// that's been there a moment — not one that took its place as the
    /// finger came down.
    private var requestShown: (id: UUID?, at: Date) = (nil, .distantPast)
    /// Following the chat at work (owner's request, 20.10): after the chat
    /// shown finished, "done" for a moment (`handoff`), then the one still
    /// working (`followWorking`). `front` is what was in front then: going
    /// to another window or tab, or picking a chat, ends it.
    private var handoff: (doneId: String, nextId: String, until: Date, front: String)?
    private var followWorking: (id: String, front: String)?
    private var lastShown: (id: String, activity: Activity)?
    /// The chat picked in the widget, and when: it's followed until you
    /// go to another chat yourself.
    private var pickedSessionId: String?
    private var pickedAt = Date.distantPast
    /// A session whose request was picked in the widget's sessions list.
    private var preferredRequestSession: String?

    private let model = AppModel()
    private lazy var widget = WidgetController(model: model)
    private lazy var settings = SettingsWindow(model: model)
    /// Long questions put shorter for the Touch Bar (macOS 26, on this Mac).
    private let shortener = ModelShortener(.question)
    /// A finished chat's answer retold in a sentence, the same way (AnswerPreview).
    private let answerShortener = ModelShortener(.answer)
    /// Short names for chats (owner, 27.10).
    private let namer = ShortNamer()
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
    private enum BarPanel { case models, agents, chats, templates }
    /// Writing to the chat from the bar (Write); the words wait in
    /// `composeDraft` while a request has the bar.
    private var composing = false
    private var composeDraft = ""
    /// The chat the bar's message line is written for, picked from its chats
    /// list — not the one followed (owner, 27.10). Kept while its words wait
    /// (a request took the bar, back at the list to pick another).
    private var composeTo: String?
    /// The templates were opened from the chat field: a pick goes into it.
    private var templatesIntoDraft = false
    private var barPanel: BarPanel?
    private var barPickerClose: DispatchWorkItem?
    /// Picked on the bar, until Claude confirms it.
    private var barPendingModel: String?
    private var barPendingEffort: String?
    private var branchCache: [String: (branch: String?, at: Date)] = [:]
    /// Your claude.ai account, once signed in: the limit, Cowork tasks and chats.
    private let claudeAI = ClaudeAI()
    private let claudeAISignIn = ClaudeAISignIn()
    /// Codex's own server, while one runs: its limits now, and words
    /// straight into a chat it has loaded (owner, 27.10).
    private let codexServer = CodexServer()
    private let desktopChat = DesktopChat()
    /// The chat Claude Desktop shows, and since when.
    private var desktopShown: (chat: String, since: Date)?

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: Config.directory, withIntermediateDirectories: true)
        // Yours alone: messages in the queue, screenshots, the log, copies of
        // your settings and the sockets live here (it was 755).
        chmod(Config.directory.path, 0o700)
        // Opened from the disk image: to Applications first (on yes this
        // copy quits here).
        if MoveToApplications.needed { MoveToApplications.offer() }
        Config.moveTemplates()
        config = Config.load()
        setUpMainMenu()
        setUpMenuBarItem()
        _ = KeySender.ensureTrusted() // macOS's Accessibility prompt, the first time
        DebugLog.tap("launch")

        store.load()
        SessionTitle.prune(base: Config.directory)
        store.onChange = { [weak self] in self?.setNeedsRefresh() }
        // Its words and files waiting go with it: through claude.ai now.
        store.onRenamed = { [weak self] from, to in
            guard let self else { return }
            if let files = self.attachments.removeValue(forKey: from) { self.attachments[to, default: []] += files }
            if self.pickedSessionId == from { self.pickedSessionId = to }
            if self.lastActiveId == from { self.lastActiveId = to }
            // What you're writing or saying to it right now (review, 29.10).
            if let draft = self.model.chatDrafts.removeValue(forKey: from) { self.model.chatDrafts[to] = draft }
            for state in [self.widget.state, self.drawer.state] where state.composerChat == from { state.composerChat = to }
            if self.voiceFor == from { self.voiceFor = to }
            if self.model.listeningFor == from { self.model.listeningFor = to }
            guard self.queue.contains(where: { $0.sessionId == from }) else { return }
            self.queue = self.queue.map { $0.sessionId == from ? AppModel.QueueItem(id: $0.id, text: $0.text, sessionId: to, project: $0.project) : $0 }
            self.saveQueue()
            DebugLog.note("queue: its chat is a Cowork task — its words go through claude.ai")
        }

        problems.about = { [weak self] in self?.aboutThisMac() ?? [] }
        problems.offers = { [weak self] in (self?.config.problemOffers ?? false) && self?.config.doNotDisturb != true }
        problems.stopOffers = { [weak self] in self?.setConfig("problemOffers", false) }
        problems.start()
        startLocalCowork()

        // Hooks, the status line and the tap talk to the app here.
        let socket = SocketServer(path: Config.socketPath) { [weak self] message, responder in
            self?.handle(message, responder: responder)
        }
        if (try? socket.start()) != nil {
            server = socket
            // The pre-rename socket name, for taps and hooks started before.
            let old = Config.directory.appendingPathComponent("claudebar.sock").path
            unlink(old)
            symlink("cloudingbar.sock", old)
        } else {
            DebugLog.problem("socket", "the socket couldn't be opened: hooks can't reach the app")
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(frontmostAppChanged(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        frontApp = NSWorkspace.shared.frontmostApplication

        touchBar.barView.onAction = { [weak self] in self?.perform($0) }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.setNeedsRefresh()
            }
        }
        touchBar.barView.onWidth = { DebugLog.note("touch bar: \($0)") }
        typing.onChange = { [weak self] text in self?.typingChanged(text) }
        typing.onSubmit = { [weak self] _ in self?.perform(.send) }
        typing.onCancel = { [weak self] in self?.stopTyping() }

        setUpModel()
        setUpVoice()
        loadQueue()
        setUpClaudeAI()
        setUpCodexServer()
        model.showTour = { [weak self] in self?.showTour() }

        setUpClaudeCode()
        setUpUpdates()
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
            case "Stop", "UserPromptSubmit", "SessionEnd", "Interrupt", "StopFailure":
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
        if let app = frontApp, desktopChats(app) {
            readDesktopChat(app)
        } else if let app = frontApp, isTerminal(app) {
            frontWindow.readTitle(of: app) { [weak self] title in
                guard let self, title != self.frontTitle else { return }
                self.frontTitle = title
                self.setNeedsRefresh()
            }
            readFrontTTY(app)
        }
        if ticks % 2 == 0 {
            store.pollTranscripts()
            if ticks % 10 == 0 || ticks == 2 {
                store.pollCodexRollouts()
                if config.codexServer && Setup.hasCodex { codexServer.poll() }
            }
        } else {
            readDesktopPrompt()
        }
        if ticks % 10 == 0 { refreshSetupStatus() }
        if ticks % 5 == 0 { followRemoteControl() }
        // A closed chat leaves the list within 2 s (was 10, owner 28.10).
        if ticks % 2 == 0 {
            let gone = Set(store.prune())
            for r in requests where r.sessionId.map(gone.contains) ?? false { finish(r, "session gone → dropped") }
        }
        refresh() // the reset countdown ticks
    }

    // MARK: - Front app

    @objc private func frontmostAppChanged(_ note: Notification) {
        frontApp = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        frontTitle = nil
        barExpanded = false
        desktopShown = nil
        frontTTY = nil
        refresh()
        if let app = frontApp, desktopChats(app) {
            readDesktopChat(app)
        } else if let app = frontApp, isTerminal(app) {
            frontWindow.readTitle(of: app) { [weak self] title in
                self?.frontTitle = title
                self?.setNeedsRefresh()
            }
            readFrontTTY(app)
        }
    }

    static let desktopBundle = "com.anthropic.claudefordesktop"

    /// Claude Desktop in front, with chats of its own: the one its sidebar
    /// shows open (its window title is always "Claude").
    /// Claude Desktop in front, with chats of its own alive. (It may be in
    /// terminalBundleIDs too, for the Touch Bar; its window title says
    /// nothing, so this comes first.)
    private func desktopChats(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == Self.desktopBundle && store.alive.contains(where: \.inDesktopApp)
    }

    private func readDesktopChat(_ app: NSRunningApplication) {
        desktopChat.readOpenChat(of: app) { [weak self] shown in
            guard let self, self.frontApp == app, let shown,
                  shown.chat != self.desktopShown?.chat || shown.title != self.frontTitle else { return }
            if shown.chat != self.desktopShown?.chat { self.desktopShown = (shown.chat, Date()) }
            self.frontTitle = shown.title
            // Known by its title: remembered by its chat too.
            if let title = shown.title, self.store.session(inDesktop: nil, chat: shown.chat) == nil,
               let s = self.store.session(inDesktop: title), s.desktopChat == nil {
                self.store.link(s, desktopChat: shown.chat, title: title)
            }
            DebugLog.note("desktop chat: \(shown.title ?? "…") \(shown.chat) → \(self.store.session(inDesktop: shown.title, chat: shown.chat)?.displayName ?? "not known")")
            self.setNeedsRefresh()
        }
    }

    /// Terminal or iTerm in front, with a terminal chat alive: which tab.
    private func readFrontTTY(_ app: NSRunningApplication) {
        guard let id = app.bundleIdentifier, Terminals.supports(id),
              store.alive.contains(where: { $0.tty != nil && $0.entrypoint != "claude-vscode" }) else {
            if frontTTY != nil { frontTTY = nil; setNeedsRefresh() }
            return
        }
        Terminals.frontTTY(id) { [weak self] tty in
            guard let self, tty != self.frontTTY else { return }
            self.frontTTY = tty
            self.setNeedsRefresh()
        }
    }

    /// A Claude app in front — a terminal or VS Code (the hosts in the
    /// config) or Claude Desktop — not a browser or a messenger.
    private var claudeAppInFront: Bool {
        guard let app = frontApp else { return false }
        return isTerminal(app) || app.bundleIdentifier == Self.desktopBundle
    }

    /// Keys into the chat in front, unless Claude is asking for permission
    /// there in its own menu: Return would pick "Yes", a digit an option.
    private func safeToType(quiet: Bool = false) -> Bool {
        let front = frontApp?.bundleIdentifier == Self.desktopBundle
            ? store.session(inDesktop: frontTitle, chat: desktopShown?.chat)
            : store.session(inWindow: frontTitle, tty: frontTTY)
        guard let s = front ?? focusedSession, s.waitingNotice else { return true }
        if !quiet { NSSound.beep() }
        DebugLog.note("typing held back: \(s.displayName) is asking for permission")
        return false
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
        guard touchBarEnabled, SystemModalTouchBar.isSupported, let app = frontApp else { return false }
        if config.touchBarEverywhere { return true }
        return isTerminal(app) && !store.alive.isEmpty
    }

    /// Over the Control Strip in Claude's apps; next to it elsewhere (the
    /// bar in every app), so volume and brightness stay at hand.
    private var barFullWidth: Bool {
        // A window of ours has the keyboard (writing on the bar, the widget's
        // message box, Settings): beside Apple's buttons macOS would put that
        // window's own Touch Bar in Claude's place, so the whole bar it is.
        // The chats list too: beside Apple's buttons several chats don't fit.
        barExpanded || NSApp.keyWindow != nil || barPanel == .chats
            || (inClaudeApp ? config.hideControlStrip : config.touchBarOutside == "whole")
    }

    /// The short bar opened to the whole Touch Bar, until folded back or
    /// another app comes to the front.
    private var barExpanded = false

    /// A terminal, VS Code or Claude in front.
    private var inClaudeApp: Bool { frontApp.map(isTerminal) ?? false }

    /// The chats a Claude app's window in front may show (SessionStore.inFront):
    /// no word that one of them finished — never a guess from the one followed before.
    private var chatsInFront: Set<String> {
        guard let app = frontApp, claudeAppInFront else { return [] }
        return store.inFront(windowTitle: frontTitle, tty: frontTTY,
                             desktop: app.bundleIdentifier == Self.desktopBundle, desktopChat: desktopShown?.chat)
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

    /// The chat the widget and the bar follow (SessionStore.focus): just
    /// after a pick in the widget, that one, while its window comes up.
    private var focusedSession: Session? {
        if let id = pickedSessionId, Date().timeIntervalSince(pickedAt) < 4,
           let s = store.sessions[id], s.isAlive() { return s }
        if let h = handoff, let s = store.sessions[h.doneId], s.isAlive() { return s }
        if let f = followWorking, let s = store.sessions[f.id], s.isAlive() { return s }
        return frontSession
    }

    /// The chat of the window or tab in front (SessionStore.focus).
    private var frontSession: Session? {
        store.focus(windowTitle: frontTitle, tty: frontTTY, sticky: [pickedSessionId, lastActiveId].compactMap { $0 },
                           desktop: frontApp?.bundleIdentifier == Self.desktopBundle, desktopChat: desktopShown?.chat)
    }

    private func refresh() {
        refreshQueued = false
        Session.useShortNames = config.shortNames
        namer.consider(store.alive)
        let key = frontKey
        if key != frontSince.key { frontSince = (key, Date()) }
        // Gone to another chat yourself: the pick is over.
        let shown = frontApp?.bundleIdentifier == Self.desktopBundle
            ? store.session(inDesktop: frontTitle, chat: desktopShown?.chat) : store.session(inWindow: frontTitle, tty: frontTTY)
        if let id = pickedSessionId, Date().timeIntervalSince(pickedAt) >= 4, let shown, shown.id != id {
            pickedSessionId = nil
        }
        updateFollowing()
        let active = focusedSession
        if let shown = currentRequest(active: active)?.id, shown != requestShown.id { requestShown = (shown, Date()) }
        updateDoneAlerts(active: active)
        if active?.id != lastActiveId {
            lastActiveId = active?.id
            DebugLog.note("active session: \(active?.displayName ?? "none") (\(active?.id.prefix(8) ?? "-"))")
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

        // Settings arranging the short bar: that one, live (in the whole
        // bar's place: beside Apple's buttons macOS shows Settings' own).
        var bar = barModel(active: active, short: !barFullWidth || (model.editingShortBar && settings.isKey))
        if let r = currentRequest(active: active), let s = r.sessionId.flatMap({ store.sessions[$0] }) {
            bar.requestChat = BarModel.Chat(id: s.id, name: Self.barName(s.displayName, id: s.id),
                                            color: Session.colors[s.colorIndex % Session.colors.count],
                                            current: s.id == active?.id, waiting: true)
        }

        if composing, currentRequest(active: active) != nil {
            // A request takes the bar: the words wait for later.
            composeDraft = typingText
            stopTyping(keepDraft: true)
        }
        if let request = currentRequest(active: active) {
            bar.activity = .wait
            switch request.kind {
            case .permission:
                let s = request.summary
                bar.mode = .permission(verb: s.verb, detail: s.detail)
                bar.offersAlways = request.canRemember
            case .question:
                if typingFor === request {
                    bar.mode = .typing(text: typingText)
                } else if let q = request.current {
                    // A long question shorter, marked ✦ (Apple's model on this
                    // Mac); a tap shows it whole. The options stay word for word.
                    let text = shortener.short(for: q.text).map { "✦ " + $0 } ?? q.text
                    bar.questionKey = q.text
                    bar.mode = .question(text: text, options: q.options,
                                         multiSelect: q.multiSelect, picked: request.picked)
                }
            }
        } else if composing, let to = composeTo {
            // Written for a chat picked from the list: its chip, its files.
            let s = store.sessions[to]
            bar.mode = .typing(text: typingText)
            bar.typingTo = BarModel.Chat(id: to, name: s.map { Self.barName($0.displayName, id: to) } ?? "Chat ended",
                                         color: s.map { Session.colors[$0.colorIndex % Session.colors.count] } ?? 0x8E8E93,
                                         current: to == active?.id, waiting: false)
            bar.typingFiles = attachments[to]?.count ?? 0
            bar.typingPlaceholder = "Type on the keyboard…"
        } else if composing {
            bar.mode = .typing(text: typingText)
            bar.typingLabel = active.map { "To " + Self.short($0.displayName, 18) } ?? "Write"
            bar.typingPlaceholder = config.taskQueue ? "Sent when Claude is free" : "Typed into the chat"
            bar.typingCommands = true
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
                bar.mode = panel == .models ? .models : panel == .agents ? .agents : panel == .templates ? .templates : .chats
            } else {
                closeBarPicker()
            }
        }
        // Another chat is done: Cloud says which for a few seconds — not over
        // a request, your writing or an open list.
        if let d = doneNow, bar.mode == .normal || bar.mode == .contextWarning, let s = store.sessions[d.id] {
            bar.mode = .done(BarModel.Chat(id: s.id, name: Self.barName(s.displayName, id: s.id),
                                           color: Session.colors[s.colorIndex % Session.colors.count],
                                           current: false, waiting: false))
            bar.doneAnswer = answerStart(of: s)
        }
        touchBar.show(bar, fullWidth: barFullWidth)
    }

    /// A name cut to `n` characters with "…".
    static func short(_ text: String, _ n: Int) -> String {
        text.count > n ? String(text.prefix(n - 1)) + "…" : text
    }

    /// The buttons in the row.
    private func currentButtons(_ active: Session?) -> [ButtonSpec] {
        config.buttons(for: active?.projectName).filter { !$0.menu }
    }

    /// The Commands button's list: all your buttons, the row's and the
    /// ones kept only there (owner, 26.10: it opens the commands).
    private func menuButtons(_ active: Session?) -> [ButtonSpec] {
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

    /// The bar for the chat shown, as it is between requests — for the
    /// Touch Bar, and for Settings to arrange (`short`: beside Apple's buttons).
    private func barModel(active: Session?, short: Bool) -> BarModel {
        var bar = BarModel()
        bar.buttons = currentButtons(active)
        let account = active?.entrypoint == "codex" ? store.codexAccount : store.account
        bar.sessionPercent = account.sessionPercent
        bar.resetCountdown = account.resetCountdown
        bar.contextPercent = active?.contextPercent(windowOverride: config.contextWindowSize)
        bar.activity = activity(of: active)
        bar.cloudVariant = active.map { $0.colorIndex % Session.colors.count }
        bar.quiet = config.doNotDisturb
        bar.awake = config.widget ? widget.panelOpen : drawer.shown
        bar.shows = Set(short ? config.touchBarShortShows : config.touchBarShows)
        bar.modelLabel = ModelChoice.label(model: active?.modelName, effort: active?.effort)
        bar.modelAlias = barPendingModel ?? ModelChoice.alias(of: active?.model)
        bar.effort = barPendingEffort ?? active?.effort
        bar.agents = (active?.agents ?? []).map { a in
            ([a.type] + [a.task ?? a.doing].compactMap { $0 }).joined(separator: " · ")
        }
        bar.chats = model.sessions.map {
            BarModel.Chat(id: $0.id, name: ($0.current && model.chatDone ? "✓ " : "") + Self.barName($0.name, id: $0.id),
                          color: $0.color, current: $0.current, waiting: $0.waiting)
        }
        bar.templates = menuButtons(active).map { Self.short($0.label, 28) }
        if let active, active.linesAdded + active.linesRemoved > 0 {
            bar.lines = "+\(active.linesAdded) −\(active.linesRemoved)"
        }
        bar.branch = active.flatMap(branch(of:))
        bar.cost = active?.costUSD.map { String(format: "$%.2f", $0) }
        bar.chatName = active.map { Self.short($0.displayName, 18) }
        bar.project = active?.projectName
        bar.short = short // beside Apple's buttons: everything smaller
        bar.expanded = barExpanded
        bar.listening = voiceIntoBar && voice.isRunning
        let which = short ? "short" : "whole"
        bar.order = config.touchBarOrder[which] ?? []
        // The short bar's blocks have their own sizes, not dragged ones.
        bar.widths = short ? [:] : (config.touchBarWidths[which] ?? [:]).mapValues { CGFloat($0) }
        return bar
    }

    private func pickOption(_ i: Int, _ request: PendingRequest) {
        guard let q = request.current, q.options.indices.contains(i) else { return }
        if q.multiSelect {
            if request.picked.contains(i) { request.picked.remove(i) } else { request.picked.insert(i) }
            DebugLog.tap("toggle \(q.options[i])")
            extendHold(request)
            setNeedsRefresh()
        } else {
            DebugLog.tap("option \(q.options[i])")
            advance(request, with: q.options[i])
        }
    }

    private func sendPicked(_ request: PendingRequest) {
        guard let q = request.current, !request.picked.isEmpty else { return }
        let labels = request.picked.sorted().map { q.options[$0] }
        DebugLog.tap("send \(labels.joined(separator: ", "))")
        advance(request, with: labels.joined(separator: ", "))
    }

    // MARK: - Taps

    private func perform(_ action: BarAction) {
        let active = focusedSession
        let request = currentRequest(active: active)

        switch action {
        case .widget:
            DebugLog.tap("widget button")
            if config.widget {
                // Cloud wakes up and opens the widget's panel; tapped again,
                // it folds the panel away and dozes off.
                widget.togglePanel()
                if widget.panelOpen { touchBar.barView.pokeCharacter() }
                setNeedsRefresh()
            } else {
                drawer.toggle()
            }

        case let .button(i):
            let buttons = currentButtons(active)
            guard buttons.indices.contains(i) else { return }
            let spec = buttons[i]
            DebugLog.tap("button \(spec.label)")
            if composing && spec.type == .text {
                // Into the message being written.
                let draft = typingText.trimmingCharacters(in: .whitespaces)
                composeDraft = (draft.isEmpty ? "" : draft + " ") + expand(spec.value)
                stopTyping(keepDraft: true)
                perform(.write)
            } else if composing {
                // The keys go back to your editor first; the words wait.
                composeDraft = typingText
                stopTyping(keepDraft: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.run(spec) }
            } else {
                run(spec)
            }

        case .allow, .always, .deny, .option, .sendPicked:
            guard let request else { return }
            guard request.id == requestShown.id, Date().timeIntervalSince(requestShown.at) >= 0.7 else {
                // It has only just come (or replaced the one you meant).
                if request.id != requestShown.id { requestShown = (request.id, Date()) }
                DebugLog.tap("answer ignored: the request had only just come")
                return
            }
            if case let .option(i) = action { pickOption(i, request); return }
            if case .sendPicked = action { sendPicked(request); return }
            guard request.kind == .permission else { return }
            if request.desktopKey != nil {
                // Asked in Claude Desktop's window: its button pressed there.
                let labels = desktopPrompt?.options ?? []
                let pick: String?
                switch action {
                // Never "Always allow" for an Allow: no plain one, nothing pressed.
                case .allow: pick = labels.first { DesktopChat.allows($0) && !$0.lowercased().contains("always") }
                case .always: pick = labels.first { $0.lowercased().contains("always") } ?? labels.first(where: DesktopChat.allows)
                default: pick = labels.first(where: DesktopChat.denies)
                }
                guard let pick else {
                    NSSound.beep()
                    DebugLog.tap("desktop permission: no such button there")
                    return
                }
                DebugLog.tap("desktop permission: \(pick)")
                answerInDesktop(request, choices: [pick], own: nil)
                return
            }
            let name: String
            let output: [String: Any]
            switch action {
            case .allow: name = "allow"; output = PendingRequest.allow()
            case .always: name = "always"; output = request.always()
            default: name = "deny"; output = PendingRequest.deny()
            }
            DebugLog.tap("\(name) \(request.toolName)")
            answer(request, output)

        case .other:
            guard let request, request.kind == .question else { return }
            DebugLog.tap("other")
            typingFor = request
            typingText = ""
            typing.begin()
            extendHold(request)
            setNeedsRefresh()

        case .write:
            guard request == nil else { return }
            DebugLog.tap("write (bar)")
            closeBarPicker()
            openLine()

        case let .writeTo(id):
            // A chat picked from the list: the line written for it, the chat
            // followed and the windows as they are.
            guard request == nil, store.sessions[id] != nil else { return }
            DebugLog.tap("write to \(store.sessions[id]?.displayName ?? id) (bar)")
            openLine(to: id)
            closeBarPicker()

        case .cancelTyping:
            DebugLog.tap("cancel typing (bar)")
            if composing { composeDraft = "" }
            stopTyping()

        case .templates where menuButtons(active).isEmpty:
            // Nothing in it yet: where to put buttons in it.
            DebugLog.tap("menu (bar): empty, to Settings → Buttons")
            model.openSettingsTab("buttons")

        case .templates:
            DebugLog.tap("templates (bar)")
            if composing {
                composeDraft = typingText
                templatesIntoDraft = true
                stopTyping(keepDraft: true)
            }
            barPanel = .templates
            closeBarPickerLater(after: 20)
            setNeedsRefresh()

        case let .pickTemplate(i):
            let intoDraft = templatesIntoDraft
            closeBarPicker()
            let menu = menuButtons(active)
            guard menu.indices.contains(i) else { return }
            DebugLog.tap("menu \(menu[i].label)")
            if intoDraft && menu[i].type == .text {
                // Into the message being written, then back to it.
                let draft = composeDraft.trimmingCharacters(in: .whitespaces)
                composeDraft = (draft.isEmpty ? "" : draft + " ") + expand(menu[i].value)
                perform(.write)
            } else {
                run(menu[i])
            }

        case .send where composing && composeTo != nil:
            // Written for a chat picked from the list: to that chat, as the
            // Chats tab sends — straight in or its queue, nothing typed into
            // a window (owner, 27.10). The bar back as it was.
            guard let to = composeTo else { return }
            let text = typingText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || attachments[to]?.isEmpty == false else { return }
            guard store.sessions[to]?.isAlive() == true else {
                // It has ended: the line stays, its chip takes the words to another chat.
                NSSound.beep()
                DebugLog.note("send (bar): the chat picked has ended — not sent")
                return
            }
            DebugLog.tap("send message (bar) to a chat picked")
            composeDraft = ""
            stopTyping()
            send(text, to: to)

        case .send where composing:
            let text = typingText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            DebugLog.tap("send message (bar)")
            composeDraft = ""
            stopTyping()
            if config.taskQueue {
                model.addToQueue(text) // sent when Claude is free, like the widget's
            } else {
                // Into its chat, brought forward if another app is in front.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.deliver(text, to: self?.focusedSession)
                }
            }

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
            // In the message line: our own recognizer, the words showing in
            // the line as you speak (not the system's dictation up top).
            DebugLog.tap("dictate")
            if let request = typingFor { extendHold(request) }
            if voice.isRunning { voice.stop() } else { voiceBegin(stopAfterPause: 5) }

        case .dictate:
            DebugLog.tap("dictate (bar)")
            model.voiceToggle()

        case .screenshot:
            DebugLog.tap("screenshot (bar)")
            // From the line written for a chat picked: for that chat.
            if composing, let to = composeTo { takeScreenshot(into: to) } else { takeScreenshot() }

        case .compact:
            DebugLog.tap("compact (context warning)")
            active?.contextSnoozedUntil = 101 // until it drops below the threshold
            guard claudeAppInFront, safeToType() else { NSSound.beep(); setNeedsRefresh(); return }
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

        case .chats:
            DebugLog.tap("chats (bar)")
            if composing {
                // The chip on the line: back to the list, the words kept for
                // the chat picked next (dropped if none is).
                composeDraft = typingText
                stopTyping(keepDraft: true)
            }
            barPanel = .chats
            closeBarPickerLater(after: 15)
            setNeedsRefresh()

        case let .pickChat(id):
            if composing && composeTo == id {
                // ↗ on the line written for it: that chat comes up (the keys
                // go to it), the words wait for it on the bar.
                composeDraft = typingText
                stopTyping(keepDraft: true)
            }
            closeBarPicker()
            if doneNow?.id == id { endDone() }
            model.focusSession(id)

        case .dismissDone:
            DebugLog.tap("done elsewhere: OK")
            endDone()

        case .showRequest:
            // The whole question or command: in the widget's panel, else the island.
            DebugLog.tap("whole request (bar)")
            if config.widget {
                widget.showPanel()
            } else if !drawer.shown {
                drawer.show()
            }
            setNeedsRefresh()

        case .closePanel:
            let backToDraft = templatesIntoDraft
            closeBarPicker()
            if backToDraft { perform(.write) }

        case .expand:
            DebugLog.tap("whole bar")
            barExpanded = true
            setNeedsRefresh()

        case .collapse:
            DebugLog.tap("fold back")
            barExpanded = false
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
        // No chat: words and keys would go to the shell or the file in front
        // (the widget shows its buttons with no chat too, owner 25.10).
        if focusedSession == nil, [.phrase, .command, .text, .key].contains(spec.type) {
            NSSound.beep()
            DebugLog.note("button held back: no chat")
            return
        }
        widget.releaseKey() // keystrokes go to your editor, not the widget
        switch spec.type {
        case .screenshot:
            takeScreenshot()
        case .phrase, .command:
            let text = spec.type == .phrase ? expand(spec.value) : spec.value
            if claudeAppInFront && safeToType(quiet: true) {
                KeySender.type(text, pressReturn: true)
            } else if let session = focusedSession {
                // Another app in front (the bar shows everywhere), or Claude's
                // permission menu open there: not typed — to the chat, like the
                // widget's message (straight in, or queued until it's safe).
                deliver(text, to: session)
            } else {
                NSSound.beep()
            }
        case .text:
            // Into the app in front, to finish there — never into Claude's
            // permission menu.
            guard !claudeAppInFront || safeToType() else { return }
            insertTemplate(spec.value)
        case .key:
            guard claudeAppInFront, safeToType() else { NSSound.beep(); return }
            if !KeySender.press(spec.value) { NSSound.beep() }
        case .link:
            // A path works too ("~/Applications/Some.app"): the way it's
            // written down most often (owner, 27.10).
            let value = spec.value.trimmingCharacters(in: .whitespaces)
            let url = value.hasPrefix("/") || value.hasPrefix("~")
                ? URL(fileURLWithPath: (value as NSString).expandingTildeInPath)
                : URL(string: value)
            guard let url else { NSSound.beep(); return }
            NSWorkspace.shared.open(url)
        }
    }

    private func answer(_ request: PendingRequest, _ output: [String: Any]) {
        guard requests.contains(where: { $0 === request }) else { return }
        if request.desktopKey != nil, let q = request.questions.first {
            // Asked in Claude Desktop's window: the option pressed there, or
            // your own words typed into its field.
            let text = request.answers[q.text] ?? ""
            let parts = text.components(separatedBy: ", ")
            if q.options.contains(text) {
                answerInDesktop(request, choices: [text], own: nil)
            } else if parts.allSatisfy(q.options.contains) {
                answerInDesktop(request, choices: parts, own: nil)
            } else {
                answerInDesktop(request, choices: [], own: text)
            }
            return
        }
        requests.removeAll { $0 === request }
        // Desktop's window may show it a while yet: not offered from there again.
        if request.remoteKey != nil { remoteJustAnswered = remoteJustAnswered.filter { Date().timeIntervalSince($0.at) < 20 } + [(request, Date())] }
        request.responder.answer(output)
        // Codex's own prompt is not coming: it asked, you answered here.
        if request.entrypoint == "codex", let id = request.sessionId { store.sessions[id]?.waitingNotice = false }
        if typingFor === request { stopTyping() }
        DebugLog.note("answered from the bar")
        setNeedsRefresh()
    }

    // MARK: - Claude Desktop's own questions (Cowork)

    /// What the chat open in Claude Desktop asks (a question, a permission),
    /// read from its window: Cowork's never reach a hook.
    private var desktopPrompt: DesktopChat.Prompt?
    /// Just answered: still on screen a moment, not to be offered again.
    private var desktopAnswered: (key: String, at: Date)?

    private var desktopTrace = ""

    private func readDesktopPrompt() {
        if desktopChat.trace == nil {
            // Why nothing was found, in debug.log — once per change.
            desktopChat.trace = { [weak self] why in
                DispatchQueue.main.async {
                    guard let self, why != self.desktopTrace else { return }
                    self.desktopTrace = why
                    DebugLog.note("desktop prompt: \(why.replacingOccurrences(of: #"\(\d+ elements"#, with: "(…", options: .regularExpression))")
                }
            }
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.desktopBundle).first else {
            if desktopPrompt != nil { syncDesktopPrompt(nil) }
            return
        }
        desktopChat.readPrompt(of: app) { [weak self] prompt in self?.syncDesktopPrompt(prompt) }
    }

    /// When the window's question was first read.
    private var desktopPromptSeen: (key: String, at: Date)?

    /// The window's question on the bar and in the widget, as long as it's there.
    private func syncDesktopPrompt(_ prompt: DesktopChat.Prompt?) {
        desktopPrompt = prompt
        if prompt == nil { desktopPromptSeen = nil }
        let current = requests.first { $0.desktopKey != nil }
        if let current, current.desktopKey != prompt?.key {
            finish(current, "desktop prompt: answered in Claude", reply: false)
        }
        guard let prompt, current?.desktopKey != prompt.key else { return }
        if let a = desktopAnswered, a.key == prompt.key, Date().timeIntervalSince(a.at) < 6 { return }
        // The chat open there: the one it asks in.
        let session = desktopShown.flatMap { shown in store.alive.first { $0.desktopChat == shown.chat } }?.id
        // A Cowork task's comes from its card within seconds, with all it says;
        // the window's reading first, then that, showed the card twice (owner,
        // 30.10). The window's only if its card has nothing to say.
        if let s = session.flatMap({ store.sessions[$0] }), s.entrypoint == "cowork", s.remoteSession != nil, claudeAI.canSend {
            if desktopPromptSeen?.key != prompt.key { desktopPromptSeen = (prompt.key, Date()) }
            if let seen = desktopPromptSeen, Date().timeIntervalSince(seen.at) < 8 { return }
        }
        let request = prompt.kind == .question
            ? PendingRequest(desktopQuestion: prompt.text, options: prompt.options, multiSelect: prompt.multiSelect,
                             sessionId: session, key: prompt.key)
            : PendingRequest(desktopPermission: prompt.text, sessionId: session, key: prompt.key)
        // Read from claude.ai already, or just answered there: the bar has it once (review, 29.10).
        let remote = requests.filter { $0.remoteKey != nil }
            + remoteJustAnswered.filter { Date().timeIntervalSince($0.at) < 20 }.map(\.request)
        if remote.contains(where: request.sameAsk) { return }
        requests.append(request)
        DebugLog.note("desktop prompt: \(prompt.kind == .question ? "question" : "permission") on the bar (\(prompt.options.count) options)")
        setNeedsRefresh()
    }

    /// Presses the answer in Claude Desktop's window.
    private func answerInDesktop(_ request: PendingRequest, choices: [String], own: String?) {
        requests.removeAll { $0 === request }
        if typingFor === request { stopTyping() }
        desktopAnswered = (request.desktopKey ?? "", Date())
        guard let prompt = desktopPrompt, prompt.key == request.desktopKey,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.desktopBundle).first else {
            DebugLog.note("desktop prompt: gone before the answer")
            setNeedsRefresh()
            return
        }
        // Your words may need typing in Claude's window: not into the widget's field.
        if own != nil { widget.releaseKey() }
        desktopChat.answer(prompt, choices: choices, own: own, in: app) { [weak self] done in
            if done { DebugLog.note("desktop prompt: answered in Claude's window") } else { DebugLog.problem("desktop answer", "desktop prompt: couldn't press the answer") }
            if !done { NSSound.beep() }
            self?.setNeedsRefresh()
        }
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

    /// Ends the bar's line. The line written for a chat picked from the
    /// list takes its words with it, unless they're kept (`keepDraft`): words
    /// for one chat never wait to go to another.
    private func stopTyping(keepDraft: Bool = false) {
        if composing, composeTo != nil, !keepDraft {
            composeTo = nil
            composeDraft = ""
        }
        typing.end()
        composing = false
        typingFor = nil
        typingText = ""
        setNeedsRefresh()
    }

    /// The bar's message line, with the words waiting; `to`: written for a
    /// chat picked from the list. Words still waiting for such a chat (a
    /// request took the bar) keep it.
    private func openLine(to id: String? = nil) {
        if let id { composeTo = id } else if composeDraft.isEmpty { composeTo = nil }
        composing = true
        typingText = composeDraft
        typing.begin(with: composeDraft)
        setNeedsRefresh()
    }

    // MARK: - Menu bar

    /// Cloud in the menu bar, and its menu, entry by entry (nil: a line).
    private func setUpMenuBarItem() {
        touchBarToggleItem.target = self
        touchBarToggleItem.action = #selector(toggleTouchBar)
        updateItem.target = self
        updateItem.action = #selector(updateFromMenu)
        let entries: [NSMenuItem?] = [
            NSMenuItem(title: "Clouding Bar", action: nil, keyEquivalent: ""),
            touchBarStatusItem, touchBarToggleItem, templatesItem,
            nil,
            menuEntry("Show or Hide the Island", #selector(toggleIsland)),
            menuEntry("Settings…", #selector(openSettings), key: ","),
            menuEntry("Take the Tour…", #selector(showTour)),
            menuEntry("Report a Problem…", #selector(reportProblem)),
            updateItem,
            menuEntry("Reset Widget Position", #selector(resetWidgetPosition)),
            nil,
            menuEntry("Reload Config", #selector(reloadConfig)),
            menuEntry("Open Config Folder", #selector(openConfigFolder)),
            nil,
            NSMenuItem(title: "Quit Clouding Bar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ]
        let menu = NSMenu()
        menu.delegate = self
        entries.forEach { menu.addItem($0 ?? .separator()) }

        let cloud = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        cloud.button?.image = MascotView.menuBarImage()
        cloud.button?.setAccessibilityLabel("Clouding Bar")
        cloud.menu = menu
        menuBarCloud = cloud
    }

    /// A menu entry that calls back here.
    private func menuEntry(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
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
        if case .available(let v) = updater.state {
            updateItem.title = "Install Update \(v)…"
        } else {
            updateItem.title = "Check for Updates…"
        }
        updateItem.isHidden = !Updater.isRelease
        touchBarPresent = TouchBarDetector.hasTouchBar
        touchBarStatusItem.title = touchBarPresent ? "Touch Bar: found" : "Touch Bar: not found"
        touchBarToggleItem.state = touchBarEnabled ? .on : .off
        // The menu button's list, here too.
        let menu = menuButtons(focusedSession)
        templatesItem.isHidden = menu.isEmpty
        let sub = NSMenu()
        for spec in menu {
            let item = NSMenuItem(title: spec.label, action: #selector(menuTemplate(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = spec
            item.toolTip = spec.value
            sub.addItem(item)
        }
        templatesItem.submenu = sub
    }

    @objc private func menuTemplate(_ sender: NSMenuItem) {
        // The one picked, even if the chat shown changes meanwhile.
        guard let spec = sender.representedObject as? ButtonSpec else { return }
        // Let the menu close and focus return to the app in front first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            DebugLog.tap("menu \(spec.label)")
            self.run(spec)
        }
    }

    /// One of the menu button's list, picked in the widget.
    private func runMenu(_ i: Int) {
        let menu = menuButtons(focusedSession)
        guard menu.indices.contains(i) else { return }
        DebugLog.tap("menu \(menu[i].label)")
        run(menu[i])
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
                self?.model.setupFailed = false
                // VS Code doesn't run the status line: its chats bring the
                // 5-hour limit through the wrapper, set up with the rest
                // (owner, 25.10: on a fresh install VS Code showed nothing).
                let vscode = Setup.describe(Setup.wrapVSCodeIfFree())
                // A fresh install hadn't it (28.10): the prompt at launch goes
                // by unseen. Asked again now, with the reason.
                let trusted = KeySender.ensureTrusted()
                self?.model.setupMessage = (["Connected: new chats show up here."]
                    + (Setup.pluginActive ? ["A chat that was already open: type /reload-plugins in it, or start a new one."] : [])
                    + [vscode].compactMap { $0 }
                    + (trusted ? [] : ["One more: allow Clouding Bar in System Settings → Privacy & Security → Accessibility, for the bar's buttons and Claude Desktop's chats."]))
                    .joined(separator: " ")
            } catch {
                self?.model.setupFailed = true
                self?.model.setupMessage = error.localizedDescription
            }
            self?.refreshSetupStatus()
        }
        model.connectCodex = { [weak self] in
            DebugLog.tap("connect to Codex")
            do {
                try Setup.connectCodex()
                self?.model.codexMessage = Setup.codexPluginActive
                    ? "Codex already has Clouding Bar's plugin, which brings the hooks: nothing to add. Codex runs them once you trust them (Trust all, or /hooks)."
                    : "Done. Codex runs the hooks only once you trust them: start it and choose Trust all (or run /hooks). A hook added later asks again, for itself only."
            } catch {
                self?.model.codexMessage = "Codex's hooks.json couldn't be changed: \(error.localizedDescription)"
            }
            self?.refreshSetupStatus()
        }
        model.openAccessibility = {
            DebugLog.tap("open Accessibility settings")
            KeySender.ensureTrusted() // puts Clouding Bar in the list, to be switched on
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
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

    /// Also every 10 seconds (a plugin installed meanwhile): only what
    /// changed is assigned, so the settings window doesn't redraw for nothing.
    private func refreshSetupStatus() {
        let m = model
        func set(_ key: ReferenceWritableKeyPath<AppModel, Bool>, _ value: Bool) {
            if m[keyPath: key] != value { m[keyPath: key] = value }
        }
        set(\.pluginActive, Setup.pluginActive)
        set(\.pluginSynced, Setup.pluginSynced)
        set(\.claudeConnected, Setup.isConnected)
        set(\.hasCodex, Setup.hasCodex)
        set(\.codexConnected, Setup.codexConnected)
        set(\.codexViaPlugin, Setup.codexPluginActive && !Setup.codexHooksInFile)
        set(\.hasVSCode, Setup.hasVSCode)
        set(\.vscodeWrapped, Setup.vscodeWrapped)
        set(\.accessibilityTrusted, AXIsProcessTrusted())
    }

    /// The first launch of a download: ask before touching Claude Code's settings.
    private func offerSetup() {
        let vscodeLine = Setup.hasVSCode && !Setup.vscodeWrapped
            ? ", and in VS Code a small wrapper for the same limit (unless one of your own is set)" : ""
        let alert = NSAlert()
        alert.messageText = "Connect Clouding Bar to Claude Code?"
        alert.informativeText = Setup.pluginActive
            ? "Clouding Bar's plugin already links it to Claude Code. For the 5-hour limit and the context it adds its status line to ~/.claude/settings.json (a plugin can't)\(vscodeLine): your settings are merged, never replaced, and backed up first."
            : "Clouding Bar adds a small hook and a status line to ~/.claude/settings.json\(vscodeLine), so Claude Code can tell it what it's doing and ask you through it. Your settings are merged, never replaced, and backed up first. Nothing leaves this Mac."
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            model.connectClaude()
            if let message = model.setupMessage {
                let done = NSAlert()
                done.messageText = model.setupFailed ? "Couldn't connect" : "Connected"
                done.informativeText = message
                done.runModal()
            }
        } else {
            setConfig("setupDeclined", true)
        }
    }

    /// Cowork tasks on this Mac (LocalCowork): every 5 s, as claude.ai's when one is on.
    private func startLocalCowork() {
        let queue = DispatchQueue(label: "cloudingbar.local-cowork", qos: .utility)
        let reader = LocalCowork.Reader()
        var reading = false, said: Int?
        let timer = Timer(timeInterval: ClaudeAIChats.Pace.active, repeats: true) { [weak self] _ in
            guard !reading else { return }
            reading = true
            queue.async {
                let tasks = reader.read()
                DispatchQueue.main.async {
                    reading = false
                    if said != tasks.count {
                        said = tasks.count
                        DebugLog.note("local cowork: \(tasks.count) active on this Mac")
                    }
                    self?.store.apply(localCowork: tasks)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        localCoworkTimer = timer
    }

    @objc private func reportProblem() {
        DebugLog.tap("report a problem")
        problems.reportNow()
    }

    /// What a report says about this Mac: how it's set up, nothing of yours.
    private func aboutThisMac() -> [String] {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        #if arch(arm64)
        let chip = "Apple silicon"
        #else
        let chip = "Intel"
        #endif
        func on(_ value: Bool) -> String { value ? "yes" : "no" }
        return ["Clouding Bar " + version, "macOS " + ProcessInfo.processInfo.operatingSystemVersionString, chip,
                "Screens: \(NSScreen.screens.count)", "Accessibility: " + on(model.accessibilityTrusted),
                "Claude Code connected: " + on(model.claudeConnected), "VS Code wrapper: " + on(model.vscodeWrapped),
                "Codex connected: " + on(model.codexConnected), "claude.ai signed in: " + on(model.hasLiveKey)]
    }

    /// The tour runs in the settings window.
    @objc private func showTour() {
        DebugLog.tap("tour")
        openSettings()
        SettingsTour.begin()
        model.tourStep = 0
    }

    @objc private func resetWidgetPosition() {
        setConfig("widgetPosition", NSNull())
        widget.resetPosition()
    }

    @objc private func reloadConfig() {
        config = Config.load()
        refresh()
    }

    /// ~/.cloudingbar in Finder.
    @objc private func openConfigFolder() {
        let config = Config.directory.appendingPathComponent("config.json")
        if FileManager.default.fileExists(atPath: config.path) {
            NSWorkspace.shared.activateFileViewerSelecting([config])
        } else {
            NSWorkspace.shared.open(Config.directory)
        }
    }

    // MARK: - Widget and settings

    private func setUpModel() {
        model.perform = { [weak self] in self?.perform($0) }
        model.answerText = { [weak self] in self?.answerTyped($0) }
        model.openSession = { [weak self] in self?.openSession($0) }
        model.barChanged = { [weak self] in self?.setNeedsRefresh() }
        shortener.changed = { [weak self] in self?.setNeedsRefresh() }
        answerShortener.changed = { [weak self] in self?.setNeedsRefresh() }
        namer.changed = { [weak self] in self?.setNeedsRefresh() }
        namer.enabled = { [weak self] in self?.config.shortNames ?? false }
        namer.chats = { [weak self] in self?.store.alive ?? [] }
        model.openSettingsTab = { [weak self] tab in
            self?.model.settingsTabRequest = tab
            self?.openSettings()
        }
        model.barPreview = { [weak self] short in
            guard let self else { return BarModel() }
            let active = self.focusedSession
            var bar = self.barModel(active: active, short: short)
            bar.expanded = false
            if active == nil {
                // No chat open: example numbers, so every switch shows what
                // it does (owner, 25.10).
                bar.sessionPercent = bar.sessionPercent ?? 42
                bar.resetCountdown = bar.resetCountdown ?? "1:23"
                bar.contextPercent = 31
                bar.activity = .work
                bar.modelLabel = ModelChoice.label(model: "Opus 5.5", effort: "high")
                bar.agents = ["Explore · Find where the hooks are installed"]
                bar.lines = "+120 −8"
                bar.branch = "main"
                bar.cost = "$1.20"
                bar.chatName = "Example chat"
                bar.project = "my-app"
                bar.chats = [BarModel.Chat(id: "example", name: "Example chat", color: 0x0A84FF, current: true, waiting: false)]
            }
            return bar
        }
        model.focusSession = { [weak self] id in
            guard let self, self.store.sessions[id] != nil else { return }
            DebugLog.tap("focus session \(self.store.sessions[id]?.displayName ?? id)")
            self.pickedSessionId = id
            self.pickedAt = Date()
            if self.preferredRequestSession != nil && self.preferredRequestSession != id { self.preferredRequestSession = nil }
            self.refresh()
            self.openSession(id)
        }
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
        model.sendDictated = { [weak self] in self?.sendDictated() }
        model.discardDictated = { [weak self] in
            DebugLog.tap("discard dictated")
            self?.model.dictated = nil
            self?.widget.update()
        }
        model.voiceToggle = { [weak self] in
            guard let self else { return }
            if self.model.listening || self.voice.isRunning {
                self.voice.stop()
            } else {
                // Tap-to-talk: ends by itself after a 5 s pause (shorter
                // pauses are part of speaking), or with another tap.
                self.voiceBegin(stopAfterPause: 5)
            }
        }
        model.resetWidgetPosition = { [weak self] in self?.resetWidgetPosition() }
        model.openAtLogin = LoginItem.isEnabled
    }

    private func setConfig(_ key: String, _ value: Any) {
        // Something switched on in the widget: a pill sized by hand makes
        // room for it (owner, 25.10) — not an upright one, not one that shows
        // everything already.
        if config.pillWidth > 0, config.pillWidth < 10_000, switchesOn(key, value),
           !PillLayout.isVertical(width: CGFloat(config.pillWidth), height: model.pillHeightBudget) {
            Config.save("pillWidth", 0)
        }
        Config.save(key, value)
        config = Config.load()
        if key == "codexServer" {
            if config.codexServer { codexServer.poll() } else { codexServer.stop() }
            model.codexServerState = config.codexServer ? codexServer.state : "Off"
        }
        DebugLog.note("setting \(key) changed")
        refresh()
    }

    /// Whether this change switches something on in the widget.
    private func switchesOn(_ key: String, _ value: Any) -> Bool {
        switch key {
        case "pillShows": return !Set(value as? [String] ?? []).isSubset(of: config.pillShows)
        case "metrics": return !Set(value as? [String] ?? []).isSubset(of: config.metrics)
        case "widgetHides": return !Set(config.widgetHides).isSubset(of: value as? [String] ?? [])
        case "screenshot": return value as? Bool == true && !config.screenshot
        case "taskQueue": return value as? Bool == true && !config.taskQueue
        default: return false
        }
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
        set(\.hasNotch, WidgetController.hasNotch(WidgetController.notchScreen))
        set(\.hasSession, !alive.isEmpty)
        set(\.activity, request != nil ? .wait : activity(of: active))
        set(\.project, active?.projectName)
        set(\.chatName, active?.displayName)
        set(\.chatColor, Session.colors[(active?.colorIndex ?? 0) % Session.colors.count])
        set(\.cloudVariant, active.map { $0.colorIndex % Session.colors.count })
        set(\.chatPlace, active.map { place(of: $0) })
        // The time on its own in the details line, when that shows it.
        let timeApart = config.metrics.contains("time")
        set(\.chatStatus, active.map { status(of: $0, waiting: activity(of: $0) == .wait, time: !timeApart) })
        set(\.chatTime, active.map { AppModel.duration(since: $0.activity == .work ? $0.activitySince : $0.lastSeen) })
        set(\.chatDone, handoff != nil && active?.id == handoff?.doneId)
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
        set(\.contextTokens, active?.contextTokens)
        set(\.contextWindow, active.map { $0.contextWindow(override: config.contextWindowSize) })
        set(\.tokensIn, active?.tokensIn)
        set(\.tokensOut, active?.tokensOut)
        set(\.cost, active?.costUSD)
        set(\.modelName, active?.modelName)
        set(\.modelId, active?.model)
        set(\.effort, active?.effort)
        set(\.linesAdded, active?.linesAdded ?? 0)
        set(\.linesRemoved, active?.linesRemoved ?? 0)
        set(\.branch, config.metrics.contains("git") ? active.flatMap(branch(of:)) : nil)
        set(\.agents, active?.runningAgents ?? 0)
        set(\.agentRows, (active?.agents ?? []).enumerated().map { i, a in
            AppModel.AgentRow(id: a.toolUseId ?? a.agentId ?? "\(i)", type: a.type, task: a.task, doing: a.doing,
                              elapsed: AppModel.elapsed(since: a.started), background: a.background)
        })
        set(\.isAPI, store.account.sessionPercent == nil && active?.costUSD != nil)
        set(\.queue, queue)
        set(\.attachments, active.flatMap { attachments[$0.id] } ?? [])
        set(\.chatFiles, attachments)
        set(\.chatInFront, active != nil && store.session(inWindow: frontTitle, tty: frontTTY)?.id == active?.id)
        // The widget's buttons; the bar has its own switch for them.
        set(\.buttons, config.widgetHides.contains("buttons") ? [] : currentButtons(active))
        set(\.menuButtons, config.widgetHides.contains("menu") ? [] : menuButtons(active))
        set(\.knownProjects, Array(Set(alive.compactMap(\.projectName))).sorted())

        let waitingIds = Set(requests.compactMap(\.sessionId))
        let rows = alive.map { s -> AppModel.SessionRow in
            let waiting = waitingIds.contains(s.id) || s.waitingNotice
            return AppModel.SessionRow(id: s.id, name: s.displayName, status: status(of: s, waiting: waiting),
                                       activity: waiting ? .wait : s.activity,
                                       context: s.contextPercent(windowOverride: config.contextWindowSize),
                                       waiting: waiting, place: place(of: s),
                                       color: Session.colors[s.colorIndex % Session.colors.count],
                                       current: s.id == active?.id)
        }
        // A steady order, so the chips don't jump about: as they started.
        .sorted { a, b in
            let sa = store.sessions[a.id], sb = store.sessions[b.id]
            return (sa?.colorIndex ?? 0, a.id) < (sb?.colorIndex ?? 0, b.id)
        }
        set(\.sessions, rows)

        let card: AppModel.RequestCard? = request.map { self.card(for: $0, active: active) }
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

    /// "GitHub · VS Code": its project and where it runs.
    private func place(of s: Session) -> String {
        let source: String
        switch s.entrypoint {
        case "cowork", "cowork-local": source = "Cowork"
        case "claude-ai": source = "claude.ai"
        case "claude-vscode": source = "VS Code"
        case "cli": source = "Terminal"
        case "claude-desktop": source = "Desktop"
        case "codex": source = "Codex" + (s.codexHost.map { " · " + $0 } ?? "")
        default: source = "Claude Code"
        }
        // A titled chat names its project too; an untitled one is its project.
        // claude.ai's chats have no project ("Cowork · Cowork" was).
        return ([s.title != nil && !s.fromList ? s.projectName : nil, source] as [String?]).compactMap { $0 }.joined(separator: " · ")
    }

    /// A chat's name on the Touch Bar, Cowork's marked as such (its chats
    /// sit beside Claude Code's under the same names).
    static func barName(_ name: String, id: String) -> String {
        (id.hasPrefix("cowork-") || id.hasPrefix("coworklocal-") ? "Cowork · " : "") + short(name, 60)
    }

    /// "Needs your OK", "Working · 3 min", "Done · your turn", "Idle · 12 min".
    private func status(of s: Session, waiting: Bool, time: Bool = true) -> String {
        waiting ? "Needs your OK"
            : s.activity == .work ? "Working" + (time ? " · \(AppModel.duration(since: s.activitySince))" : "")
            : handoff?.doneId == s.id || (s.finishedAt.map { Date().timeIntervalSince($0) < 15 * 60 } ?? false) ? "Done · your turn"
            : "Idle" + (time ? " · \(AppModel.duration(since: s.lastSeen))" : "")
    }

    /// What's in front, to tell when you've gone elsewhere: the app and the
    /// chat its window or tab surely shows (not the title's text, which
    /// changes as Claude works).
    private var frontKey: String {
        let shown = frontApp?.bundleIdentifier == Self.desktopBundle
            ? store.session(inDesktop: frontTitle, chat: desktopShown?.chat)?.id ?? desktopShown?.chat
            : store.session(inWindow: frontTitle, tty: frontTTY)?.id
        return (frontApp?.bundleIdentifier ?? "") + "|" + (shown ?? "")
    }

    // MARK: - Another chat done

    /// Chats that finished while another was shown, waiting their turn to be
    /// told (one at a time).
    private var doneQueue: [String] = []
    /// Each chat's finish already noticed.
    private var doneSeen: [String: Date] = [:]
    /// The one being told now, until then.
    private var doneNow: (id: String, until: Date)?
    private lazy var doneBubble: DoneBubbleController = {
        let bubble = DoneBubbleController()
        bubble.onOpen = { [weak self] id in
            guard let self else { return }
            switch id {
            default:
                DebugLog.tap("done elsewhere: open")
                self.endDone()
                self.model.focusSession(id)
            }
        }
        // The widget's own Cloud is the one that steps out (owner, 27.10).
        bubble.onAway = { [weak self] way in self?.model.cloudOut = way }
        return bubble
    }()

    /// A chat other than the one shown finished: Cloud says which, on the
    /// widget and the Touch Bar. Not the chat shown or in front (you see
    /// it), not in do-not-disturb, not over a request or your writing.
    private func updateDoneAlerts(active: Session?) {
        // With its answer to tell, the chat shown on the widget too (the only
        // one, often: owner, 29.10 — no answer ever showed): all but the one
        // whose own window is in front.
        let withAnswer = config.answerPreview
        let front = withAnswer ? chatsInFront : Set([frontSession?.id].compactMap { $0 })
        let active = withAnswer ? nil : active
        for s in store.alive {
            guard let at = s.finishedAt, doneSeen[s.id] != at else { continue }
            doneSeen[s.id] = at
            guard config.doneAlerts, !config.doNotDisturb, Date().timeIntervalSince(at) < 60,
                  s.id != active?.id, !front.contains(s.id), handoff?.doneId != s.id, !doneQueue.contains(s.id) else { continue }
            doneQueue.append(s.id)
            DebugLog.note("done elsewhere: \(s.displayName)")
        }
        if let now = doneNow, Date() >= now.until, !doneBubble.hovering { endDone() }
        // Its answer may come after the word that it's done (Codex's file,
        // Cowork's events), and Apple's short form of it later still.
        if let now = doneNow, let s = store.sessions[now.id] { doneBubble.setAnswer(answerStart(of: s)) }
        guard doneNow == nil, requests.isEmpty, !composing, config.doneAlerts, !config.doNotDisturb else { return }
        while let id = doneQueue.first {
            doneQueue.removeFirst()
            // Started again, gone, or in view by now: nothing to tell.
            guard let s = store.sessions[id], s.isAlive(), s.activity == .sleep,
                  s.id != active?.id, !front.contains(s.id) else { continue }
            beginDone(s)
            break
        }
    }

    private func beginDone(_ s: Session) {
        // Longer with the answer's start to read.
        let stay: TimeInterval = config.answerPreview ? 7 : 5
        doneNow = (s.id, Date().addingTimeInterval(stay))
        let alert = DoneBubbleController.Alert(id: s.id, name: s.displayName, detail: place(of: s),
                                               color: Session.colors[s.colorIndex % Session.colors.count],
                                               variant: s.colorIndex % Session.colors.count, answer: answerStart(of: s))
        // On the widget (or, with neither widget nor Touch Bar, the screen's corner).
        if config.widget || !barShouldShow {
            doneBubble.show(alert, anchor: config.widget ? widget.place : nil, stay: stay - 0.5)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + stay + 0.05) { [weak self] in self?.setNeedsRefresh() }
    }

    /// How a done chat's answer begins, for the bubble and the bar: ✦ and
    /// Apple's short form once there is one (asked for here), else its first lines.
    private func answerStart(of s: Session) -> String? {
        guard config.answerPreview, let answer = s.answer else { return nil }
        return answerShortener.short(for: answer).map { "✦ " + $0 } ?? AnswerPreview.firstLines(answer)
    }

    private func endDone() {
        guard doneNow != nil else { return }
        doneNow = nil
        doneBubble.hide()
        setNeedsRefresh()
    }

    /// The chat shown finished: "done" for a moment, then the one still at
    /// work — or, with none at work, back to the chat in front. Your own
    /// move (another window or tab, a pick) or the chat in front starting
    /// again ends it.
    private func updateFollowing() {
        guard config.followWorking else { handoff = nil; followWorking = nil; lastShown = nil; return }
        let picked = pickedSessionId != nil && Date().timeIntervalSince(pickedAt) < 4
        let front = frontSession
        let key = frontKey
        if let h = handoff, h.front != key || picked { handoff = nil }
        if let f = followWorking, f.front != key || picked || (front.map { $0.id != f.id && $0.activity != .sleep } ?? false) {
            followWorking = nil
        }
        // The "done" moment is over: on to the next.
        if let h = handoff, Date() >= h.until {
            handoff = nil
            if let next = store.sessions[h.nextId], next.isAlive(), next.id != front?.id {
                followWorking = (next.id, key)
                DebugLog.note("follow working: \(next.displayName)")
            } else {
                followWorking = nil
            }
        }
        guard handoff == nil, let shown = focusedSession else { lastShown = nil; return }
        defer { lastShown = (shown.id, shown.activity) }
        guard !picked, let last = lastShown, last.id == shown.id, last.activity == .work, shown.activity == .sleep else { return }
        let working = store.alive.filter { $0.id != shown.id && $0.activity == .work }.max { $0.lastSeen < $1.lastSeen }
        guard let next = working ?? (front.flatMap { $0.id != shown.id ? $0 : nil }) else { return }
        handoff = (shown.id, next.id, Date().addingTimeInterval(4), key)
        DebugLog.note("done: \(shown.displayName); next \(next.displayName)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.05) { [weak self] in self?.setNeedsRefresh() }
    }

    private func card(for r: PendingRequest, active: Session?) -> AppModel.RequestCard {
        let session = r.sessionId.flatMap { store.sessions[$0] }
        var card = AppModel.RequestCard(id: r.id, kind: r.kind == .permission ? .permission : .question,
                                        project: session?.projectName)
        card.chat = session?.displayName
        card.color = session.map { Session.colors[$0.colorIndex % Session.colors.count] }
        card.elsewhere = session != nil && session?.id != active?.id && store.alive.count > 1
        if r.kind == .permission {
            let s = r.summary
            card.verb = s.verb
            // The widget has room for all of it: the command, the change, the arguments.
            card.detail = r.fullDetail
            card.offersAlways = r.canRemember
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
        let active = focusedSession
        guard let request = currentRequest(active: active), request.kind == .question else { return }
        DebugLog.tap("widget: send typed answer")
        var answer = text
        if let q = request.current, q.multiSelect, !request.picked.isEmpty {
            answer = (request.picked.sorted().map { q.options[$0] } + [text]).joined(separator: ", ")
        }
        model.otherDraft = ""
        advance(request, with: answer)
    }

    /// Brings that chat to the front: a terminal one's tab (Terminal or
    /// iTerm); a VS Code one's window, then the conversation itself (two
    /// can share a window). VS Code is never made to open a new window for
    /// a chat that's already open somewhere.
    private func openSession(_ id: String) {
        guard let session = store.sessions[id] else { NSSound.beep(); return }
        DebugLog.tap("open session \(session.displayName)")
        if session.inDesktopApp {
            // A chat known by its id: Claude Desktop's own link to it, which
            // also brings the app up — started, if it isn't (28.10: from the
            // background, activate() was ignored and nothing came up).
            if let chat = session.desktopChat, chat.hasPrefix("/chat/"),
               ClaudeAIChats.isId(String(chat.dropFirst("/chat/".count))),
               let url = URL(string: "claude://claude.ai" + chat),
               NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
                DebugLog.note("desktop chat open by its link: \(chat)")
                return
            }
            // A Cowork task on this Mac: its page in the app.
            if let chat = session.desktopChat, chat.hasPrefix("/cowork/"), session.isLocalCowork,
               DesktopSessions.isLocal(String(chat.dropFirst("/cowork/".count))),
               let url = URL(string: "claude://claude.ai" + chat),
               NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
                DebugLog.note("desktop chat open by its link: \(chat)")
                return
            }
            // A Claude Code chat of the app: its own link, whatever the app
            // shows (29.10: with Design in front there was no row to press).
            if let local = session.desktopLocal, let url = DesktopSessions.link(local),
               NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
                NSWorkspace.shared.open(url)
                DebugLog.note("desktop code chat open by its link: \(local)")
                return
            }
            // Not known yet: brought up, then the chat's row in its sidebar pressed.
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.desktopBundle).first,
               let url = app.bundleURL {
                let open = NSWorkspace.OpenConfiguration()
                open.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: open)
                if let title = session.desktopTitle ?? session.title {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        self?.desktopChat.open(title: title, in: app) { pressed in
                            DebugLog.note("desktop chat open \(title): \(pressed ? "pressed" : "no row")")
                        }
                    }
                }
            } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.desktopBundle) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
            return
        }
        if session.ambient {
            // Known only from Codex's files, no tty: its tab by the title Codex
            // gives it, "<the chat's name> | <project>" — one such tab, or none
            // brought up (owner, 27.10). Only brought up: nothing typed by it.
            let name = session.displayName
            guard let title = session.title, let cwd = session.cwd else {
                NSSound.beep()
                DebugLog.note("open: \(name) has no name from Codex yet — no tab to bring up")
                return
            }
            Terminals.tabs { tabs in
                let hits = tabs.filter { CodexRollout.isTabTitle($0.title, of: title, in: cwd) }
                guard hits.count == 1 else {
                    NSSound.beep()
                    DebugLog.note("open: \(hits.count) tabs titled for \(name) — not brought up")
                    return
                }
                Terminals.focus(tty: hits[0].tty) { found in if !found { NSSound.beep() } }
            }
            return
        }
        if session.entrypoint != "claude-vscode" {
            // A terminal chat: its tab, else (VS Code's own terminal) its window.
            guard let tty = session.tty else { _ = raiseVSCodeWindow(for: session); return }
            Terminals.focus(tty: tty) { [weak self] found in
                if !found { _ = self?.raiseVSCodeWindow(for: session) }
            }
            return
        }
        let raised = raiseVSCodeWindow(for: session)
        if !raised, let folder = session.startFolder ?? session.cwd {
            // Not seen (another Space, a full-screen window): VS Code itself
            // brings up the window that has the folder — a new one only if none does.
            // The folder the chat started in, not where it went with `cd`
            // since: that one has no window, and got a new one (owner, 27.10).
            guard let path = folder.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: "vscode://file" + path) else { NSSound.beep(); return }
            NSWorkspace.shared.open(url)
        }
        // The Claude extension opens a conversation by its id.
        guard let url = URL(string: "vscode://anthropic.claude-code/open?session=\(id)") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + (raised ? 0.3 : 1.5)) {
            NSWorkspace.shared.open(url)
        }
    }

    /// Raises the VS Code window that shows this chat: by the chat's title,
    /// else its project's folder, else a folder it sits in.
    private func raiseVSCodeWindow(for session: Session) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.microsoft.VSCode").first
        else { return false }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.5)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.pathComponents.count
        let folders = session.cwd.map { Array(URL(fileURLWithPath: $0).pathComponents.dropFirst(home)) } ?? []
        let start = session.startFolder.map { URL(fileURLWithPath: $0).lastPathComponent }
        var best: (score: Int, window: AXUIElement)?
        for window in windows {
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
                  let text = title as? String else { continue }
            let parts = SessionStore.titleParts(text)
            var score = 0
            // A name another chat has too raises no window by it (review, 27.10).
            if session.windowTitles.contains(where: parts.contains),
               !store.alive.contains(where: { $0 !== session && $0.windowTitles.contains(where: parts.contains) }) { score = 3 }
            else if let start, parts.contains(start) { score = 2 }
            // Where cd went has a window only by chance: the start folder's wins.
            else if let last = folders.last, parts.contains(last) { score = start == nil ? 2 : 1 }
            else if folders.contains(where: parts.contains) { score = 1 }
            if score > (best?.score ?? 0) { best = (score, window) }
        }
        guard let window = best?.window else { return false }
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        app.activate(options: [])
        return true
    }

    // MARK: - Voice

    private func setUpVoice() {
        rightOption.onStart = { [weak self] in self?.voiceBegin() }
        rightOption.onEnd = { [weak self] in self?.voice.stop() }
        rightOption.start()
        voice.onPartial = { [weak self] text in
            guard let self else { return }
            if self.voiceIntoBar {
                // The words as they come, right in the bar's message line.
                self.typing.set(Self.join(self.voiceBarBase, text))
            } else {
                self.model.heard = text
            }
        }
        voice.onLog = { DebugLog.note("voice: \($0)") }
        voice.onMessage = { [weak self] message in
            guard let self else { return }
            DebugLog.note(message)
            self.voiceMessageShown = true
            self.model.heard = message
        }
        voice.onFinal = { [weak self] text in
            guard let self else { return }
            if let id = self.voiceFor {
                // Into that chat's composer in the Chats tab, to read over and send.
                self.voiceFor = nil
                if let text {
                    self.model.chatDrafts[id] = Self.join(self.model.chatDrafts[id] ?? "", text)
                } else {
                    self.showNote(self.voiceMessageShown ? self.model.heard : "Didn't catch that — try again", for: id)
                }
                self.voiceMessageShown = false
                self.model.listeningFor = nil
                self.model.heard = ""
                (self.config.widget ? self.widget.state : self.drawer.state).focusComposer += 1
                return
            }
            if self.voiceIntoBar {
                // Stays in the line, to edit and send from the bar.
                if let text { self.typing.set(Self.join(self.voiceBarBase, text)) }
                self.voiceIntoBar = false
                self.model.listening = false
                self.model.heard = ""
                self.setNeedsRefresh()
                return
            }
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

    /// The checked words go where the widget's message box sends them: to
    /// the queue (when Claude is free), or typed into the chat with Enter.
    private func sendDictated() {
        guard let text = model.dictated?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        model.dictated = nil
        widget.update()
        DebugLog.tap("send dictated (\(text.count) characters)")
        if config.taskQueue && focusedSession != nil {
            model.addToQueue(text)
        } else {
            deliver(text, to: focusedSession)
        }
    }

    /// Dictating into the Touch Bar's message line (it was open, or the
    /// Touch Bar is all there is): the words show there as they come.
    private var voiceIntoBar = false
    /// Dictating into a chat's composer in the Chats tab (its mic, or right
    /// ⌥ while it's open): the words land there, for that chat.
    private var voiceFor: String?
    /// What the line held before you spoke.
    private var voiceBarBase = ""

    private static func join(_ a: String, _ b: String) -> String {
        [a, b].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func voiceBegin(stopAfterPause: TimeInterval? = nil, into chat: String? = nil) {
        guard !voice.isRunning, !model.listening, model.listeningFor == nil else { return }
        DebugLog.tap(stopAfterPause == nil ? "voice (hold ⌥)" : "voice (mic)")
        voice.stopAfterPause = stopAfterPause
        // A chat's composer in the Chats tab: its words, there — unless the
        // bar's line is open, which is where you're writing.
        voiceFor = chat ?? (typing.isActive ? nil : composerOpen)
        // Only the Touch Bar (no widget): its message line opens for the words.
        if voiceFor == nil, !typing.isActive, !config.widget, barShouldShow, currentRequest(active: focusedSession) == nil {
            openLine()
        }
        voiceIntoBar = voiceFor == nil && typing.isActive
        voiceBarBase = voiceIntoBar ? typing.text : ""
        model.listeningFor = voiceFor
        model.listening = !voiceIntoBar && voiceFor == nil // the widget shows it only when it's the widget's
        model.heard = ""
        widget.update()
        setNeedsRefresh()
        if let request = typingFor ?? currentRequest(active: nil), request.kind == .question { extendHold(request) }
        voice.start(language: config.voiceLanguage, allowServer: config.voiceAllowServer)
    }

    /// The Chats tab's composer open in the widget (or the island): its chat.
    private var composerOpen: String? {
        guard config.widget || drawer.shown else { return nil }
        let state = config.widget ? widget.state : drawer.state
        return state.mode == .chats ? state.composerChat : nil
    }

    /// Dictated text goes where you'd type it: the bar's answer field, the
    /// widget's "Other" field, or else the app in front — without Enter.
    private func deliverVoice(_ text: String) {
        if typing.isActive {
            typing.insert(text)
        } else if model.request?.kind == .question, widget.state.mode == .panel {
            model.otherDraft = model.otherDraft.isEmpty ? text : model.otherDraft + " " + text
        } else if config.voiceReview && config.widget {
            // To check in the widget first ("Say more" adds to it).
            let before = (model.dictated ?? "").trimmingCharacters(in: .whitespaces)
            model.dictated = before.isEmpty ? text : before + " " + text
        } else if claudeAppInFront && !safeToType() {
            // Claude's own permission menu is open there: a "2" in your words
            // would pick an option. Kept on the dictation card instead.
            let before = (model.dictated ?? "").trimmingCharacters(in: .whitespaces)
            model.dictated = before.isEmpty ? text : before + " " + text
        } else {
            widget.releaseKey()
            KeySender.type(text)
        }
        DebugLog.note("voice: \(text.count) characters into " + (typing.isActive ? "the Touch Bar answer" : model.request?.kind == .question && widget.state.mode == .panel ? "the widget's Other field" : NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"))
    }

    // MARK: - Stage 3: hotkeys, templates, queue, auto-compact, screenshot

    /// Global shortcuts for the buttons the bar shows now, and the menu's.
    private func updateHotKeys(_ active: Session?) {
        let shortcuts = config.buttons(for: active?.projectName).compactMap { spec -> (combo: String, action: () -> Void)? in
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
        let active = focusedSession
        let date = DateFormatter()
        date.dateFormat = "yyyy-MM-dd"
        return template
            .replacingOccurrences(of: "{project}", with: active?.projectName ?? "")
            .replacingOccurrences(of: "{branch}", with: active.flatMap(branch(of:)) ?? "")
            .replacingOccurrences(of: "{clipboard}", with: NSPasteboard.general.string(forType: .string) ?? "")
            .replacingOccurrences(of: "{date}", with: date.string(from: Date()))
    }

    private func insertTemplate(_ template: String) {
        DebugLog.tap("template")
        widget.releaseKey()
        KeySender.type(expand(template)) // no Enter: read it over first
    }

    /// Its git branch: of the folder it started in, else of the file it
    /// touched last. Looked up at most every 5 s.
    private func branch(of s: Session) -> String? {
        let key = s.id + "|" + (s.workPath ?? "")
        if let c = branchCache[key], Date().timeIntervalSince(c.at) < 5 { return c.branch }
        let b = s.branch
        branchCache[key] = (b, Date())
        return b
    }

    /// Context over the threshold, Claude idle, its window in front: /compact.
    private func autoCompact(_ session: Session) {
        guard session.activity == .sleep, !session.waitingNotice,
              !requests.contains(where: { $0.sessionId == session.id }),
              store.session(inWindow: frontTitle, tty: frontTTY)?.id == session.id,
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
            self.queueOrSend(text, to: self.focusedSession)
        }
        model.sendTo = { [weak self] text, id in self?.send(text, to: id) }
        model.screenshotTo = { [weak self] id in self?.takeScreenshot(into: id) }
        model.dropFilesTo = { [weak self] urls, id in self?.attach(urls, to: id) ?? false }
        model.removeAttachmentFrom = { [weak self] path, id in self?.detach(path, from: id) }
        model.voiceTo = { [weak self] id in
            guard let self else { return }
            if self.voice.isRunning || self.model.listening || self.model.listeningFor != nil {
                self.voice.stop()
            } else {
                self.voiceBegin(stopAfterPause: 5, into: id)
            }
        }
        model.removeFromQueue = { [weak self] id in
            DebugLog.tap("queue: removed by hand")
            self?.queue.removeAll { $0.id == id }
            self?.saveQueue()
            self?.refresh()
        }
        model.sendQueuedNow = { [weak self] id in self?.sendQueuedNow(id) }
        model.runMenuButton = { [weak self] in self?.runMenu($0) }
        model.takeScreenshot = { [weak self] in self?.takeScreenshot() }
        model.dropFiles = { [weak self] urls in self?.attach(urls) ?? false }
        model.removeAttachment = { [weak self] path in
            guard let self, let active = self.focusedSession else { return }
            self.detach(path, from: active.id)
        }
        model.insertAttachments = { [weak self] in self?.insertAttachments() }
        model.setModel = { [weak self] alias in self?.switchModel("/model " + alias) }
        model.setEffort = { [weak self] level in self?.switchModel("/effort " + level) }
    }

    private func saveQueue() {
        if let data = try? JSONEncoder().encode(queue) { try? data.write(to: queueURL, options: .atomic) }
    }

    /// The widget's words for a chat, the files dropped for it after them.
    /// Straight in where its chat takes that (VS Code's Claude, through the
    /// wrapper; a chat Codex's server has loaded): no window, no keys,
    /// wherever you are — when the agent is free and nothing of yours waits
    /// before it. Else the queue, one at a time as it gets free (owner,
    /// 27.10), or until its chat is in front — never a window switched.
    /// `kept`: Claude's side didn't take it after all, so it's queued.
    @discardableResult
    private func queueOrSend(_ text: String, to session: Session?, kept: (() -> Void)? = nil) -> Delivery? {
        // Dropped files go along, after the words.
        let files = session.flatMap { attachments.removeValue(forKey: $0.id) } ?? []
        let full = ([text] + files.map(FileDrop.quoted)).filter { !$0.isEmpty }.joined(separator: " ")
        guard !full.isEmpty else { return nil }
        if let s = session, Delivery.route(direct: straightIn(s, files: files), free: isFree(s),
                                           queuedBefore: queue.contains(where: { $0.sessionId == s.id }), waits: true) == .now {
            DebugLog.tap("send straight to " + (s.entrypoint == "codex" ? "Codex" : "Claude") + (files.isEmpty ? "" : " with \(files.count) file(s)"))
            inject(text, files: files, into: s) { [weak self] in
                self?.enqueue(full, for: session)
                kept?()
            }
            return .now
        }
        enqueue(full, for: session)
        DebugLog.tap("queue add (\(queue.count))" + (files.isEmpty ? "" : " with \(files.count) file(s)"))
        return .queue
    }

    /// Words for a chat picked by name — the Chats tab's composer, the bar's
    /// line opened from its list — whatever the widget follows (owner, 27.10:
    /// write to any chat without switching to it). That chat's own rules
    /// (queueOrSend): straight in, else its queue — a chat that takes only
    /// keys gets them once it's surely in front, or with Send now. A chat
    /// that has ended isn't swapped for another: nothing is sent.
    private func send(_ text: String, to id: String) {
        guard let target = Delivery.target(addressed: id, followed: focusedSession?.id,
                                           isAlive: { [store] in store.sessions[$0]?.isAlive() ?? false }),
              let session = store.sessions[target] else {
            NSSound.beep()
            showNote("That chat has ended — not sent", for: id)
            DebugLog.note("send: the chat picked has ended — not sent")
            return
        }
        let name = Self.short(session.displayName, 28)
        let direct = straightIn(session)
        let route = queueOrSend(text, to: session) { [weak self] in
            // Not taken: where it goes now (claude.ai refused it — keys, review 29.10).
            guard let self else { return }
            self.showNote(Delivery.note(.queue, direct: self.straightIn(session), to: name), for: id)
        }
        if let route { showNote(Delivery.note(route, direct: direct, to: name), for: id) }
    }

    /// The Chats tab's line after Send: where the words are, for a moment.
    private func showNote(_ text: String, for chat: String) {
        let note = AppModel.SentNote(chat: chat, text: text)
        model.sentNote = note
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.model.sentNote == note { self?.model.sentNote = nil }
        }
    }

    /// When each chat was last handed a message: until its hook says Claude
    /// took it, the chat counts as busy, so the next one waits its turn.
    private var handedAt: [String: Date] = [:]

    /// Claude has finished its reply there and asks nothing (Delivery.free).
    private func isFree(_ session: Session) -> Bool {
        Delivery.free(session, asking: requests.contains(where: { $0.sessionId == session.id }),
                      handedAt: handedAt[session.id], sending: codexSending.contains(session.id) || remoteSending.contains(session.id))
    }

    /// Codex chats a message is on its way to (its server answers within
    /// half a minute): busy till then, so the next one isn't added to its turn.
    private var codexSending = Set<String>()

    /// Sends a chat's next queued message once Claude there has finished a
    /// reply: straight in where its chat takes that, else typed once its
    /// window is in front (like a button). Each chat's own in order; one
    /// chat waiting doesn't hold up another's.
    private func dispatchQueue() {
        for id in queue.compactMap(\.sessionId) { store.keepLocalCowork(id) }
        let gone = queue.filter { $0.sessionId.flatMap { store.sessions[$0] } == nil }
        if !gone.isEmpty {
            queue.removeAll { $0.sessionId.flatMap { store.sessions[$0] } == nil }
            saveQueue()
            for g in gone { DebugLog.note("queue: dropped, its chat is gone (\(g.project ?? g.sessionId ?? "no chat"))") }
        }
        guard Date().timeIntervalSince(queueSentAt ?? .distantPast) > 10 else { return }
        var seen = Set<String>()
        for (i, next) in queue.enumerated() {
            guard let id = next.sessionId, let session = store.sessions[id], seen.insert(id).inserted,
                  isFree(session), Date().timeIntervalSince(session.activitySince) > 1.5 else { continue }
            // Files dropped for it wait at its end, as paths: they go as files.
            let parts = Inject.split(next.text)
            // A Cowork task on this Mac: into its window if that shows it, its
            // place in the queue kept till it's gone. Else keys, as below.
            if Date() < (fieldTaken[id] ?? .distantPast) { continue }
            if parts.files.isEmpty, session.isLocalCowork, Date() >= (quietHeld[id] ?? .distantPast) {
                sendQuietly(parts.words, into: session) { [weak self] result in
                    guard result == .gone, let self else { return }
                    self.queue.removeAll { $0.id == next.id }
                    self.saveQueue()
                    self.setNeedsRefresh()
                }
                continue
            }
            if straightIn(session, files: parts.files) {
                queue.remove(at: i)
                saveQueue()
                queueSentAt = Date()
                DebugLog.note("queue: sent straight to \(session.displayName), \(queue.count) left")
                inject(parts.words, files: parts.files, into: session) { [weak self] in
                    self?.queue.insert(next, at: 0)
                    self?.saveQueue()
                    self?.setNeedsRefresh()
                }
                return
            }
            // In front a moment already: just switched to, its field may not
            // take the first letters yet.
            // Never while you write in one of our fields: typing would take
            // the keyboard from it mid-word (review, 27.10).
            guard chatInFront(id), Date().timeIntervalSince(frontSince.at) > 1.2,
                  Delivery.keysFree(barTyping: typing.isActive, ourKeyWindow: NSApp.keyWindow != nil) else { continue }
            queue.remove(at: i)
            saveQueue()
            queueSentAt = Date()
            handedAt[id] = Date()
            DebugLog.note("queue: sent to \(session.projectName ?? session.id), \(queue.count) left")
            typeAfterReleasingKey(next.text, for: session)
            return
        }
    }

    /// Send now: straight in where its chat takes that (while Claude works,
    /// Claude Code queues them itself; Codex's server adds them to the turn
    /// running), else its chat brought to the front
    /// and the words typed in at once. If the chat doesn't come up, it goes
    /// back to the head of the queue.
    private func sendQueuedNow(_ id: UUID) {
        guard let i = queue.firstIndex(where: { $0.id == id }) else { return }
        // On its way already: the queue is sending this very one.
        if let chat = queue[i].sessionId, chat.hasPrefix("coworklocal-"), remoteSending.contains(chat) {
            NSSound.beep()
            return
        }
        let item = queue.remove(at: i)
        saveQueue()
        refresh()
        guard let session = item.sessionId.flatMap({ store.sessions[$0] }) else { return }
        DebugLog.tap("queue: send now → \(session.displayName)")
        let parts = Inject.split(item.text)
        if parts.files.isEmpty, session.isLocalCowork {
            let id = session.id
            sendQuietly(parts.words, into: session) { [weak self] result in
                guard result != .gone, let self else { return }
                if !self.chatInFront(id) { self.openSession(id) }
                if result == .fieldTaken {
                    // Yours in its field: shown to you, the words wait.
                    self.queue.insert(item, at: 0)
                    self.saveQueue()
                    self.setNeedsRefresh()
                } else {
                    self.typeWhenInFront(item, session: id, tries: 16, since: Date())
                }
            }
            return
        }
        if straightIn(session, files: parts.files) {
            inject(parts.words, files: parts.files, into: session) { [weak self] in
                self?.queue.insert(item, at: 0)
                self?.saveQueue()
                self?.refresh()
            }
            return
        }
        // You asked for it: its chat brought forward, then typed into.
        if !chatInFront(session.id) { openSession(session.id) }
        typeWhenInFront(item, session: session.id, tries: 16, since: Date())
    }

    /// A local Cowork task: not tried again till then, after its window didn't
    /// show it (soon) or its field turned the words down (for a while).
    private var quietHeld: [String: Date] = [:]
    /// Something of yours in its field: neither way for now.
    private var fieldTaken: [String: Date] = [:]

    enum QuietResult { case gone, notSent, fieldTaken }

    /// Its words into Claude Desktop's window, if it shows this task. Busy
    /// meanwhile, so the keys don't overtake.
    private func sendQuietly(_ words: String, into session: Session, done: @escaping (QuietResult) -> Void) {
        let id = session.id
        guard let page = session.desktopChat,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: Self.desktopBundle).first else {
            quietHeld[id] = Date().addingTimeInterval(15)
            done(.notSent)
            return
        }
        remoteSending.insert(id)
        desktopChat.sendQuietly(words, page: page, in: app) { [weak self] result in
            guard let self else { return }
            self.remoteSending.remove(id)
            DebugLog.note("local cowork: send \(result)")
            switch result {
            case .sent:
                self.handedAt[id] = Date()
                self.queueSentAt = Date()
                self.store.markSent(id)
                done(.gone)
            case .unsure:
                // Pressed: it may have gone. Not again; they're still in its field.
                NSSound.beep()
                self.handedAt[id] = Date()
                self.queueSentAt = Date()
                done(.gone)
            case .busy:
                self.fieldTaken[id] = Date().addingTimeInterval(15)
                done(.fieldTaken)
            case .notShown:
                self.quietHeld[id] = Date().addingTimeInterval(15)
                done(.notSent)
            case .refused:
                self.quietHeld[id] = Date().addingTimeInterval(60)
                done(.notSent)
            }
            self.setNeedsRefresh()
        }
    }

    /// A message into the queue for this chat.
    private func enqueue(_ text: String, for session: Session?) {
        queue.append(.init(text: text, sessionId: session?.id, project: session?.projectName))
        saveQueue()
        refresh()
    }

    /// Its words go straight in: Claude's input (VS Code, through the
    /// wrapper), Codex's own server for a chat it has loaded, or claude.ai.
    private func straightIn(_ session: Session, files: [String] = []) -> Bool {
        Delivery.direct(session, codexLoaded: codexDirect(session),
                        remote: remoteDirect(session) != nil || (files.isEmpty && chatDirect(session)))
    }

    /// A plain claude.ai chat (Chrome, Claude Desktop's Chat tab): words alone
    /// go into it as its page sends them, whatever window is in front (owner,
    /// 30.10). Turned down: keys, for 10 minutes. Pictures: keys, for now.
    private func chatDirect(_ session: Session) -> Bool {
        claudeAI.canSend && session.entrypoint == "claude-ai" && session.id.hasPrefix("claudeai-")
            && Date().timeIntervalSince(remoteRefused[session.id] ?? .distantPast) > 600
    }

    private func sendToPlainChat(_ text: String, into session: Session, fallback: @escaping () -> Void) {
        let name = session.displayName, id = session.id
        handedAt[id] = Date()
        remoteSending.insert(id)
        claudeAI.sendToChat(text, chat: String(id.dropFirst("claudeai-".count))) { [weak self] result in
            guard let self else { return }
            self.remoteSending.remove(id)
            switch result {
            case .sent:
                DebugLog.note("sent into its chat on claude.ai (\(name))")
                self.store.markSent(id)
                self.queueSentAt = Date()
                self.claudeAI.lookSoon()
                self.setNeedsRefresh()
            case .kept(let why):
                self.remoteRefused[id] = Date()
                DebugLog.note("its chat didn't take it (\(name)): \(why) — kept, typed once its chat is in front")
                fallback()
            case .offline:
                DebugLog.note("no connection to claude.ai (\(name)) — kept for later")
                fallback()
            case .unsure(let why):
                NSSound.beep()
                DebugLog.note("claude.ai's chat: \(why) (\(name)) — maybe sent, not sent again")
            }
        }
    }

    private let remoteControlQueue = DispatchQueue(label: "cloudingbar.remote-control")
    private let desktopCache = DesktopSessions.Cache()

    /// Chats that may take words through Remote Control: the desktop app's
    /// Claude Code chats (their link and Remote Control from its own files)
    /// and Terminal's (from Claude Code's record of each) — their cards then
    /// asked of claude.ai. Files read off the main thread (review, 29.10).
    private func followRemoteControl() {
        let alive = store.alive
        let desktop = alive.contains { $0.entrypoint == "claude-desktop" }
        let terminals = alive.filter { $0.entrypoint == "cli" }.compactMap { s in s.claudePid.map { (id: s.id, pid: $0) } }
        guard desktop || !terminals.isEmpty else { followBridges(); return }
        remoteControlQueue.async { [desktopCache] in
            let entries = desktop ? DesktopSessions.read(cache: desktopCache) : nil
            var bridges: [String: String] = [:]
            for t in terminals { bridges[t.id] = ClaudeSessions.bridge(pid: t.pid, session: t.id) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let entries { self.store.apply(desktop: entries) }
                self.store.apply(terminalBridges: bridges, checked: terminals.map(\.id))
                self.followBridges()
            }
        }
    }

    /// The Remote Control sessions whose cards claude.ai is asked for.
    private func followBridges() {
        let bridges = Set(store.alive.filter { $0.entrypoint == "claude-desktop" || $0.entrypoint == "cli" }.compactMap(\.remoteSession))
        guard bridges != claudeAI.bridges else { return }
        claudeAI.bridges = bridges
        remoteCards = remoteCards.filter { !$0.value.bridge || bridges.contains($0.key) }
    }

    /// claude.ai's cards of the sessions it holds, by "cse_…" (ClaudeAI.onRemote).
    private var remoteCards: [String: ClaudeAIChats.Remote] = [:]
    /// Cowork's numbers for Stats, from those cards.
    private let coworkLedger = CoworkLedger()
    /// claude.ai refused words for these: keys again for a while, not the
    /// same refusal every 10 s.
    private var remoteRefused: [String: Date] = [:]
    /// Answers sent through claude.ai: its card may still show the request
    /// a moment — not offered again.
    private var remoteAnswered: [String: Date] = [:]
    /// …nor read again from Desktop's window, which shows it till Claude moves on.
    private var remoteJustAnswered: [(request: PendingRequest, at: Date)] = []
    /// Words on their way to claude.ai, by chat: busy till it says it took
    /// them, so the next in its queue doesn't overtake (review, 29.10).
    private var remoteSending = Set<String>()

    /// Where its words go through claude.ai ("cse_…"): a Cowork task, or a
    /// desktop Code or Terminal chat whose Remote Control is on the line —
    /// wherever its window is (owner, 29.10). Nil: keys, as before.
    private func remoteDirect(_ session: Session) -> String? {
        guard claudeAI.canSend, let id = session.remoteSession,
              Date().timeIntervalSince(remoteRefused[id] ?? .distantPast) > 600 else { return nil }
        if session.entrypoint == "cowork" { return id }
        guard session.entrypoint == "claude-desktop" || session.entrypoint == "cli", let card = remoteCards[id],
              card.bridge, card.connected, !card.archived else { return nil }
        return id
    }

    /// Its words through claude.ai, as yours: refused, they're kept
    /// (`fallback`); no telling, not sent again, lest Claude get them twice.
    private func sendToClaudeAI(_ text: String, files: [String], into session: Session, remote: String,
                                fallback: @escaping () -> Void) {
        guard let content = Inject.content(text, files: files) else { fallback(); return }
        handedAt[session.id] = Date()
        let name = session.displayName, id = session.id
        remoteSending.insert(id)
        let sent = { [weak self] in
            guard let self else { return }
            self.store.markSent(id)
            self.queueSentAt = Date()
            self.claudeAI.lookSoon()
            self.setNeedsRefresh()
        }
        // Into its session: Claude gets it, the chat doesn't show it.
        let throughSession = { [weak self] in
            guard let self else { return }
            self.claudeAI.send(content, to: remote) { [weak self] result in
                guard let self else { return }
                self.remoteSending.remove(id)
                switch result {
                case .sent:
                    DebugLog.note("sent through claude.ai (\(name))")
                    sent()
                case .kept(let why):
                    self.remoteRefused[remote] = Date()
                    DebugLog.note("claude.ai didn't take it (\(name)): \(why) — kept, typed once its chat is in front")
                    fallback()
                case .offline:
                    DebugLog.note("no connection to claude.ai (\(name)) — kept for later")
                    fallback()
                case .unsure(let why):
                    NSSound.beep()
                    DebugLog.note("claude.ai send: \(why) (\(name)) — maybe sent, not sent again")
                }
            }
        }
        // Words alone to a Cowork task: into its chat, as its page sends them,
        // so they show there too (owner, 30.10). Pictures go to its session
        // as before; so do words claude.ai's chat turns down.
        guard files.isEmpty, session.entrypoint == "cowork", id.hasPrefix("cowork-") else { throughSession(); return }
        claudeAI.sendToChat(text, chat: String(id.dropFirst("cowork-".count))) { [weak self] result in
            guard let self else { return }
            switch result {
            case .sent:
                self.remoteSending.remove(id)
                DebugLog.note("sent into its chat on claude.ai (\(name))")
                sent()
            case .kept(let why):
                DebugLog.note("its chat didn't take it (\(name)): \(why) — to its session instead")
                throughSession()
            case .offline:
                self.remoteSending.remove(id)
                DebugLog.note("no connection to claude.ai (\(name)) — kept for later")
                fallback()
            case .unsure(let why):
                self.remoteSending.remove(id)
                NSSound.beep()
                DebugLog.note("claude.ai's chat: \(why) (\(name)) — maybe sent, not sent again")
            }
        }
    }

    /// A session's card from claude.ai. A Cowork task's question or
    /// permission comes only this way (no hook reaches its cloud, and its
    /// window may show something else): on the bar, answered back there.
    private func remoteCard(_ card: ClaudeAIChats.Remote, for id: String) {
        remoteCards[id] = card
        store.apply(coworkCard: card, session: id)
        // Stats: what this read adds to the task's record (owner, 30.10).
        if let task = store.sessions.values.first(where: { $0.entrypoint == "cowork" && $0.remoteSession == id }),
           task.id.hasPrefix("cowork-") {
            coworkLedger.record(card, task: String(task.id.dropFirst("cowork-".count)), model: task.model)
        }
        guard let session = store.alive.first(where: { $0.remoteSession == id && $0.entrypoint == "cowork" }) else { return }
        let current = requests.first { $0.remoteKey != nil && $0.sessionId == session.id }
        if let current, current.remoteKey != card.pending?.requestId {
            finish(current, "cowork: answered in Claude", reply: false)
        }
        remoteAnswered = remoteAnswered.filter { Date().timeIntervalSince($0.value) < 120 }
        guard let pending = card.pending, current?.remoteKey != pending.requestId,
              remoteAnswered[pending.requestId] == nil else { return }
        let name = session.displayName
        let request = PendingRequest(remote: pending, sessionId: session.id) { [weak self] output in
            self?.answerThroughClaudeAI(output, pending: pending, in: id, name: name)
        }
        guard let request else { return }
        // Its window's reading of the same question gives way.
        for r in requests where r.desktopKey != nil && r.sameAsk(as: request) {
            finish(r, "desktop prompt: taken from claude.ai instead", reply: false)
        }
        requests.append(request)
        DebugLog.note("cowork: \(request.kind == .question ? "question" : "permission") on the bar, from claude.ai")
        setNeedsRefresh()
    }

    /// Signed out, or the key turned down: what Cowork tasks asked through
    /// claude.ai leaves the bar (their chats are gone, no list says so).
    private func dropRemoteRequests() {
        for r in requests where r.remoteKey != nil { finish(r, "cowork: signed out of claude.ai — dropped", reply: false) }
        remoteCards = [:]
    }

    /// The bar's answer (what a PermissionRequest hook would print) as
    /// Claude Code's control_response. Not taken: offered again.
    private func answerThroughClaudeAI(_ output: [String: Any], pending: ClaudeAIChats.Pending, in id: String, name: String) {
        guard var decision = (output["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any] else { return }
        // An allow carries the input it runs with: as asked, if not changed.
        if decision["behavior"] as? String == "allow", decision["updatedInput"] == nil { decision["updatedInput"] = pending.input }
        remoteAnswered[pending.requestId] = Date()
        claudeAI.answer(decision, request: pending.requestId, in: id) { [weak self] result in
            switch result {
            case .sent:
                DebugLog.note("cowork: answered through claude.ai (\(name))")
                self?.claudeAI.lookSoon()
            case .kept(let why):
                NSSound.beep()
                self?.remoteAnswered[pending.requestId] = nil
                DebugLog.note("cowork: claude.ai didn't take the answer (\(name)): \(why) — asked again")
            case .offline:
                NSSound.beep()
                self?.remoteAnswered[pending.requestId] = nil
                DebugLog.note("cowork: no connection to claude.ai (\(name)) — asked again")
            case .unsure(let why):
                NSSound.beep()
                DebugLog.note("cowork: \(why) (\(name)) — the answer may have gone in")
            }
        }
    }

    /// A Codex chat its own server has loaded (Terminal's codex, 0.164 on):
    /// its words go in by the chat's id — never typed, never a tab guessed.
    private func codexDirect(_ session: Session) -> Bool {
        config.codexServer && session.entrypoint == "codex" && session.codexWindowOpen && codexServer.canSend(to: session.id)
    }

    /// Hands it to Claude's input (Inject): off the main thread, then the
    /// chat's echo shows it. If Claude's side doesn't take it, `fallback`.
    /// A Codex chat's go to Codex's server instead; a Cowork task's, or a
    /// desktop Code chat's with Remote Control, to claude.ai.
    private func inject(_ text: String, files: [String] = [], into session: Session, fallback: @escaping () -> Void) {
        if let remote = remoteDirect(session) {
            sendToClaudeAI(text, files: files, into: session, remote: remote, fallback: fallback)
            return
        }
        if files.isEmpty, chatDirect(session) {
            sendToPlainChat(text, into: session, fallback: fallback)
            return
        }
        if codexDirect(session) {
            handedAt[session.id] = Date()
            sendToCodex(text, files: files, into: session, fallback: fallback)
            return
        }
        guard let pid = session.claudePid, let data = Inject.message(text, files: files) else {
            fallback()
            return
        }
        handedAt[session.id] = Date()
        let name = session.displayName
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Inject.send(data, pid: pid)
            DispatchQueue.main.async { [weak self] in
                DebugLog.note(ok ? "sent straight to Claude (\(name))" : "Claude's input didn't take it (\(name)): kept")
                if ok {
                    self?.queueSentAt = Date()
                    self?.setNeedsRefresh()
                } else {
                    fallback()
                }
            }
        }
    }

    /// Into a Codex chat through Codex's own server, as yours: dropped files
    /// go as their paths in the words, as the queue has them. Codex's
    /// approvals for it come in its own window (and on the bar with Connect).
    /// No answer: it may have gone in — not sent again, lest Codex get it twice.
    private func sendToCodex(_ text: String, files: [String], into session: Session, fallback: @escaping () -> Void) {
        let words = ([text] + files.map(FileDrop.quoted)).filter { !$0.isEmpty }.joined(separator: " ")
        let name = session.displayName, id = session.id
        // Its Codex looked at again now, not 10 s ago: just quit, the chat is
        // still loaded and would run with no window (review, 27.10).
        guard let cwd = session.cwd, Tty.codexFolders([cwd]).contains(cwd) else {
            session.codexWindowOpen = false
            DebugLog.note("Codex isn't running in \(name)'s folder any more — kept")
            fallback()
            return
        }
        codexSending.insert(id)
        codexServer.send(words, to: id) { [weak self] result in
            self?.codexSending.remove(id)
            switch result {
            case .sent:
                DebugLog.note("sent straight to Codex (\(name))")
                self?.queueSentAt = Date()
                self?.handedAt[id] = Date()
                self?.setNeedsRefresh()
            case .kept(let why):
                DebugLog.note("Codex's server didn't take it (\(name)): \(why) — kept")
                fallback()
            case .unsure(let why):
                NSSound.beep()
                DebugLog.note("Codex's server didn't answer (\(name)): \(why) — maybe sent, not sent again")
            }
        }
    }

    private func typeWhenInFront(_ item: AppModel.QueueItem, session id: String, tries: Int,
                                 since started: Date, requeue: Bool = true) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            // Its window just asked forward: the title read before may still be
            // the old one. A second, and in front a moment, before any key.
            if Date().timeIntervalSince(started) > 1, Date().timeIntervalSince(self.frontSince.at) > 0.5,
               self.chatInFront(id) {
                self.queueSentAt = Date()
                if self.typeAfterReleasingKey(item.text, for: self.store.sessions[id]) { DebugLog.note("queue: sent now") }
            } else if tries > 0 {
                self.typeWhenInFront(item, session: id, tries: tries - 1, since: started, requeue: requeue)
            } else {
                // Its chat didn't come up: kept, not typed into another app.
                if requeue || self.config.taskQueue {
                    self.queue.insert(item, at: 0)
                    self.saveQueue()
                    self.refresh()
                }
                NSSound.beep()
                DebugLog.note("send: its chat didn't come to the front — " + (requeue || self.config.taskQueue ? "back in the queue" : "not sent"))
            }
        }
    }

    /// Types into the chat in front — after a moment if the widget had the
    /// keyboard, so the first letters don't go missing on the way back.
    @discardableResult
    /// `chat`: the one the words are for — held back, they wait in its
    /// queue, not a chat guessed from the window (review, 27.10).
    private func typeAfterReleasingKey(_ text: String, for chat: Session?) -> Bool {
        // One of our own fields has the keyboard — the bar's line, the
        // island's, Settings: the keys would land there, and its Return send
        // them to whichever chat it's addressed to (review, 27.10).
        let oursHasKeys = typing.isActive || (NSApp.keyWindow != nil && !widget.ownsKey)
        guard safeToType(), !oursHasKeys else {
            // Claude's own permission menu may be open there: kept in the
            // queue, out once Claude has moved on — not lost.
            let front = chat ?? store.session(inWindow: frontTitle, tty: frontTTY) ?? focusedSession
            queue.insert(.init(text: text, sessionId: front?.id, project: front?.projectName), at: 0)
            saveQueue()
            refresh()
            DebugLog.note(oursHasKeys ? "send: held in the queue while you write in one of our fields" : "send: held in the queue while Claude asks for permission")
            return false
        }
        let hadKey = widget.releaseKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + (hadKey ? 0.25 : 0)) {
            KeySender.type(text, pressReturn: true)
        }
        return true
    }

    /// The window or tab in front, and since when (the queue waits until
    /// it has been there a moment).
    private var frontSince: (key: String, at: Date) = ("", .distantPast)

    /// That chat is surely the one in front (its window or tab, or the page
    /// Claude Desktop shows) — never a guess, as words are typed into it.
    private func chatInFront(_ id: String) -> Bool {
        guard let app = frontApp else { return false }
        if app.bundleIdentifier == Self.desktopBundle {
            return store.session(inDesktop: frontTitle, chat: desktopShown?.chat)?.id == id
        }
        // Another app in front (a browser): the window title read last is
        // its editor's from before, and keys would go to that other app.
        guard isTerminal(app) else { return false }
        return store.session(inWindow: frontTitle, tty: frontTTY, naming: true)?.id == id
    }

    /// A message for this chat (the widget's box, the bar, the voice card):
    /// straight in where its chat takes that (Claude's input, Codex's
    /// server), else typed in once its chat is in front. No chat known: left
    /// in a Claude app's field without Enter — never sent into whatever app
    /// is in front.
    private func deliver(_ text: String, to session: Session?) {
        guard let session else {
            guard claudeAppInFront, safeToType() else { NSSound.beep(); DebugLog.note("send: no chat known — not sent"); return }
            widget.releaseKey()
            KeySender.type(text)
            return
        }
        if straightIn(session) {
            // Codex at work: its server would add the words to the turn
            // running, so they wait for it to end, as Claude Code keeps them.
            let route = Delivery.route(direct: true, free: isFree(session),
                                       queuedBefore: queue.contains { $0.sessionId == session.id }, waits: codexDirect(session))
            if route == .now {
                inject(text, into: session) { [weak self] in self?.enqueue(text, for: session) }
            } else {
                enqueue(text, for: session)
                DebugLog.note("send: Codex is at work — queued until its turn ends")
            }
        } else if chatInFront(session.id) {
            typeAfterReleasingKey(text, for: session)
        } else {
            enqueue(text, for: session) // goes once its chat is in front
            DebugLog.note("send: its chat isn't in front — queued")
        }
    }

    /// /model or /effort, typed into the chat in front like a button's
    /// command. Claude Code switches at once and notes it in the transcript.
    private func switchModel(_ command: String) {
        DebugLog.tap(command)
        // No chat: /model would go to the shell or the file in front.
        guard focusedSession != nil, claudeAppInFront, safeToType() else {
            NSSound.beep()
            barPendingModel = nil
            barPendingEffort = nil
            setNeedsRefresh()
            return
        }
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
        templatesIntoDraft = false
        // Back at the list from the line written for a chat, and none picked
        // there: its words don't wait to go to another.
        if barPanel == .chats, !composing, composeTo != nil {
            composeTo = nil
            composeDraft = ""
        }
        guard barPanel != nil || barPendingModel != nil || barPendingEffort != nil else { return }
        barPanel = nil
        barPendingModel = nil
        barPendingEffort = nil
        setNeedsRefresh()
    }

    /// Files dropped on the widget wait for the session it shows — or, `to`
    /// a chat picked in the Chats tab, for that one (never the chat followed
    /// in its place).
    private func attach(_ urls: [URL], to id: String? = nil) -> Bool {
        let target: Session?
        if let id { target = store.sessions[id] } else { target = focusedSession }
        guard let active = target else { return false }
        attachments = attachments.filter { store.sessions[$0.key] != nil } // sessions gone
        var list = attachments[active.id] ?? []
        for url in urls where !list.contains(url.path) { list.append(url.path) }
        attachments[active.id] = list
        DebugLog.tap("dropped \(urls.count) file(s) for \(active.projectName ?? active.id), \(list.count) waiting")
        refresh()
        return true
    }

    /// A file taken off a chat's.
    private func detach(_ path: String, from id: String) {
        attachments[id]?.removeAll { $0 == path }
        if attachments[id]?.isEmpty == true { attachments[id] = nil }
        refresh()
    }

    /// Insert: the paths go into the chat in front right away, without
    /// Enter, like a screenshot's. Only into that session's own chat.
    private func insertAttachments() {
        guard let active = focusedSession,
              store.session(inWindow: frontTitle, tty: frontTTY)?.id == active.id,
              let files = attachments.removeValue(forKey: active.id), !files.isEmpty else { NSSound.beep(); return }
        DebugLog.tap("insert \(files.count) file(s) into \(active.projectName ?? active.id)")
        widget.releaseKey()
        KeySender.type(files.map(FileDrop.quoted).joined(separator: " ") + " ")
        refresh()
    }

    /// A screenshot for one chat — its composer in the Chats tab, or the
    /// bar's line written for it: attached to that chat, never typed into the
    /// app in front (it may not be that chat's window), and back in that
    /// composer or line to go with your words. The chat followed stays.
    private func takeScreenshot(into id: String) {
        guard let session = store.sessions[id] else { NSSound.beep(); return }
        DebugLog.tap("screenshot for \(session.displayName)")
        widget.releaseKey()
        Screenshot.take { [weak self] path in
            guard let self else { return }
            // Taken or cancelled, the keys go back to where you write to that
            // chat: left with none, its field still looked ready and your
            // words went to the app in front (review, 27.10).
            defer {
                if self.composing && self.composeTo == id {
                    self.typing.refocus() // its chip counts the file; the keys back to the line
                } else if self.config.widget {
                    self.widget.openComposer(id)
                } else {
                    self.drawer.openComposer(id)
                }
            }
            guard let path else { return } // cancelled
            guard self.attach([URL(fileURLWithPath: path)], to: id) else { NSSound.beep(); return }
            DebugLog.note("screenshot → attached to \(session.displayName)")
        }
    }

    private func takeScreenshot() {
        DebugLog.tap("screenshot")
        widget.releaseKey()
        // Where it goes is decided now: the app in front may change while
        // you pick the area.
        let intoChat = inClaudeApp
        let intoDesktop = frontApp?.bundleIdentifier == Self.desktopBundle
        Screenshot.take { [weak self] path in
            guard let self, let path else { return } // cancelled
            if intoDesktop {
                // Its Design, Cowork and chats can't read a path on this Mac;
                // its Code chats take a pasted picture too.
                self.widget.releaseKey()
                Screenshot.paste(path)
                DebugLog.note("screenshot → pasted into Claude Desktop")
            } else if intoChat {
                self.widget.releaseKey()
                KeySender.type(path + " ")
                DebugLog.note("screenshot → path typed")
            } else if self.attach([URL(fileURLWithPath: path)]) {
                // Another app in front: not typed there, but attached to the
                // chat shown, to go with your next message — in the widget,
                // or, with the widget off, on the island the Touch Bar's Cloud
                // calls up (owner, 24.10: never off to the chat's window).
                if self.config.widget { self.widget.openMessage() } else { self.drawer.openMessage() }
                self.refresh()
                DebugLog.note("screenshot → attached to the chat shown")
            }
        }
    }

    // MARK: - Updates

    private func setUpUpdates() {
        model.updatesPossible = Updater.isRelease
        model.checkForUpdates = { [weak self] in self?.updater.check() }
        model.installUpdate = { [weak self] in self?.installUpdate() }
        updater.onChange = { [weak self] state in self?.showUpdate(state) }
        updater.start { [weak self] in self?.config.checkUpdates ?? false }
        showUpdate(updater.state)
    }

    private func showUpdate(_ state: Updater.State) {
        let have = Updater.version
        switch state {
        case .idle: model.updateText = "Version \(have)"
        case .checking: model.updateText = "Checking…"
        case .upToDate: model.updateText = "Up to date · \(have)"
        case .available(let v): model.updateText = "\(v) is out · you have \(have)"
        case .installing: model.updateText = "Installing… it reopens by itself"
        case .failed(let why): model.updateText = why
        }
        if case .available(let v) = state { model.updateVersion = v } else if state != .installing { model.updateVersion = nil }
    }

    @objc private func updateFromMenu() {
        DebugLog.tap("menu: updates")
        if case .available = updater.state {
            installUpdate()
        } else {
            updater.check()
            openSettings()
        }
    }

    /// From the disk image the update can't go in place: moving to
    /// Applications comes first (the copy there finds the update itself).
    private func installUpdate() {
        if MoveToApplications.needed { MoveToApplications.offer() } else { updater.install() }
    }

    // MARK: - Codex's server and claude.ai

    /// Codex's own server (CodexServer): its limits into Codex's account,
    /// its state into Settings.
    private func setUpCodexServer() {
        codexServer.onLimits = { [weak self] limits in self?.store.applyCodexServerLimits(limits) }
        codexServer.onChange = { [weak self] in
            guard let self else { return }
            self.model.codexServerState = self.config.codexServer ? self.codexServer.state : "Off"
            self.setNeedsRefresh()
        }
        model.codexServerState = config.codexServer ? codexServer.state : "Off"
    }

    private func setUpClaudeAI() {
        claudeAI.onUpdate = { [weak self] percent, resets in
            self?.store.account.apply(used: percent, resetsAt: resets)
            self?.setNeedsRefresh()
        }
        claudeAI.onWeek = { [weak self] percent, resets in
            self?.store.account.applyWeek(used: percent, resetsAt: resets)
            self?.setNeedsRefresh()
        }
        claudeAI.onState = { [weak self] state in
            self?.model.liveLimitState = state
            DebugLog.note("claude.ai: \(state)")
        }
        claudeAI.onChats = { [weak self] chats in
            guard let self else { return }
            self.store.apply(claudeAI: chats)
            // A Cowork task no longer waiting: answered in Claude, or stopped.
            for r in self.requests where r.remoteKey != nil && r.sessionId.flatMap({ self.store.sessions[$0]?.waitingNotice }) != true {
                self.finish(r, "cowork: no longer waiting (answered in Claude)", reply: false)
            }
        }
        claudeAI.onRemote = { [weak self] id, card in self?.remoteCard(card, for: id) }
        claudeAI.known = { [weak self] in
            var known: [String: String] = [:]
            for s in self?.store.sessions.values ?? [:].values where s.entrypoint == "cowork" && s.id.hasPrefix("cowork-") {
                if let cse = s.remoteSession { known[String(s.id.dropFirst("cowork-".count))] = cse }
            }
            return known
        }
        claudeAI.onContext = { [weak self] uuid, context in self?.store.apply(claudeAIContext: context, chat: uuid) }
        claudeAI.onRejected = { [weak self] in
            // Its chats would stay "working" for hours.
            self?.store.forgetClaudeAI()
            self?.dropRemoteRequests()
            self?.model.liveKeyRejected = true
        }
        model.signInClaudeAI = { [weak self] in
            self?.claudeAISignIn.show { key in
                guard let self, let key else { return }
                guard ClaudeAI.saveKey(key) else {
                    self.model.liveLimitState = "Couldn't keep the key in the Keychain"
                    return
                }
                DebugLog.tap("claude.ai signed in")
                self.setConfig("claudeAIChats", true)
                // The window showed the warning and waited for "I Understand".
                self.setConfig("claudeAIRiskShown", true)
                self.claudeAI.readChats = true
                self.model.hasLiveKey = true
                self.model.liveKeyRejected = false
                self.model.liveLimitState = "Checking…"
                self.claudeAI.start()
            }
        }
        model.removeLiveKey = { [weak self] in
            ClaudeAI.deleteKey()
            self?.claudeAI.stop()
            self?.store.forgetClaudeAI()
            self?.dropRemoteRequests()
            self?.model.hasLiveKey = false
            self?.model.liveKeyRejected = false
            self?.model.liveLimitState = "Off"
            DebugLog.tap("claude.ai signed out, key removed")
        }
        model.hasLiveKey = ClaudeAI.hasKey
        if model.hasLiveKey {
            // A key pasted before 1.2.8 was given for the limit: the chats
            // only once you say so (review, 28.10).
            claudeAI.readChats = config.claudeAIChats == true
            // Signed in before the warning (1.2.21): asked once, and claude.ai
            // is left alone until the answer (owner, 30.10).
            let warn = ClaudeAINotice.needsAsk(hasKey: true, shown: config.claudeAIRiskShown)
            if warn {
                model.liveLimitState = "Waiting for your answer"
            } else {
                model.liveLimitState = "Checking…"
                claudeAI.start()
            }
            if warn || config.claudeAIChats == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self else { return }
                    if warn {
                        guard self.askClaudeAIRisk() else { return }
                        self.model.liveLimitState = "Checking…"
                        self.claudeAI.start()
                    }
                    if self.config.claudeAIChats == nil { self.askClaudeAIChats() }
                }
            }
        }
    }

    /// Once, for those already signed in: Anthropic's terms don't allow this,
    /// and the choice is theirs (owner, 30.10). False: signed out, by the
    /// same way as Settings' Sign Out.
    private func askClaudeAIRisk() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = ClaudeAINotice.title
        alert.informativeText = ClaudeAINotice.text
        alert.addButton(withTitle: "Keep Signed In")
        alert.addButton(withTitle: "Sign Out")
        NSApp.activate(ignoringOtherApps: true)
        let keep = alert.runModal() == .alertFirstButtonReturn
        setConfig("claudeAIRiskShown", true)
        DebugLog.tap("claude.ai terms warning: \(keep ? "kept signed in" : "signed out")")
        if !keep { model.removeLiveKey() }
        return keep
    }

    /// Once, for a key from before 1.2.8: the chats too, or the limit alone.
    private func askClaudeAIChats() {
        let alert = NSAlert()
        alert.messageText = "Show your Cowork tasks and claude.ai chats too?"
        alert.informativeText = "Clouding Bar can now show them in its chats list — working, done or waiting for you, and a Cowork task's context — with the claude.ai key you gave it for the limit. It talks only to claude.ai — reads, and sends only what you send to a task or chat — and keeps the chats' names on this Mac. You can sign out any time in Settings → General → Claude."
        alert.addButton(withTitle: "Show Them")
        alert.addButton(withTitle: "Only the Limit")
        NSApp.activate(ignoringOtherApps: true)
        let yes = alert.runModal() == .alertFirstButtonReturn
        setConfig("claudeAIChats", yes)
        DebugLog.tap("claude.ai chats: \(yes ? "shown" : "limit only")")
        claudeAI.readChats = yes
        if yes { claudeAI.start() }
    }
}
