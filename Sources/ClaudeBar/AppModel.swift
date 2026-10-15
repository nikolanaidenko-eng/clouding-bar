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
        let name: String
        let status: String
        let activity: Activity
        let context: Double?
        let waiting: Bool
    }

    @Published var config = Config()
    @Published var touchBarPresent = false
    @Published var hasNotch = false
    @Published var openAtLogin = false

    @Published var hasSession = false
    @Published var activity: Activity = .sleep
    @Published var project: String?
    @Published var sessionPercent: Double?
    @Published var resetShort: String?
    @Published var resetLong: String?
    /// "2 h ago": how old the last known limit is (shown with no session).
    @Published var limitAge: String?
    @Published var contextPercent: Double?
    @Published var tokensIn: Int?
    @Published var tokensOut: Int?
    @Published var cost: Double?
    @Published var buttons: [ButtonSpec] = []
    @Published var sessions: [SessionRow] = []
    @Published var request: RequestCard?
    /// Projects seen in sessions, for the profile picker.
    @Published var knownProjects: [String] = []

    @Published var listening = false
    @Published var heard = ""
    /// What's typed in the widget's "Other" field.
    @Published var otherDraft = ""

    // Voice language support, worked out by VoiceInput.
    @Published var voiceOffline = true

    var perform: (BarAction) -> Void = { _ in }
    var answerText: (String) -> Void = { _ in }
    var openSession: (String) -> Void = { _ in }
    var showRequest: (String) -> Void = { _ in }
    var setConfig: (String, Any) -> Void = { _, _ in }
    var setOpenAtLogin: (Bool) -> Void = { _ in }
    var voice: (Bool) -> Void = { _ in }
    var resetWidgetPosition: () -> Void = {}

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

    static func ago(_ date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes) min ago" }
        if minutes < 48 * 60 { return "\(minutes / 60) h ago" }
        return "\(minutes / 1440) d ago"
    }

    static func duration(since date: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h"
    }
}
