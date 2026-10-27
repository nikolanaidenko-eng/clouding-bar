import AppKit
import Combine

/// What the widget and the settings window show, refreshed by AppDelegate.
/// SwiftUI views read it; taps go back through the closures.
final class AppModel: ObservableObject {
    struct RequestCard: Equatable {
        enum Kind { case permission, question }
        let id: UUID
        let kind: Kind
        let project: String?
        /// The chat it comes from ("Status bar") and its colour.
        var chat: String?
        var color: UInt32?
        /// From a chat other than the one the widget shows.
        var elsewhere = false
        // permission
        var verb = ""
        var detail = ""
        // question
        var question = ""
        var options: [String] = []
        var descriptions: [String] = []
        var multiSelect = false
        var picked: Set<Int> = []
        var index = 0
        var count = 1
        /// "Always allow" is Claude's; Codex can't remember an allow.
        var offersAlways = true
    }

    struct SessionRow: Identifiable, Equatable {
        let id: String
        /// Its title, else its project.
        let name: String
        let status: String
        let activity: Activity
        let context: Double?
        let waiting: Bool
        /// "GitHub · VS Code"
        var place = ""
        var color: UInt32 = 0x0A84FF
        /// The one the widget shows.
        var current = false
    }

    @Published var config = Config()
    @Published var touchBarPresent = false
    @Published var hasNotch = false
    @Published var openAtLogin = false

    @Published var hasSession = false
    /// Each one makes the widget's Cloud wave (Claude's ☁️).
    @Published var cloudWaves = 0
    /// Cloud has stepped out of the widget to say another chat is done:
    /// 1 up (out over the pill), -1 down (out of the notch), 0 at home.
    @Published var cloudOut = 0
    /// The settings window opens at this tab ("widget"), then forgets it.
    @Published var settingsTabRequest: String?
    @Published var activity: Activity = .sleep
    @Published var project: String?
    /// The chat the widget shows: its title (or project), colour, and
    /// where it runs ("GitHub · VS Code").
    @Published var chatName: String?
    @Published var chatColor: UInt32 = 0x0A84FF
    /// The active chat's Cloud (its colorIndex); nil: no chat, Settings' colour.
    @Published var cloudVariant: Int?
    @Published var chatPlace: String?
    /// "Working · 3 min", "Idle · 12 min".
    @Published var chatStatus: String?
    /// How long the chat shown has been at it (or idle): "3 min".
    @Published var chatTime: String?
    /// The chat shown just finished and the widget is about to move on to
    /// the one at work: a tick instead of its dot.
    @Published var chatDone = false
    @Published var sessionPercent: Double?
    @Published var resetShort: String?
    @Published var resetLong: String?
    /// "2 h ago": how old the last known limit is (shown with no session).
    @Published var limitAge: String?
    @Published var contextPercent: Double?
    /// Tokens in the context now, and the window ("327k of 1M").
    @Published var contextTokens: Int?
    @Published var contextWindow: Int?
    /// "Codex" when the session in front is Codex's (its own limits, no
    /// Claude model picker); nil for Claude.
    @Published var agentName: String?
    /// The weekly (7-day) limit and when it resets ("Thu 14:00").
    @Published var weekPercent: Double?
    @Published var weekReset: String?
    @Published var tokensIn: Int?
    @Published var tokensOut: Int?
    @Published var cost: Double?
    @Published var buttons: [ButtonSpec] = []
    /// The Commands button's list: all the buttons.
    @Published var menuButtons: [ButtonSpec] = []
    @Published var sessions: [SessionRow] = []
    @Published var request: RequestCard?
    /// Projects seen in sessions, for the profile picker.
    @Published var knownProjects: [String] = []

    // Small metrics (each shown only when picked in Settings)
    @Published var modelName: String?
    /// The model's id ("claude-opus-5-5[1m]"), for the picker.
    @Published var modelId: String?
    @Published var effort: String?
    /// The model and effort picker is open in the panel.
    @Published var pickingModel = false
    @Published var linesAdded = 0
    @Published var linesRemoved = 0
    @Published var branch: String?
    @Published var agents = 0
    /// Paying per token (no subscription limit seen): cost makes sense.
    @Published var isAPI = false

    /// A running subagent, for the panel's list and the bar.
    struct AgentRow: Identifiable, Equatable {
        let id: String
        /// "Explore", "general-purpose"
        let type: String
        /// What it was asked: "Find the hook code".
        let task: String?
        /// Its latest tool: "Read · Session.swift".
        let doing: String?
        /// How long it's been running: "40 s", "3 min".
        let elapsed: String
        let background: Bool
    }
    @Published var agentRows: [AgentRow] = []
    /// The panel shows the list of running subagents.
    @Published var showingAgents = false

