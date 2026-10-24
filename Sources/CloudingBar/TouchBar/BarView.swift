import AppKit

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
        /// The live chats, opened from the chat button: pick one to follow.
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
    /// The typing field's word before it and its placeholder: an answer
    /// ("Other") or a message to the chat ("To Status bar").
    var typingLabel = "Other"
    var typingPlaceholder = "Type your answer"
    /// Writing to the chat (not answering): your buttons and templates
    /// stay at hand beside the field.
    var typingCommands = false
    /// Dictating into the line: the mic lit, the words arriving as you speak.
    var listening = false
    /// The chat the bar shows, for the chat field: "Status bar".
    var chatName: String?
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
    /// The chat button shows the chats; a pick follows that one.
    case chats, pickChat(String)
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
}

/// The whole Touch Bar as one view, laid out like design/TB-*.dc.html:
///
///   normal      [character] · Session ─── · Context ── · buttons
///   permission  [character] · ● Run `command` · Allow · Always · Deny
///   question    [character] · ● Question? · option · option · Other…
///   typing      [character] · ═ · Other [answer________] · Send · 🎤
///   context     [character] · Session ─── · Context ── (red) · Compact · Later
///   models      [character] · Model  Opus 1M · Opus · … · Effort  low · … · Done
///   agents      [character] · Subagents  Explore · Find the hook code · … · Done
///
/// [character] is a button (where esc used to be) that opens the widget.
///
/// Session and Context share whatever the buttons leave (3 : 2) and drop
/// their words as space runs out: "Session"/"Context" → "5h"/"Ctx" → just
/// the numbers (TB-Normal's renderVals).
final class BarView: NSView {
    var onAction: ((BarAction) -> Void)?

    /// Width of the full-width system-modal bar (2008 px measured on the
    /// 13" MacBook Pro); layout follows whatever width we actually get.
    static let preferredWidth: CGFloat = 1004
    /// Beside the Control Strip (Apple's brightness, volume…).
    static let narrowWidth: CGFloat = 628 // measured: screencapture -b, Chrome in front

    /// Beside the Control Strip: as wide as the room there, so nothing slips
    /// under Apple's buttons.
    var narrow = false {
        didSet { if narrow != oldValue { invalidateIntrinsicContentSize(); needsLayout = true } }
    }

    private(set) var model = BarModel()
    private var builtFor: String?
    private let mascot = MascotView(size: 28)
    private lazy var widgetButton: BarButton = {
        let b = BarButton("Clouding Bar") { [weak self] in self?.onAction?(.widget) }
        b.setTitle("")
        b.addSubview(mascot)
        return b
    }()

    private var slots: [Slot] = []
    private var meters: MetersPair?
    private var mini: MiniMetersView?
    private var field: TypingFieldView?
    /// The model picker didn't fit in one row (the Control Strip is out):
    /// models and effort take turns, `effortPage` says which shows.
    private var pagedModels = false
    private var effortPage = false
    private var pendingAnimations: [(CALayer) -> Void] = []
    private var animatedViews: [NSView] = []

