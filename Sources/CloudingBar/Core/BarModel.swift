import CoreGraphics
import Foundation

/// Everything the bar shows, as plain data.
struct BarModel: Equatable {
    enum Mode: Equatable {
        case normal
        case contextWarning
        case permission(verb: String, detail: String)
        case question(text: String, options: [String], multiSelect: Bool, picked: Set<Int>)
        case typing(text: String)
        /// The model and effort picker, opened from the model button.
        case models
        /// The subagents at work, opened from the subagents button.
        case agents
        /// The live chats, opened from the chat button: pick one to write to
        /// it without following it (owner, 27.10).
        case chats
        /// Your templates, opened from the templates button: tap one to
        /// type it into the chat.
        case templates
        /// Another chat than the one shown is done: Cloud says which, for
        /// a few seconds (tap to go there).
        case done(Chat)
    }

    /// A live chat, for the chat button and the chats panel.
    struct Chat: Equatable {
        let id: String
        let name: String
        let color: UInt32
        let current: Bool
        let waiting: Bool
    }

    var mode: Mode = .normal
    var activity: Activity = .sleep
    var sessionPercent: Double?
    var resetCountdown: String?
    var contextPercent: Double?
    var buttons: [ButtonSpec] = []
    /// Do not disturb: nothing pulses.
    var quiet = false
    /// The widget is open from Cloud's button: Cloud stays up (not asleep).
    var awake = false
    /// The chat's Cloud (its colorIndex); nil: the colour picked in Settings.
    var cloudVariant: Int?
    /// What shows besides the character: "session", "reset", "context",
    /// "model", "buttons", "mic", "shot" (Settings → Touch Bar).
    var shows: Set<String> = ["session", "reset", "context", "buttons"]
    /// The model button: "Opus 5.5 1M · xhigh".
    var modelLabel: String?
    /// For the picker: the model's alias ("opus[1m]") and the effort.
    var modelAlias: String?
    var effort: String?
    /// Subagents at work: "Explore · Find the hook code".
    var agents: [String] = []
    /// Every live chat; with more than one, the bar says which it shows.
    var chats: [Chat] = []
    /// The chat a request comes from (with several chats).
    var requestChat: Chat?
    /// "Always" beside Allow: Claude's, not Codex's (it can't remember an allow).
    var offersAlways = true
    /// The typing field's word before it and its placeholder: an answer
    /// ("Other") or a message to the chat ("To Status bar").
    var typingLabel = "Other"
    var typingPlaceholder = "Type your answer"
    /// Writing to the chat (not answering): your buttons and templates
    /// stay at hand beside the field.
    var typingCommands = false
    /// The line is written for a chat picked from the list, not the one
    /// followed: its chip before the words, ↗ to open it at the end. And
    /// the files waiting for it (a screenshot taken from the line).
    var typingTo: Chat?
    var typingFiles = 0
    /// Dictating into the line: the mic lit, the words arriving as you speak.
    var listening = false
    /// The chat the bar shows, for the chat field: "Status bar".
    var chatName: String?
    /// The chat's project: its first letter is the short bar's chat button.
    var project: String?
    /// The question as asked, when the bar shows it shorter.
    var questionKey = ""
    /// Done: the start of that chat's answer (✦: put shorter by Apple's
    /// model); swapped in place when the short form comes.
    var doneAnswer: String?
    /// Beside Apple's buttons: everything smaller, the rest left out — and a
    /// button that opens the whole bar (`expand`).
    var short = false
    /// Opened from short: a button folds it back, Apple's buttons return.
    var expanded = false
    /// Your templates, as they read.
    var templates: [String] = []
    /// What the widget can show too: "+120 −8", "main", "$1.20".
    var lines: String?
    var branch: String?
    var cost: String?
    /// Arranged in Settings: the blocks' order and their dragged widths.
    var order: [String] = []
    var widths: [String: CGFloat] = [:]

