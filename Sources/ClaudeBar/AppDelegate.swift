import AppKit

/// Wires everything together:
///  - hook events arrive over the unix socket and update session state
///  - the Touch Bar takes over only while a terminal is frontmost AND
///    at least one Claude Code session is alive ("Claude mode")
///  - a small menu bar item for status and quitting
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config = Config.load()
    private let usageTracker = UsageTracker()
    private lazy var touchBarController = TouchBarController(config: config, usageTracker: usageTracker)

    private var socketServer: HookSocketServer?
    private var statusItem: NSStatusItem?

    /// Live Claude Code sessions, keyed by session id.
    private var activeSessions: Set<String> = []
    /// The permission prompt we're currently showing buttons for, if any.
    private var pendingPermissionMessage: String?
    private var terminalIsFrontmost = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpMenuBarItem()
        KeySender.ensureTrusted()

        try? FileManager.default.createDirectory(at: Config.directory,
                                                 withIntermediateDirectories: true)
        let server = HookSocketServer(path: Config.socketPath) { [weak self] data in
            DispatchQueue.main.async { self?.handleHookPayload(data) }
        }
        do {
            try server.start()
            socketServer = server
        } catch {
            NSLog("ClaudeBar: could not open hook socket — \(error.localizedDescription)")
        }

        // Track which app is frontmost so we only own the Touch Bar
        // while you're actually looking at your terminal.
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self,
                           selector: #selector(frontmostAppChanged(_:)),
                           name: NSWorkspace.didActivateApplicationNotification,
                           object: nil)
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            terminalIsFrontmost = isTerminal(frontmost)
        }
    }

    // MARK: - Hook events

    private func handleHookPayload(_ data: Data) {
        guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
            return
        }

        switch event.hookEventName {
        case "SessionStart":
            if let id = event.sessionId { activeSessions.insert(id) }
            if let transcript = event.transcriptPath {
                usageTracker.watch(transcriptPath: transcript)
            }

        case "SessionEnd":
            if let id = event.sessionId { activeSessions.remove(id) }
            if activeSessions.isEmpty { usageTracker.stop() }
            pendingPermissionMessage = nil

        case "Notification":
            if event.isPermissionRequest {
                pendingPermissionMessage = event.message
            }

        case "Stop", "UserPromptSubmit":
            // Claude finished a turn / the user answered — any prompt we
            // were showing buttons for is gone.
            pendingPermissionMessage = nil

        default:
            break
        }

        refreshTouchBar()
    }

    // MARK: - Frontmost app tracking

    @objc private func frontmostAppChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        terminalIsFrontmost = isTerminal(app)
        refreshTouchBar()
    }

    private func isTerminal(_ app: NSRunningApplication) -> Bool {
        guard let bundleID = app.bundleIdentifier else { return false }
        return config.terminalBundleIDs.contains(bundleID)
    }

    // MARK: - Touch Bar state

    private func refreshTouchBar() {
        let claudeMode = !activeSessions.isEmpty && terminalIsFrontmost
        guard claudeMode else {
            touchBarController.dismiss()
            return
        }
        if let message = pendingPermissionMessage {
            touchBarController.show(.permission(message: message))
        } else {
            touchBarController.show(.idle)
        }
    }

    // MARK: - Menu bar

    private func setUpMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.title = "✳"

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "ClaudeBar is watching for Claude Code sessions",
                                action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        let configItem = NSMenuItem(title: "Open Config Folder",
                                    action: #selector(openConfigFolder), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit ClaudeBar",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    @objc private func openConfigFolder() {
        NSWorkspace.shared.open(Config.directory)
    }
}