    private struct Slot {
        /// Left out, from the right, when even shrunk things don't fit.
        var droppable = false
        enum Width {
            case fixed(CGFloat)
            case shrinkable(CGFloat)  // fixed, but gives way when space runs out
            case flex(weight: CGFloat, min: CGFloat)
        }
        let view: NSView
        let width: Width
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: narrow ? Self.narrowWidth : Self.preferredWidth, height: Palette.height)
    }

    func update(_ new: BarModel) {
        let key = Self.structureKey(new)
        if new.mode != .models { pagedModels = false; effortPage = false }
        model = new
        if key != builtFor {
            builtFor = key
            rebuild()
        }
        refreshValues()
    }

    // MARK: Building

    /// What decides the set of subviews; values change without a rebuild.
    private static func structureKey(_ m: BarModel) -> String {
        let buttons = m.buttons.map(\.label).joined(separator: "\u{1}") + (m.quiet ? "|quiet" : "")
            + "|" + m.shows.sorted().joined(separator: ",")
        let chat = (m.current.map { "\($0.id)|\($0.name)" } ?? "") + "|" + (m.requestChat?.id ?? "")
        switch m.mode {
        case .normal:
            let info = [m.lines, m.branch, m.cost, m.chatName].map { $0 ?? "" }.joined(separator: "|")
            return "normal|\(buttons)|\(m.modelLabel ?? "")|\(m.agents.count)|\(chat)|\(info)|\(m.templates.count)|\(m.short)|\(m.expanded)"
        case .templates: return "templates|" + m.templates.joined(separator: "\u{1}")
        case .chats: return "chats|" + m.chats.map { "\($0.id)\($0.name)\($0.current)\($0.waiting)" }.joined(separator: "\u{1}")
        case .models: return "models|\(m.modelAlias ?? "")|\(m.effort ?? "")"
        case .agents: return "agents|" + m.agents.joined(separator: "\u{1}")
        case .contextWarning: return "context"
        case let .done(c): return "done|\(c.id)|\(c.name)|\(m.short)"
        case let .permission(verb, detail): return "permission|\(verb)|\(detail)|\(chat)"
        case let .question(text, options, multi, picked):
            return "question|\(text)|\(options.joined(separator: "\u{1}"))|\(multi)|\(picked.sorted())|\(chat)"
        case .typing:
            return "typing|\(m.typingLabel)|\(m.typingPlaceholder)|\(m.typingCommands)|\(buttons)|\(m.templates.count)|\(m.listening)"
        }
    }

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        slots = []
        meters = nil
        mini = nil
        field = nil
        pendingAnimations = []
        animatedViews = []

        add(widgetButton, .fixed(60))

        switch model.mode {
        case .normal:
            let short = model.short
            // Short (owner, 24.10): the limits at least half the bar; the chat
            // line's frame with your commands in it (three at most, the rest
            // on the whole bar) but no room for words — and the chat's name
            // only in what room is left.
            let shortHalf = (Self.narrowWidth - Palette.edge * 2) / 2
            var shortBox: NSView?
            var shortBoxWidth: CGFloat = 0
            if short, case let commands = commandButtons(limit: 3), !commands.isEmpty {
                let field = ComposeFieldButton(placeholder: "") { [weak self] in self?.onAction?(.write) }
                let box = ChatBoxView(field: field, commands: commands, compact: true)
                shortBox = box
                shortBoxWidth = box.commandsWidth + 6
            }
            // Several chats: which one this is; a tap lists them all.
            if let chat = model.current {
                let b = BarButton(chat.name, fontSize: short ? 11 : 12, dot: chat.color, marquee: true) { [weak self] in self?.onAction?(.chats) }
                // A name that fits keeps its room (it stands still; what doesn't
                // fit goes from the right instead); a longer one gives way and slides.
                var cap: CGFloat = short ? 130 : 220
                if short {
                    // Room beside Cloud (60), half the bar, the commands and "whole bar" (40).
                    cap = min(cap, shortHalf - 60 - 40 - shortBoxWidth - Palette.gap * (shortBox == nil ? 2 : 3))
                }
                let fit = b.fittingWidth(padding: short ? 8 : 10)
                if cap >= min(fit, 60) { add(b, fit <= cap ? .fixed(fit) : .shrinkable(cap)) }
            }
            // Short (beside Apple's buttons): everything, smaller; what
            // still doesn't fit is left out from the right (layout()).
            let shows = model.shows
            let session = shows.contains("session"), context = shows.contains("context")
            if session || context {
                let pair = MetersPair(padding: 6, showSession: session, showContext: context)
                meters = pair
                add(pair, .flex(weight: 1, min: short ? shortHalf : session && context ? 120 : 80))
            }
            if shows.contains("model"), let label = model.modelLabel {
                let b = BarButton(label, fontSize: short ? 11 : 12, symbol: ("cpu", 0xBF5AF2)) { [weak self] in self?.onAction?(.models) }
                add(b, .shrinkable(min(short ? 120 : 190, b.fittingWidth(padding: short ? 8 : 12))), droppable: true)
            }
            if shows.contains("agents") {
                let n = model.agents.count
                let b = BarButton(n == 0 ? "No agents" : "\(n) agent\(n == 1 ? "" : "s")", fontSize: 12,
                                  symbol: ("person.2.fill", 0x40C8E0)) {
                    [weak self] in self?.onAction?(.agents)
                }
                add(b, .shrinkable(b.fittingWidth(padding: short ? 8 : 14)), droppable: true)
            }
            // What the widget shows besides: lines, branch, cost.
            for (key, text, symbol) in [("lines", model.lines, ("chevron.left.forwardslash.chevron.right", UInt32(0x30D158))),
                                        ("branch", model.branch, ("arrow.triangle.branch", UInt32(0xFF9F0A))),
                                        ("cost", model.cost, ("dollarsign.circle", UInt32(0xFFD60A)))] {
                guard shows.contains(key), let text else { continue }
                let b = BarButton(text, fontSize: short ? 11 : 12, symbol: symbol)
                add(b, .shrinkable(min(short ? 100 : 150, b.fittingWidth(padding: short ? 8 : 12))), droppable: true)
            }
            if short {
                if let shortBox { add(shortBox, .fixed(shortBoxWidth), droppable: true) }
            } else if shows.contains("chat") {
                // The chat's name is on the bar already when there are several.
                let placeholder = model.current != nil ? "Message…" : model.chatName.map { "Write to “\($0)”…" } ?? "Message…"
                let field = ComposeFieldButton(placeholder: placeholder) {
                    [weak self] in self?.onAction?(.write)
                }
                // Your commands inside it, one whole (short: three at most).
                let box = ChatBoxView(field: field, commands: commandButtons(limit: short ? 3 : nil), compact: short)
                add(box, .flex(weight: 1.2, min: (short ? 100 : 150) + box.commandsWidth), droppable: true)
            }
            if shows.contains("templates"), !model.templates.isEmpty {
                let b = BarButton(short ? "" : "Templates", fontSize: 12, symbol: ("text.badge.plus", 0xBF5AF2)) { [weak self] in
                    self?.onAction?(.templates)
                }
                add(b, short ? .fixed(40) : .shrinkable(b.fittingWidth(padding: 14)), droppable: true)
            }
            // With the chat field, your buttons are inside it.
            if !short && shows.contains("buttons") && !shows.contains("chat") {
                for (i, spec) in model.buttons.enumerated() {
                    let b = customButton(spec.label, compact: short) { [weak self] in self?.onAction?(.button(i)) }
                    add(b.button, .shrinkable(b.width), droppable: true)
                    animate(b.button) { $0.popIn() }
                }
            }
            // Short: no screenshot or mic — the chats, the limits and the
            // message box with its commands only; they're on the whole bar
            // (owner, 24.10).
            if !short, shows.contains("shot"), let icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Screenshot") {
                add(BarButton("Screenshot", icon: icon) { [weak self] in self?.onAction?(.screenshot) }, .fixed(48), droppable: true)
            }
            if !short, shows.contains("mic") {
                add(BarButton("Dictate", icon: Self.micImage()) { [weak self] in self?.onAction?(.dictate) }, .fixed(48), droppable: true)
            }
            // No meters: the rest stays at the left, after the character.
            if meters == nil { add(NSView(), .flex(weight: 1, min: 0)) }
            // Short: one button opens the whole bar; opened: one folds it back.
            if short || model.expanded,
               let icon = NSImage(systemSymbolName: short ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
                                  accessibilityDescription: short ? "Whole bar" : "Fold back") {
                let b = BarButton(short ? "Whole bar" : "Fold back", icon: icon) { [weak self] in
                    self?.onAction?(short ? .expand : .collapse)
                }
                add(b, .fixed(40))
            }

        case let .done(chat):
            // Cloud jumps twice and says which chat finished.
            let short = model.short
            let name = BarButton("✓ " + chat.name + " — done", style: .outline, fontSize: short ? 12 : 13,
                                 dot: chat.color, marquee: true) { [weak self] in self?.onAction?(.pickChat(chat.id)) }
            add(name, .flex(weight: 1, min: short ? 140 : 200))
            let open = BarButton("Open", style: .primary) { [weak self] in self?.onAction?(.pickChat(chat.id)) }
            let ok = BarButton("OK") { [weak self] in self?.onAction?(.dismissDone) }
            add(open, .fixed(short ? 64 : 84))
            add(ok, .fixed(short ? 50 : 64))
            [name, open, ok].forEach { b in animate(b) { $0.slideIn() } }
            if !Palette.reduceMotion {
                mascot.poke()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in self?.mascot.poke() }
            }

        case .contextWarning:
            let pair = MetersPair(padding: 8, contextWidth: 210)
            pair.contextAlarm = true
            meters = pair
            add(pair, .flex(weight: 1, min: 120))
            let compact = BarButton("Compact", style: .primary) { [weak self] in self?.onAction?(.compact) }
            let later = BarButton("Later") { [weak self] in self?.onAction?(.later) }
            add(compact, .fixed(110))
            add(later, .fixed(75))
            [compact, later].forEach { b in animate(b) { $0.slideIn() } }

        case let .permission(verb, detail):
            addRequestChat()
            let message = MessageView(verb: verb, detail: detail, monospaced: true, quiet: model.quiet)
            add(message, .flex(weight: 1, min: model.short ? 100 : 120))
            animate(message) { $0.slideIn() }
            let allow = BarButton("Allow", style: .primary) { [weak self] in self?.onAction?(.allow) }
            let always = BarButton("Always") { [weak self] in self?.onAction?(.always) }
            let deny = BarButton("Deny", style: .deny) { [weak self] in self?.onAction?(.deny) }
            add(allow, .fixed(model.short ? 76 : 100))
            add(always, .fixed(model.short ? 80 : 100))
            add(deny, .fixed(model.short ? 62 : 75))
            [allow, always, deny].forEach { b in animate(b) { $0.slideIn(delay: 0.06) } }

        case let .question(text, options, multi, picked):
            addRequestChat()
            let message = MessageView(verb: nil, detail: text, monospaced: false, quiet: model.quiet)
            add(message, .flex(weight: 1, min: 120))
            animate(message) { $0.slideIn() }
            var group: [NSView] = []
            for (i, label) in options.enumerated() {
                let b = BarButton(label, style: picked.contains(i) ? .selected : .normal) { [weak self] in
                    self?.onAction?(.option(i))
                }
                add(b, .shrinkable(min(b.fittingWidth(padding: model.short ? 10 : 14), model.short ? 130 : 180)))
                group.append(b)
            }
            if multi && !picked.isEmpty {
                let send = BarButton("Send", style: .primary) { [weak self] in self?.onAction?(.sendPicked) }
                add(send, .fixed(85))
                group.append(send)
            }
            let other = BarButton("Other…", style: .outline) { [weak self] in self?.onAction?(.other) }
            add(other, .fixed(other.fittingWidth(padding: 14)))
            group.append(other)
            group.forEach { b in animate(b) { $0.slideIn(delay: 0.06) } }

        case .models:
            var group: [NSView] = []
            let models = !pagedModels || !effortPage, efforts = !pagedModels || effortPage
            if models && !pagedModels {
                let modelWord = sectionLabel("Model")
                add(modelWord, .fixed(ceil(modelWord.intrinsicContentSize.width) + 2))
            }
            for choice in ModelChoice.models where models {
                let b = BarButton(choice.label, style: choice.alias == model.modelAlias ? .selected : .normal, fontSize: 12) {
                    [weak self] in self?.onAction?(.pickModel(choice.alias))
                }
                add(b, .shrinkable(b.fittingWidth(padding: 12)))
                group.append(b)
            }
            if efforts && !pagedModels {
                let effortWord = sectionLabel("Effort")
                add(effortWord, .fixed(ceil(effortWord.intrinsicContentSize.width) + 8))
            }
            for level in ModelChoice.efforts where efforts {
                let b = BarButton(level, style: level == model.effort ? .selected : .normal, fontSize: 12) {
                    [weak self] in self?.onAction?(.pickEffort(level))
                }
                add(b, .shrinkable(b.fittingWidth(padding: 12)))
                group.append(b)
            }
            if pagedModels {
                let flip = BarButton(effortPage ? "‹ Model" : "Effort ›", style: .outline, fontSize: 12) { [weak self] in
                    guard let self else { return }
                    self.effortPage.toggle()
                    self.rebuild()
                }
                add(flip, .fixed(flip.fittingWidth(padding: 14)))
                group.append(flip)
            }
            add(NSView(), .flex(weight: 1, min: 0))
            let done = BarButton("Done", style: .outline) { [weak self] in self?.onAction?(.closePanel) }
            add(done, .fixed(done.fittingWidth(padding: 14)))
            group.append(done)
            group.forEach { b in animate(b) { $0.slideIn(delay: 0.04) } }

        case .chats:
            var group: [NSView] = []
            let word = sectionLabel("Chats")
            add(word, .fixed(ceil(word.intrinsicContentSize.width) + 2))
            for chat in model.chats {
                // A whole name stands still; one that didn't get the room slides.
                let b = BarButton(chat.name + (chat.waiting ? " ●" : ""), style: chat.current ? .selected : .normal,
                                  fontSize: 12, dot: chat.color, marquee: true) { [weak self] in self?.onAction?(.pickChat(chat.id)) }
                add(b, .shrinkable(min(200, b.fittingWidth(padding: 12))))
                group.append(b)
            }
            add(NSView(), .flex(weight: 1, min: 0))
            let done = BarButton("Done", style: .outline) { [weak self] in self?.onAction?(.closePanel) }
            add(done, .fixed(done.fittingWidth(padding: 14)))
            group.append(done)
            group.forEach { b in animate(b) { $0.slideIn(delay: 0.04) } }

        case .templates:
            var group: [NSView] = []
            let word = sectionLabel("Templates")
            add(word, .fixed(ceil(word.intrinsicContentSize.width) + 2))
            for (i, text) in model.templates.enumerated() {
                let b = BarButton(text, fontSize: 12) { [weak self] in self?.onAction?(.pickTemplate(i)) }
                add(b, .shrinkable(min(220, b.fittingWidth(padding: 12))))
                group.append(b)
            }
            add(NSView(), .flex(weight: 1, min: 0))
            let done = BarButton("Done", style: .outline) { [weak self] in self?.onAction?(.closePanel) }
            add(done, .fixed(done.fittingWidth(padding: 14)))
            group.append(done)
            group.forEach { b in animate(b) { $0.slideIn(delay: 0.04) } }

        case .agents:
            var group: [NSView] = []
            let word = sectionLabel("Subagents")
            add(word, .fixed(ceil(word.intrinsicContentSize.width) + 2))
            if model.agents.isEmpty {
                let none = sectionLabel("none working right now")
                none.alignment = .left
                add(none, .fixed(ceil(none.intrinsicContentSize.width) + 4))
            }
            for label in model.agents {
                let b = BarButton(label, fontSize: 12)
                add(b, .shrinkable(min(260, b.fittingWidth(padding: 14))))
                group.append(b)
            }
            add(NSView(), .flex(weight: 1, min: 0))
            let done = BarButton("Done", style: .outline) { [weak self] in self?.onAction?(.closePanel) }
            add(done, .fixed(done.fittingWidth(padding: 14)))
            group.append(done)
            group.forEach { b in animate(b) { $0.slideIn(delay: 0.04) } }

        case .typing:
            let mini = MiniMetersView()
            self.mini = mini
            add(mini, .fixed(60))
            if !model.short {
                let label = NSTextField(labelWithString: model.typingLabel)
                label.font = .systemFont(ofSize: Palette.labelFont)
                label.textColor = Palette.secondary
                label.alignment = .right
                add(label, .fixed(ceil(label.intrinsicContentSize.width) + 4))
            }
            let field = TypingFieldView()
            field.placeholder = model.listening ? "Listening… speak" : model.typingPlaceholder
            self.field = field
            if model.typingCommands {
                let box = ChatBoxView(field: field, commands: commandButtons(limit: model.short ? 3 : nil), compact: model.short)
                add(box, .flex(weight: 1, min: 120 + box.commandsWidth))
                animate(box) { $0.slideIn(duration: 0.24) }
            } else {
                add(field, .flex(weight: 1, min: 120))
                animate(field) { $0.slideIn(duration: 0.24) }
            }
            let send = BarButton("Send", style: .primary) { [weak self] in self?.onAction?(.send) }
            let mic = BarButton("Dictate", style: model.listening ? .primary : .normal, icon: Self.micImage()) {
                [weak self] in self?.onAction?(.mic)
            }
            add(send, .fixed(model.short ? 70 : 85))
            if model.typingCommands && !model.short {
                // Your commands right by the field, if the bar shows them.
                if model.shows.contains("templates"), !model.templates.isEmpty,
                   let icon = NSImage(systemSymbolName: "text.badge.plus", accessibilityDescription: "Templates") {
                    add(BarButton("Templates", icon: icon) { [weak self] in self?.onAction?(.templates) }, .fixed(48))
                }
            }
            add(mic, .fixed(48))
            if let x = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel") {
                add(BarButton("Cancel", icon: x) { [weak self] in self?.onAction?(.cancelTyping) }, .fixed(40))
            }
        }
        needsLayout = true
    }

    /// Your buttons, small, for inside the chat field (if the bar shows them).
    private func commandButtons(limit: Int? = nil) -> [BarButton] {
        guard model.shows.contains("buttons") else { return [] }
        return model.buttons.enumerated().prefix(limit ?? .max).map { i, spec in
            BarButton(spec.label, fontSize: 11) { [weak self] in self?.onAction?(.button(i)) }
        }
    }

    /// Several chats: the one a request comes from, before it.
    private func addRequestChat() {
        guard model.chats.count > 1, let chat = model.requestChat else { return }
        let b = BarButton(chat.name, style: .outline, fontSize: 12, dot: chat.color, marquee: true)
        add(b, .shrinkable(min(130, b.fittingWidth(padding: 10))))
    }

    /// A small grey word before a group of buttons.
    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: Palette.labelFont)
        label.textColor = Palette.secondary
        label.alignment = .right
        return label
    }

    private func add(_ view: NSView, _ width: Slot.Width, droppable: Bool = false) {
        addSubview(view)
        slots.append(Slot(droppable: droppable, view: view, width: width))
    }

    private func animate(_ view: NSView, _ animation: @escaping (CALayer) -> Void) {
        view.wantsLayer = true
        animatedViews.append(view)
        pendingAnimations.append(animation)
    }

    /// A configured button: 13 pt, 15 pt padding, at most 130 pt wide; a
    /// long name drops to 11 pt, then gets "…".
    private func customButton(_ label: String, compact: Bool = false,
                              onTap: @escaping () -> Void) -> (button: BarButton, width: CGFloat) {
        if compact {
            // Beside Apple's buttons: 11 pt, tighter, at most 96 pt.
            let b = BarButton(label, fontSize: 11, onTap: onTap)
            return (b, min(96, max(44, b.fittingWidth(padding: 9))))
        }
        var b = BarButton(label, onTap: onTap)
        var width = b.fittingWidth(padding: 15)
        if width > 130 {
            b = BarButton(label, fontSize: 11, onTap: onTap)
            width = b.fittingWidth(padding: 12)
        }
        return (b, min(130, max(60, width)))
    }

    // MARK: Values

    /// Cloud jumps (tapped: it's woken up).
    func pokeCharacter() { mascot.poke() }
    /// Cloud waves (Claude said ☁️).
    func waveCharacter() { mascot.wave() }

    private func refreshValues() {
        mascot.activity = model.activity
        mascot.awake = model.awake
        meters?.set(session: model.sessionPercent,
                    countdown: model.mode == .normal && !model.shows.contains("reset") ? nil : model.resetCountdown,
                    context: model.contextPercent)
        mini?.set(session: model.sessionPercent, context: model.contextPercent)
        if case let .typing(text) = model.mode { field?.set(text: text) }
    }

    // MARK: Layout

    /// Diagnostics: the width the Touch Bar really gives, and what holds it.
    var onWidth: ((String) -> Void)?
    private var reportedWidth = ""

    /// `widths` brought down to `total`: as many as possible keep theirs
    /// (the narrowest first, while the others can still have `floor`), the
    /// rest share what's left equally, none under `floor` (or its own width).
    static func fitWidths(_ widths: [CGFloat], total: CGFloat, floor: CGFloat = 72) -> [CGFloat] {
        guard widths.reduce(0, +) > total else { return widths }
        let least = widths.map { min($0, floor) }
        let order = widths.indices.sorted { widths[$0] < widths[$1] }
        var kept = 0
        var used: CGFloat = 0
        for (n, i) in order.enumerated() {
            let others = order[(n + 1)...].reduce(CGFloat(0)) { $0 + least[$1] }
            guard used + widths[i] + others <= total else { break }
            used += widths[i]
            kept += 1
        }
        var out = widths
        let rest = order[kept...]
        guard !rest.isEmpty else { return out }
        let share = max(0, total - used) / CGFloat(rest.count)
        for i in rest { out[i] = min(widths[i], max(least[i], share)) }
        return out
    }

    override func layout() {
        super.layout()
        let report = "bounds \(Int(bounds.width)), superview \(Int(superview?.bounds.width ?? -1)), window \(Int(window?.frame.width ?? -1)), narrow \(narrow)"
        if report != reportedWidth { reportedWidth = report; onWidth?(report) }
        let available = bounds.width - Palette.edge * 2
        // Too much even when shrunk: leave out droppable things from the right.
        var shown = Array(slots.indices)
        func need(_ list: [Int]) -> CGFloat {
            list.reduce(CGFloat(0)) { sum, i in
                switch slots[i].width {
                case let .fixed(w): return sum + w
                case let .shrinkable(w): return sum + min(w, 72) // readable, not crammed
                case let .flex(_, min): return sum + min
                }
            } + Palette.gap * CGFloat(max(0, list.count - 1))
        }
        while need(shown) > available, let last = shown.lastIndex(where: { slots[$0].droppable }) {
            shown.remove(at: last)
        }
        for i in slots.indices { slots[i].view.isHidden = !shown.contains(i) }
        let vis = shown.map { slots[$0] }

        let gaps = Palette.gap * CGFloat(max(0, vis.count - 1))
        var widths: [CGFloat] = vis.map {
            switch $0.width {
            case let .fixed(w), let .shrinkable(w): return w
            case .flex: return 0
            }
        }
        let fixed = widths.reduce(0, +)
        let flexMin = vis.reduce(CGFloat(0)) {
            if case let .flex(_, min) = $1.width { return $0 + min }
            return $0
        }
        // The model picker doesn't fit in one row: models and effort take turns.
        if model.mode == .models && !pagedModels && fixed + gaps + flexMin > available && bounds.width > 0 {
            pagedModels = true
            rebuild()
            layout()
            return
        }
        // Not enough room: shrinkable slots give way first — as many as can
        // keep their whole names do (the shortest first); the rest share
        // what's left, and their names slide.
        let overflow = fixed + gaps + flexMin - available
        if overflow > 0 {
            let shrinkable = vis.indices.filter { if case .shrinkable = vis[$0].width { return true }; return false }
            let total = shrinkable.reduce(CGFloat(0)) { $0 + widths[$1] }
            if total > 0 {
                let fitted = Self.fitWidths(shrinkable.map { widths[$0] }, total: total - overflow)
                for (i, w) in zip(shrinkable, fitted) { widths[i] = w }
            }
        }
        // Flexible slots: each its minimum first, then the rest by weight.
        let remaining = max(0, available - gaps - widths.reduce(0, +))
        let weights = vis.reduce(CGFloat(0)) {
            if case let .flex(w, _) = $1.width { return $0 + w }
            return $0
        }
        let extra = max(0, remaining - flexMin)
        let squeeze = flexMin > 0 ? min(1, remaining / flexMin) : 1
        for (i, slot) in vis.enumerated() {
            if case let .flex(w, min) = slot.width, weights > 0 {
                widths[i] = min * squeeze + extra * w / weights
            }
        }

        var x = Palette.edge
        for (slot, width) in zip(vis, widths) {
            var h = Palette.height
            if slot.view === mascot { h = 28 }
            if slot.view === widgetButton {
                mascot.frame = CGRect(x: (width - 28) / 2, y: 1, width: 28, height: 28)
            }
            if let label = slot.view as? NSTextField { h = ceil(label.intrinsicContentSize.height) }
            slot.view.frame = CGRect(x: x, y: (bounds.height - h) / 2, width: width, height: h)
            x += width + Palette.gap
        }

        if !pendingAnimations.isEmpty {
            let runs = zip(animatedViews, pendingAnimations)
            for (view, run) in runs { if let l = view.layer { run(l) } }
            pendingAnimations = []
            animatedViews = []
        }
    }

    // MARK: Icons

    /// The microphone from TB-Typing (stroke 1.8 on a 24 grid), 14 pt.
    static func micImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: true) { rect in
            let s = rect.width / 24
            NSColor.black.setStroke()
            let body = NSBezierPath(roundedRect: NSRect(x: 9 * s, y: 3 * s, width: 6 * s, height: 11 * s),
                                    xRadius: 3 * s, yRadius: 3 * s)
            let cup = NSBezierPath()
            cup.move(to: NSPoint(x: 5 * s, y: 11 * s))
            cup.curve(to: NSPoint(x: 19 * s, y: 11 * s),
                      controlPoint1: NSPoint(x: 5 * s, y: 20.3 * s),
                      controlPoint2: NSPoint(x: 19 * s, y: 20.3 * s))
            let stem = NSBezierPath()
            stem.move(to: NSPoint(x: 12 * s, y: 18 * s))
            stem.line(to: NSPoint(x: 12 * s, y: 21 * s))
            for path in [body, cup, stem] {
                path.lineWidth = 1.8 * s
                path.lineCapStyle = .round
                path.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// Session and Context side by side, 3 : 2, with TB-Normal's shrinking
/// labels. In the context warning Context gets a fixed width and turns red.
private final class MetersPair: NSView {
    private let session = MeterView()
    private let context = MeterView()
    private let padding: CGFloat
    private let contextWidth: CGFloat?
    private let showSession: Bool
    private let showContext: Bool
    private var values: (Double?, String?, Double?) = (nil, nil, nil)

    var contextAlarm = false { didSet { context.alarm = contextAlarm } }

    init(padding: CGFloat, contextWidth: CGFloat? = nil, showSession: Bool = true, showContext: Bool = true) {
        self.padding = padding
        self.contextWidth = contextWidth
        self.showSession = showSession
        self.showContext = showContext
        super.init(frame: .zero)
        context.breathesWhenFull = true
        if showSession { addSubview(session) }
        if showContext { addSubview(context) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(session s: Double?, countdown: String?, context c: Double?) {
        values = (s, countdown, c)
        applyLabels()
    }

    private func applyLabels() {
        // Thresholds from renderVals: 900 / 560 px of room = 450 / 280 pt.
        let room = bounds.width
        let wide = room >= 450 || contextWidth != nil
        let mid = room >= 280 || contextWidth != nil
        session.set(title: wide ? "Session" : mid ? "5h" : "", percent: values.0,
                    detail: mid ? values.1 : nil)
        context.set(title: wide ? "Context" : mid ? "Ctx" : "", percent: values.2, detail: nil)
    }

    override func layout() {
        super.layout()
        let inner = bounds.insetBy(dx: padding, dy: 0)
        if let fixed = contextWidth {
            // TB-Context: Session takes the rest, Context a fixed 210 pt,
            // each with its own padding.
            let cw = min(fixed - padding * 2, inner.width / 2)
            context.frame = CGRect(x: bounds.maxX - padding - cw, y: 0, width: cw, height: bounds.height)
            session.frame = CGRect(x: inner.minX, y: 0, width: max(0, context.frame.minX - padding * 2 - inner.minX),
                                   height: bounds.height)
        } else if !showSession || !showContext {
            // Just one of them: it takes the room.
            (showSession ? session : context).frame = CGRect(x: inner.minX, y: 0, width: inner.width, height: bounds.height)
        } else {
            let spacing: CGFloat = 14
            let w = max(0, inner.width - spacing)
            session.frame = CGRect(x: inner.minX, y: 0, width: w * 3 / 5, height: bounds.height)
            context.frame = CGRect(x: session.frame.maxX + spacing, y: 0, width: w * 2 / 5, height: bounds.height)
        }
        applyLabels()
    }
}

/// "● Run npm test" / "● Storage for offline routes?" — the pulsing orange
/// dot, an optional grey verb, and the text, cut with "…" when long.
private final class MessageView: NSView {
    private let dot = CALayer()
    private let verbLabel: NSTextField?
    private let detailLabel: NSTextField

    init(verb: String?, detail: String, monospaced: Bool, quiet: Bool) {
        verbLabel = verb.map { v in
            let l = NSTextField(labelWithString: v)
            l.font = .systemFont(ofSize: Palette.buttonFont)
            l.textColor = Palette.secondary
            return l
        }
        detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = monospaced
            ? .monospacedSystemFont(ofSize: Palette.buttonFont, weight: .regular)
            : .systemFont(ofSize: Palette.buttonFont)
        detailLabel.textColor = Palette.text
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.cell?.truncatesLastVisibleLine = true
        super.init(frame: .zero)
        wantsLayer = true
        dot.backgroundColor = Palette.warning.cgColor
        dot.cornerRadius = 3
        layer?.addSublayer(dot)
        if !quiet { dot.pulse(low: 0.35, period: 1.4) }
        if let verbLabel { addSubview(verbLabel) }
        addSubview(detailLabel)
        setAccessibilityElement(true)
        setAccessibilityLabel([verb, detail].compactMap { $0 }.joined(separator: " "))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let pad: CGFloat = 8
        let spacing: CGFloat = 7
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = CGRect(x: pad, y: (bounds.height - 6) / 2, width: 6, height: 6)
        CATransaction.commit()
        var x = pad + 6 + spacing
        let h = ceil(detailLabel.intrinsicContentSize.height)
        let y = (bounds.height - h) / 2
        if let verbLabel {
            let w = ceil(verbLabel.intrinsicContentSize.width)
            verbLabel.frame = CGRect(x: x, y: y, width: w, height: h)
            x += w + spacing
        }
        detailLabel.frame = CGRect(x: x, y: y, width: max(0, bounds.width - x - pad), height: h)
    }
}