    var current: Chat? { chats.count > 1 ? chats.first(where: \.current) : nil }
}

enum BarAction {
    /// The character button where esc used to be (the keyboard has its own
    /// Esc): brings the widget up from the bottom of the screen.
    case widget, button(Int)
    case allow, always, deny
    case option(Int), other, sendPicked, send, mic
    case compact, later
    /// Normal mode's own mic and screenshot buttons.
    case dictate, screenshot
    /// The model button opens the picker; a pick types /model or /effort.
    case models, pickModel(String), pickEffort(String)
    /// The subagents button shows who's working.
    case agents
    /// The chat button shows the chats; a pick opens the message line for
    /// that one (`writeTo`), without following it. `pickChat` follows a
    /// chat and opens it (↗ on that line, "Open" on another's "done").
    case chats, writeTo(String), pickChat(String)
    /// Write: a message to the chat, typed on the keyboard or dictated,
    /// sent when Claude is free (like the widget's message box).
    case write, cancelTyping
    /// The templates button lists them; a pick types one into the chat.
    case templates, pickTemplate(Int)
    /// Beside Apple's buttons: the whole bar for Claude, and back.
    case expand, collapse
    /// "OK" on another chat's "done": back to the chat shown.
    case dismissDone
    /// Done: back from the picker or the subagents.
    case closePanel
    /// A tap on a question or a command: the whole of it, in the widget's
    /// panel or the island (owner, 26.10: the bar shows a question shorter).
    case showRequest
}

extension BarModel {
    /// What decides the set of subviews; values change without a rebuild.
    static func structureKey(_ m: BarModel) -> String {
        let buttons = m.buttons.map(\.label).joined(separator: "\u{1}") + (m.quiet ? "|quiet" : "")
            + "|" + m.shows.sorted().joined(separator: ",")
        let chat = (m.current.map { "\($0.id)|\($0.name)" } ?? "") + "|" + (m.requestChat?.id ?? "")
        switch m.mode {
        case .normal:
            let info = [m.lines, m.branch, m.cost, m.chatName, m.project].map { $0 ?? "" }.joined(separator: "|")
            let arranged = m.order.joined(separator: ",") + "|" + m.widths.sorted { $0.key < $1.key }.map { "\($0.key)=\(Int($0.value))" }.joined(separator: ",")
            return "normal|\(buttons)|\(m.modelLabel ?? "")|\(m.agents.count)|\(chat)|\(info)|\(m.templates.count)|\(m.short)|\(m.expanded)|\(arranged)"
        case .templates: return "templates|" + m.templates.joined(separator: "\u{1}")
        case .chats: return "chats|" + m.chats.map { "\($0.id)\($0.name)\($0.current)\($0.waiting)" }.joined(separator: "\u{1}")
        case .models: return "models|\(m.modelAlias ?? "")|\(m.effort ?? "")"
        case .agents: return "agents|" + m.agents.joined(separator: "\u{1}")
        case .contextWarning: return "context"
        case let .done(c): return "done|\(c.id)|\(c.name)|\(m.short)|\(m.doneAnswer != nil)"
        case let .permission(verb, detail): return "permission|\(verb)|\(detail)|\(chat)|\(m.offersAlways)"
        case let .question(text, options, multi, picked):
            // The question as asked, not its short form: that swaps in place.
            return "question|\(m.questionKey.isEmpty ? text : m.questionKey)|\(options.joined(separator: "\u{1}"))|\(multi)|\(picked.sorted())|\(chat)"
        case .typing:
            let to = m.typingTo.map { "\($0.id)|\($0.name)|\($0.color)|\(m.typingFiles)" } ?? ""
            return "typing|\(m.typingLabel)|\(m.typingPlaceholder)|\(m.typingCommands)|\(buttons)|\(m.templates.count)|\(m.listening)|\(to)|\(m.short)"
        }
    }
}