    struct QueueItem: Identifiable, Equatable, Codable {
        var id = UUID()
        let text: String
        let sessionId: String?
        let project: String?
    }
    @Published var queue: [QueueItem] = []

    /// Files dropped on the widget for the session it shows: they go with
    /// the next message written there, or into the chat with Insert.
    @Published var attachments: [String] = []
    /// Every chat's files waiting, by its id: the Chats tab's composers.
    @Published var chatFiles: [String: [String]] = [:]
    /// The words being written in each chat's composer, kept while you look
    /// at another (your voice lands here too).
    @Published var chatDrafts: [String: String] = [:]
    /// The chat whose composer the mic is dictating into.
    @Published var listeningFor: String?
    /// Just sent from the Chats tab: where the words are now ("Sent to Lead
    /// bot", "Queued for Lead bot — goes when you open it"), for a moment.
    struct SentNote: Equatable {
        var id = UUID()
        let chat: String
        let text: String
    }
    @Published var sentNote: SentNote?
    /// That session's chat is the window in front (Insert types into it).
    @Published var chatInFront = false

    // Cowork tab
    @Published var coworkLast: String?
    /// Folder names being watched for Cowork's status.
    @Published var coworkFolders: [String] = []
    @Published var coworkMessage: String?
    @Published var hasLiveKey = false
    @Published var liveLimitState = "Off"

    @Published var listening = false
    @Published var heard = ""
    /// Dictated text to look over before it's sent (nil: none).
    @Published var dictated: String?
    var sendDictated: () -> Void = {}
    var discardDictated: () -> Void = {}
    /// Dictation in the widget: listening, or the text to check.
    var voiceShown: Bool { listening || dictated != nil }
    /// What's typed in the widget's "Other" field.
    @Published var otherDraft = ""

    // Voice language support, worked out by VoiceInput.
    @Published var voiceOffline = true

    var perform: (BarAction) -> Void = { _ in }
    var answerText: (String) -> Void = { _ in }
    var openSession: (String) -> Void = { _ in }
    /// The Touch Bar as it is now, for Settings to arrange (true: the short one).
    var barPreview: (Bool) -> BarModel = { _ in BarModel() }
    /// Follow this chat in the widget and bring it to the front.
    var focusSession: (String) -> Void = { _ in }
    var showRequest: (String) -> Void = { _ in }
    var setConfig: (String, Any) -> Void = { _, _ in }
    var setOpenAtLogin: (Bool) -> Void = { _ in }
    var voice: (Bool) -> Void = { _ in }
    var voiceToggle: () -> Void = {}
    var addToQueue: (String) -> Void = { _ in }
    var removeFromQueue: (UUID) -> Void = { _ in }
    /// Send it now: its chat brought to the front and the words typed in.
    var sendQueuedNow: (UUID) -> Void = { _ in }
    var runMenuButton: (Int) -> Void = { _ in }
    var takeScreenshot: () -> Void = {}
    /// Files dropped on the widget; false if there's no session to take them.
    var dropFiles: ([URL]) -> Bool = { _ in false }
    var removeAttachment: (String) -> Void = { _ in }
    /// Types the attached files' paths into the chat in front, without Enter.
    var insertAttachments: () -> Void = {}
    // The Chats tab: one chat, picked by its id, whatever the widget follows
    // — nothing switches, no window comes forward (owner, 27.10).
    /// Words for it (text, its id): straight in, or its queue.
    var sendTo: (String, String) -> Void = { _, _ in }
    /// An area of the screen for it: attached to it, its composer open.
    var screenshotTo: (String) -> Void = { _ in }
    /// Dictation into its composer, on or off.
    var voiceTo: (String) -> Void = { _ in }
    /// Files dropped while its composer is open; false if it has ended.
    var dropFilesTo: ([URL], String) -> Bool = { _, _ in false }
    /// A file of its taken off (path, its id).
    var removeAttachmentFrom: (String, String) -> Void = { _, _ in }
    /// Switch the active session's model ("opus[1m]") or effort ("high"):
    /// typed into its chat as /model or /effort.
    var setModel: (String) -> Void = { _ in }
    var setEffort: (String) -> Void = { _ in }
    var chooseCoworkFolder: () -> Void = {}
    var makeCoworkPlugin: () -> Void = {}
    var saveLiveKey: (String) -> Void = { _ in }
    var removeLiveKey: () -> Void = {}
    var resetWidgetPosition: () -> Void = {}
    var showTour: () -> Void = {}
    /// Settings, at one of its tabs.
    var openSettingsTab: (String) -> Void = { _ in }
    /// The tour in the settings window: the stop it's at, nil when off.
    @Published var tourStep: Int?
    /// Settings is arranging the short bar: the Touch Bar shows that one.
    @Published var editingShortBar = false { didSet { if editingShortBar != oldValue { barChanged() } } }
    var barChanged: () -> Void = {}

