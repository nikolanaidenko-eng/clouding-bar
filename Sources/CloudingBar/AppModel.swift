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
    @Published var activity: Activity = .sleep
    @Published var project: String?
    /// The chat the widget shows: its title (or project), colour, and
    /// where it runs ("GitHub · VS Code").
    @Published var chatName: String?
    @Published var chatColor: UInt32 = 0x0A84FF
    @Published var chatPlace: String?
    /// "Working · 3 min", "Idle · 12 min".
    @Published var chatStatus: String?
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
    /// What's typed in the widget's "Other" field.
    @Published var otherDraft = ""

    // Voice language support, worked out by VoiceInput.
    @Published var voiceOffline = true

    var perform: (BarAction) -> Void = { _ in }
    var answerText: (String) -> Void = { _ in }
    var openSession: (String) -> Void = { _ in }
    /// Follow this chat in the widget and bring it to the front.
    var focusSession: (String) -> Void = { _ in }
    var showRequest: (String) -> Void = { _ in }
    var setConfig: (String, Any) -> Void = { _, _ in }
    var setOpenAtLogin: (Bool) -> Void = { _ in }
    var voice: (Bool) -> Void = { _ in }
    var voiceToggle: () -> Void = {}
    var addToQueue: (String) -> Void = { _ in }
    var removeFromQueue: (UUID) -> Void = { _ in }
    var insertTemplate: (String) -> Void = { _ in }
    var takeScreenshot: () -> Void = {}
    /// Files dropped on the widget; false if there's no session to take them.
    var dropFiles: ([URL]) -> Bool = { _ in false }
    var removeAttachment: (String) -> Void = { _ in }
    /// Types the attached files' paths into the chat in front, without Enter.
    var insertAttachments: () -> Void = {}
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
    /// The animated tour of the widget at work (the old one, now "Watch it work").
    var showFilm: () -> Void = {}
    /// The tour in the settings window: the stop it's at, nil when off.
    @Published var tourStep: Int?

    // Settings → General → Claude Code (Setup.swift)
    @Published var claudeConnected = true
    @Published var hasVSCode = false
    @Published var vscodeWrapped = false
    @Published var setupMessage: String?
    var connectClaude: () -> Void = {}
    @Published var hasCodex = false
    @Published var codexConnected = false
    var connectCodex: () -> Void = {}
    var wrapVSCode: () -> Void = {}

    /// The pill's height budget: what was set by pulling its top or bottom.
    var pillHeightBudget: CGFloat {
        config.pillHeight > 0 ? CGFloat(config.pillHeight) : PillLayout.height(rows: max(1, config.pillRows))
    }

    /// The pill's width budget: what was set by pulling its edge, or what
    /// the old density setting showed.
    var pillBudget: CGFloat {
        if config.pillWidth > 0 { return CGFloat(config.pillWidth) }
        switch config.pillDensity {
        case "icon": return 0
        case "numbers": return 260
        default: return 370
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