    // Settings → General → Claude Code (Setup.swift)
    @Published var claudeConnected = true
    @Published var hasVSCode = false
    @Published var vscodeWrapped = false
    @Published var setupMessage: String?
    /// The last Connect failed (`setupMessage` says why).
    var setupFailed = false
    var connectClaude: () -> Void = {}
    @Published var hasCodex = false
    @Published var codexConnected = false
    /// Codex's own server: "Connected", "Codex's server isn't running", "Off"…
    @Published var codexServerState = "Off"
    var connectCodex: () -> Void = {}
    var wrapVSCode: () -> Void = {}
    /// Clouding Bar's plugin: on in Claude Code; with your account (Claude
    /// Desktop, so in Cowork too); the Cowork-only one of 1.0 still there.
    @Published var pluginActive = false
    @Published var pluginSynced = false
    @Published var oldCoworkPlugin = false

    // Settings → General → Updates (Updater.swift)
    @Published var updatesPossible = false
    @Published var updateText = ""
    /// A newer release, ready to install.
    @Published var updateVersion: String?
    var checkForUpdates: () -> Void = {}
    var installUpdate: () -> Void = {}

    /// Settings' copy of the widget with no chat open: your settings and
    /// buttons with example numbers, so every switch shows what it does
    /// (owner, 25.10: on a fresh install nothing seemed to change). What you
    /// arrange there is saved through the live model.
    func fillExample(from live: AppModel) {
        config = live.config
        buttons = live.buttons
        menuButtons = live.menuButtons
        hasNotch = live.hasNotch
        setConfig = live.setConfig
        hasSession = true
        activity = .work
        project = "my-app"
        chatName = "Example chat"
        chatColor = 0x0A84FF
        chatPlace = "my-app · VS Code"
        chatStatus = "Working"
        chatTime = "3 min"
        sessionPercent = live.sessionPercent ?? 42
        resetShort = live.resetShort ?? "1:23"
        resetLong = live.resetLong ?? "1 h 23 min"
        contextPercent = 31
        contextTokens = 62_000
        contextWindow = 200_000
        modelName = "Opus 5.5"
        effort = "high"
        linesAdded = 120
        linesRemoved = 8
        branch = "main"
        agents = 1
        cost = 1.2
        sessions = [SessionRow(id: "example", name: "Example chat", status: "Working · 3 min", activity: .work,
                               context: 31, waiting: false, place: "my-app · VS Code", current: true)]
    }

    /// The pill's height budget: what was set by pulling its top or bottom.
    var pillHeightBudget: CGFloat {
        config.pillHeight > 0 ? CGFloat(config.pillHeight) : PillLayout.height(rows: max(1, config.pillRows))
    }

    /// The pill's width budget: what was set by pulling its edge, or what
    /// the old density setting showed; else room for everything switched
    /// on, as wide as the screen allows (owner, 25.10: what you switch on
    /// shows).
    var pillBudget: CGFloat {
        if config.pillWidth > 0 { return CGFloat(config.pillWidth) }
        switch config.pillDensity {
        case "icon": return 0
        case "numbers": return 260
        default:
            // The screen the pill is on: where it was put, else the first.
            let screen = config.widgetPosition.flatMap { p in NSScreen.screens.first { $0.frame.contains(p) } }
                ?? NSScreen.screens.first
            return max(370, (screen?.visibleFrame.width ?? 1440) - 80)
        }
    }

    var statusTitle: String {
        if request != nil { return request?.kind == .question ? "Claude asks" : "Needs your OK" }
        switch activity {
        case .work: return "Working"
        case .wait: return "Needs your OK"
        case .sleep: return "Idle"
        }
    }

    static func compact(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1_000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }

    /// "327k", "1M", "1.2M": a context size at a glance.
    static func short(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return "\(n / 1_000)k"
        default:
            let m = Double(n) / 1_000_000
            return m == m.rounded() ? "\(Int(m))M" : String(format: "%.1fM", m)
        }
    }

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        if minutes < 48 * 60 { return "\(minutes / 60) h ago" }
        return "\(minutes / 1440) d ago"
    }

    /// "40 s", "3 min", "1 h 5 min".
    static func elapsed(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds) s" }
        if seconds < 3600 { return "\(seconds / 60) min" }
        return "\(seconds / 3600) h \(seconds % 3600 / 60) min"
    }

    static func duration(since date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h"
    }
}
