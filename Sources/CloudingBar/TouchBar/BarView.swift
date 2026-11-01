import AppKit

/// The whole Touch Bar as one view, laid out like design/TB-*.dc.html:
///
///   normal      [character] · Session ─── · Context ── · buttons
///   permission  [character] · ● Run `command` · Allow · Always · Deny
///   question    [character] · ● Question? · option · option · Other…
///   typing      [character] · ═ · Other [answer________] · Send · 🎤
///   written to  [character] · → Lead bot · [words________] · 📷 · 🎤 · Send · ↗
///               (a chat picked from the chats list, not the one followed)
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
        typealias Width = BarLayout.Width
        let view: NSView
        let width: Width
        /// The block's name in Settings' arrangement ("meters", "chat", …).
        var key: String?
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
        let key = BarModel.structureKey(new)
        if new.mode != .models { pagedModels = false; effortPage = false }
        model = new
        if key != builtFor {
            builtFor = key
            rebuild()
        }
        refreshValues()
    }

    /// Where each named block is, after layout (Settings' arranging).
    var blocks: [(key: String, frame: NSRect)] {
        slots.compactMap { s in s.key.flatMap { s.view.isHidden ? nil : ($0, s.view.frame) } }
    }

    /// How wide each block may get before something has to leave the bar:
    /// Settings stops a drag at that edge instead (owner, 27.10).
    private(set) var widest: [String: CGFloat] = [:]

    // MARK: Building

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        slots = []
        meters = nil
        resetBlock = nil
        questionMessage = nil
        doneMessage = nil
        mini = nil
        field = nil
        pendingAnimations = []
        animatedViews = []

        // Cloud: narrower on the short bar, for room (owner, 26.10).
        add(widgetButton, .fixed(model.mode == .normal && model.short ? Self.shortCloud : 60))

        switch model.mode {
        case .normal where model.short:
            buildShort()

        case .normal:
            let short = model.short
            let shows = model.shows
            // The blocks, each with its key (Settings arranges them by it):
            // in their own order unless you dragged them, at their own width
            // unless you dragged that too.
            var blocks: [(key: String, view: NSView, width: Slot.Width, droppable: Bool)] = []
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
                // Short, or dragged narrow in Settings: its first letter, a
                // capital (owner, 24.10); a tap lists the chats by name.
                let initial = (model.widths["name"] ?? .infinity) < 70 || short
                let letter = chat.name.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "•"
                // On the whole bar, dragged narrow: the dot and the letter are one —
                // a bold capital in the chat's colour, no dot (owner, 27.10). The
                // short bar keeps the dot and the letter.
                let merged = initial && !short
                let b = BarButton(initial ? letter : chat.name, fontSize: short ? 11 : merged ? 14 : 12,
                                  dot: merged ? nil : chat.color, tint: merged ? chat.color : nil,
                                  weight: merged ? .bold : nil, marquee: true, slide: false) {
                    [weak self] in self?.onAction?(.chats)
                }
                b.setAccessibilityLabel(chat.name)
                // A name that fits keeps its room (it stands still); a long one
                // slides through a narrow button, not half the bar (owner, 24.10).
                var cap: CGFloat = 130
                if short {
                    // Room beside Cloud (60), half the bar, the commands and "whole bar" (40).
                    cap = min(cap, shortHalf - 60 - 40 - shortBoxWidth - Palette.gap * (shortBox == nil ? 2 : 3))
                }
                let fit = max(b.fittingWidth(padding: short ? 8 : 10), 44)
                if cap >= min(fit, 60) || model.widths["name"] != nil {
                    blocks.append(("name", b, fit <= cap ? .fixed(fit) : .shrinkable(cap), false))
                }
            }
            let session = shows.contains("session"), context = shows.contains("context")
            if session || context {
                let pair = MetersPair(padding: 6, showSession: session, showContext: context)
                meters = pair
                blocks.append(("meters", pair, .flex(weight: 1, min: short ? shortHalf : session && context ? 120 : 80), false))
            }
            // The time to the reset as a block of its own: in the meters it only
            // showed from 280 pt, so often not at all (owner, 26.10).
            if shows.contains("reset") {
                let b = BarButton(model.resetCountdown ?? "—", fontSize: 12, symbol: ("clock", 0x8E8E93))
                b.setAccessibilityLabel("Resets in " + (model.resetCountdown ?? "—"))
                resetBlock = b
                blocks.append(("reset", b, .shrinkable(64), true)) // the clock and up to "4:59"
            }
            // Switched on, it shows: "—" until it's known (owner, 25.10).
            if shows.contains("model") {
                let b = BarButton(model.modelLabel ?? "—", fontSize: short ? 11 : 12, symbol: ("cpu", 0xBF5AF2)) { [weak self] in self?.onAction?(.models) }
                blocks.append(("model", b, .shrinkable(min(short ? 120 : 190, b.fittingWidth(padding: short ? 8 : 12))), true))
            }
            if shows.contains("agents") {
                let n = model.agents.count
                let b = BarButton(n == 0 ? "No agents" : "\(n) agent\(n == 1 ? "" : "s")", fontSize: 12,
                                  symbol: ("person.2.fill", 0x40C8E0)) {
                    [weak self] in self?.onAction?(.agents)
                }
                blocks.append(("agents", b, .shrinkable(b.fittingWidth(padding: short ? 8 : 14)), true))
            }
            // What the widget shows besides: lines, branch, cost.
            for (key, text, symbol) in [("lines", model.lines, ("chevron.left.forwardslash.chevron.right", UInt32(0x30D158))),
                                        ("branch", model.branch, ("arrow.triangle.branch", UInt32(0xFF9F0A))),
                                        ("cost", model.cost, ("dollarsign.circle", UInt32(0xFFD60A)))] {
                guard shows.contains(key) else { continue }
                let b = BarButton(text ?? "—", fontSize: short ? 11 : 12, symbol: symbol)
                blocks.append((key, b, .shrinkable(min(short ? 100 : 150, b.fittingWidth(padding: short ? 8 : 12))), true))
            }
            var chatMin: CGFloat = 0
            if short {
                if let shortBox {
                    blocks.append(("chat", shortBox, .fixed(shortBoxWidth), true))
                    chatMin = shortBoxWidth
                }
            } else if shows.contains("chat") {
                // The chat's name is on the bar already when there are several.
                let placeholder = model.current != nil ? "Message…" : model.chatName.map { "Write to “\($0)”…" } ?? "Message…"
                let field = ComposeFieldButton(placeholder: placeholder) {
                    [weak self] in self?.onAction?(.write)
                }
                // Your commands inside it, one whole.
                let box = ChatBoxView(field: field, commands: commandButtons(), compact: false)
                blocks.append(("chat", box, .flex(weight: 1.2, min: 150 + box.commandsWidth), true))
                chatMin = box.commandsWidth + 40
            }
            if shows.contains("templates") {
                let b = BarButton(short ? "" : "Commands", fontSize: 12, symbol: ("text.badge.plus", 0xBF5AF2)) { [weak self] in
                    self?.onAction?(.templates)
                }
                blocks.append(("templates", b, short ? .fixed(40) : .shrinkable(b.fittingWidth(padding: 14)), true))
            }
            // With the chat field, your buttons are inside it.
            if !short && shows.contains("buttons") && !shows.contains("chat") {
                for (i, spec) in model.buttons.enumerated() {
                    let b = customButton(spec.label, compact: short) { [weak self] in self?.onAction?(.button(i)) }
                    blocks.append(("button:" + spec.label, b.button, .shrinkable(b.width), true))
                    animate(b.button) { $0.popIn() }
                }
            }
            // Short: no screenshot or mic — the chats, the limits and the
            // message box with its commands only; they're on the whole bar
            // (owner, 24.10).
            if !short, shows.contains("shot"), let icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Screenshot") {
                blocks.append(("shot", BarButton("Screenshot", icon: icon) { [weak self] in self?.onAction?(.screenshot) }, .fixed(48), true))
            }
            if !short, shows.contains("mic") {
                blocks.append(("mic", BarButton("Dictate", icon: Self.micImage()) { [weak self] in self?.onAction?(.dictate) }, .fixed(48), true))
            }
            // Your order; one not in it (new since you arranged the bar, like
            // the reset) right after the block it follows here, not last —
            // the first to go when room runs out (owner, 26.10).
            let place = Self.places(blocks.map(\.key), order: model.order)
            let ordered = blocks.enumerated().sorted { (place[$0.offset], $0.offset) < (place[$1.offset], $1.offset) }.map(\.element)
            var flexible = false
            for b in ordered {
                var width = b.width
                if let w = model.widths[b.key] {
                    // Dragged: that width, never so narrow its commands don't fit.
                    width = .fixed(max(w, b.key == "chat" ? chatMin : 24))
                }
                if case .flex = width { flexible = true }
                add(b.view, width, droppable: b.droppable, key: b.key)
            }
            // No meters, or nothing that stretches: the rest stays at the left.
            if meters == nil || !flexible { add(NSView(), .flex(weight: 1, min: 0)) }
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
            // Cloud jumps twice and says which chat finished — and, with its
            // answer known, how that begins (a tap opens the chat too).
            let short = model.short
            let name = BarButton("✓ " + chat.name + (model.doneAnswer == nil ? " — done" : ""), style: .outline,
                                 fontSize: short ? 12 : 13, dot: chat.color, marquee: true, slide: false) {
                [weak self] in self?.onAction?(.pickChat(chat.id))
            }
            if let answer = model.doneAnswer {
                add(name, .shrinkable(min(short ? 150 : 260, name.fittingWidth(padding: 10))))
                let words = MessageView(verb: nil, detail: answer, monospaced: false, quiet: true, dotted: false)
                words.onTap = { [weak self] in self?.onAction?(.pickChat(chat.id)) }
                doneMessage = words
                add(words, .flex(weight: 1, min: short ? 120 : 200))
                animate(words) { $0.slideIn() }
            } else {
                add(name, .flex(weight: 1, min: short ? 140 : 200))
            }
            let open = BarButton("Open", style: .primary) { [weak self] in self?.onAction?(.pickChat(chat.id)) }
            let ok = BarButton("OK") { [weak self] in self?.onAction?(.dismissDone) }
            add(open, .fixed(short ? 64 : 84))
            add(ok, .fixed(short ? 50 : 64))
            // The name slides (marquee): no slide-in for it, the two together
            // left a name empty on the Touch Bar (owner, 26.10).
            [open, ok].forEach { b in animate(b) { $0.slideIn() } }
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
            message.onTap = { [weak self] in self?.onAction?(.showRequest) }
            add(message, .flex(weight: 1, min: model.short ? 100 : 120))
            animate(message) { $0.slideIn() }
            let allow = BarButton("Allow", style: .primary) { [weak self] in self?.onAction?(.allow) }
            let always = BarButton("Always") { [weak self] in self?.onAction?(.always) }
            let deny = BarButton("Deny", style: .deny) { [weak self] in self?.onAction?(.deny) }
            add(allow, .fixed(model.short ? 76 : 100))
            if model.offersAlways { add(always, .fixed(model.short ? 80 : 100)) }
            add(deny, .fixed(model.short ? 62 : 75))
            (model.offersAlways ? [allow, always, deny] : [allow, deny]).forEach { b in animate(b) { $0.slideIn(delay: 0.06) } }

        case let .question(text, options, multi, picked):
            addRequestChat()
            let message = MessageView(verb: nil, detail: text, monospaced: false, quiet: model.quiet)
            message.onTap = { [weak self] in self?.onAction?(.showRequest) }
            questionMessage = message
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
            // A tap writes to that chat from here; ↗ on its line goes there.
            let word = sectionLabel("Write to")
            add(word, .fixed(ceil(word.intrinsicContentSize.width) + 2))
            for chat in model.chats {
                // A whole name stands still; one that didn't get the room slides.
                let b = BarButton(chat.name + (chat.waiting ? " ●" : ""), style: chat.current ? .selected : .normal,
                                  fontSize: 12, dot: chat.color, marquee: true, slide: false) { [weak self] in self?.onAction?(.writeTo(chat.id)) }
                add(b, .shrinkable(min(200, b.fittingWidth(padding: 12))))
                // No slide-in for the chats: a name that slides (too long, or
                // squeezed among many) came out empty with both on the Touch
                // Bar (owner, 26.10); the name button of the normal bar never
                // slid in, and showed.
            }
            add(NSView(), .flex(weight: 1, min: 0))
            // A small ✕, more room for the chats (owner, 27.10).
            let done = BarButton("Done", style: .outline,
                                 icon: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Done")?
                                    .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))) { [weak self] in
                self?.onAction?(.closePanel)
            }
            add(done, .fixed(40))
            group.append(done)
            group.forEach { b in animate(b) { $0.slideIn(delay: 0.04) } }

        case .templates:
            var group: [NSView] = []
            let word = sectionLabel("Commands")
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
            if let to = model.typingTo {
                addLine(to: to)
                break
            }
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
                   let icon = NSImage(systemSymbolName: "text.badge.plus", accessibilityDescription: "Commands") {
                    add(BarButton("Commands", icon: icon) { [weak self] in self?.onAction?(.templates) }, .fixed(48))
                }
            }
            add(mic, .fixed(48))
            if let x = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Cancel") {
                add(BarButton("Cancel", icon: x) { [weak self] in self?.onAction?(.cancelTyping) }, .fixed(40))
            }
        }
        needsLayout = true
    }

    /// The message line written for a chat picked from the list (owner,
    /// 27.10): "→ chat" in its colour — a tap goes back to the list — the
    /// words, a screenshot and the mic for that chat, Send, and ↗ at the end,
    /// the one way into that chat (followed and opened, as a pick was before).
    private func addLine(to chat: BarModel.Chat) {
        let files = model.typingFiles == 0 ? "" : model.typingFiles == 1 ? " · 1 file" : " · \(model.typingFiles) files"
        let chip = BarButton("→ " + chat.name + files, style: .outline, fontSize: 12, dot: chat.color,
                             weight: .semibold, border: chat.color, marquee: true, slide: false) { [weak self] in self?.onAction?(.chats) }
        chip.setAccessibilityLabel("To \(chat.name)\(files) — back to the chats")
        add(chip, .shrinkable(min(model.short ? 130 : 190, chip.fittingWidth(padding: 10))))
        let field = TypingFieldView()
        field.placeholder = model.listening ? "Listening… speak" : model.typingPlaceholder
        self.field = field
        add(field, .flex(weight: 1, min: 120))
        animate(field) { $0.slideIn(duration: 0.24) }
        if let icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Screenshot") {
            add(BarButton("Screenshot for \(chat.name)", icon: icon) { [weak self] in self?.onAction?(.screenshot) },
                .fixed(model.short ? 40 : 48))
        }
        add(BarButton("Dictate", style: model.listening ? .primary : .normal, icon: Self.micImage()) {
            [weak self] in self?.onAction?(.mic)
        }, .fixed(model.short ? 40 : 48))
        add(BarButton("Send", style: .primary) { [weak self] in self?.onAction?(.send) }, .fixed(model.short ? 64 : 85))
        if let icon = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: "Open \(chat.name)") {
            add(BarButton("Open \(chat.name)", style: .outline, icon: icon) { [weak self] in self?.onAction?(.pickChat(chat.id)) },
                .fixed(40))
        }
    }

    /// Your buttons, small, for inside the chat field (if the bar shows them).
    /// Your commands for the chat line; `always`: the short bar's chat line
    /// has them whatever "Buttons" says (owner, 26.10: the chat with commands).
    private func commandButtons(limit: Int? = nil, always: Bool = false) -> [BarButton] {
        guard always || model.shows.contains("buttons") else { return [] }
        return model.buttons.enumerated().prefix(limit ?? .max).map { i, spec in
            BarButton(spec.label, fontSize: 11) { [weak self] in self?.onAction?(.button(i)) }
        }
    }

    /// Several chats: the one a request comes from, before it.
    private func addRequestChat() {
        guard model.chats.count > 1, let chat = model.requestChat else { return }
        let b = BarButton(chat.name, style: .outline, fontSize: 12, dot: chat.color, marquee: true, slide: false)
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

    /// Beside Apple's buttons (owner, 26.10): a bar of its own, apart from
    /// the whole one — what you keep at hand everywhere, in your order, each
    /// block at its own fixed size (none pulled wider). By default the chat's
    /// letter, the limits, the chat line with your commands, the screenshot
    /// and the mic; something else goes in when something comes out
    /// (Settings says when there's no room).
    private func buildShort() {
        let shows = model.shows
        var blocks: [(key: String, view: NSView, width: CGFloat, droppable: Bool)] = []
        // The chat: its project's first letter, a capital, no dot (owner,
        // 26.10), in the chat's colour and a little bolder (owner, 27.10);
        // a tap lists the chats to switch.
        if shows.contains("name") {
            let chat = model.chats.first(where: \.current)
            let source = model.project ?? chat?.name ?? ""
            let letter = source.first(where: { $0.isLetter || $0.isNumber }).map { String($0).uppercased() } ?? "—"
            let b = BarButton(letter, fontSize: 13, tint: chat?.color, weight: .semibold) { [weak self] in self?.onAction?(.chats) }
            b.setAccessibilityLabel(chat?.name ?? "Chats")
            blocks.append(("name", b, Self.shortWidth("name", shows: shows), false))
        }
        let session = shows.contains("session"), context = shows.contains("context")
        if session || context {
            let pair = MetersPair(padding: 6, showSession: session, showContext: context)
            meters = pair
            blocks.append(("meters", pair, Self.shortWidth("meters", shows: shows), false))
        }
        if shows.contains("reset") {
            // The time alone: with the clock it was squeezed (owner, 26.10).
            let b = BarButton(model.resetCountdown ?? "—", fontSize: 12)
            b.setAccessibilityLabel("Resets in " + (model.resetCountdown ?? "—"))
            resetBlock = b // kept up to the minute by refreshValues
            blocks.append(("reset", b, Self.shortWidth("reset", shows: shows), true))
        }
        if shows.contains("model") {
            // A purple dot, not the chip icon: the name slides when it doesn't fit.
            let b = BarButton(model.modelLabel ?? "—", fontSize: 11, dot: 0xBF5AF2, marquee: true) { [weak self] in self?.onAction?(.models) }
            blocks.append(("model", b, Self.shortWidth("model", shows: shows), true))
        }
        if shows.contains("agents") {
            let n = model.agents.count
            let b = BarButton(n == 0 ? "No agents" : "\(n) agent\(n == 1 ? "" : "s")", fontSize: 11,
                              symbol: ("person.2.fill", 0x40C8E0)) { [weak self] in self?.onAction?(.agents) }
            blocks.append(("agents", b, Self.shortWidth("agents", shows: shows), true))
        }
        for (key, text, symbol) in [("lines", model.lines, ("chevron.left.forwardslash.chevron.right", UInt32(0x30D158))),
                                    ("branch", model.branch, ("arrow.triangle.branch", UInt32(0xFF9F0A))),
                                    ("cost", model.cost, ("dollarsign.circle", UInt32(0xFFD60A)))] where shows.contains(key) {
            blocks.append((key, BarButton(text ?? "—", fontSize: 11, symbol: symbol), Self.shortWidth(key, shows: shows), true))
        }
        // Your commands: in the chat line, or behind Commands.
        let chat = shows.contains("chat")
        if shows.contains("templates"), let icon = NSImage(systemSymbolName: "text.badge.plus", accessibilityDescription: "Commands") {
            // An icon alone, centred, like the screenshot and the mic.
            blocks.append(("templates", BarButton("Commands", icon: icon) { [weak self] in self?.onAction?(.templates) },
                           Self.shortWidth("templates", shows: shows), true))
        }
        if shows.contains("shot"), let icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Screenshot") {
            blocks.append(("shot", BarButton("Screenshot", icon: icon) { [weak self] in self?.onAction?(.screenshot) },
                           Self.shortWidth("shot", shows: shows), true))
        }
        if shows.contains("mic") {
            blocks.append(("mic", BarButton("Dictate", icon: Self.micImage()) { [weak self] in self?.onAction?(.dictate) },
                           Self.shortWidth("mic", shows: shows), true))
        }
        // As many as fit (Settings keeps it to what fits), in the order
        // shown; the chat line takes what's left, with as many commands as fit.
        // A gap after Cloud and after each block, the chat line or the spacer.
        var room = Self.shortRoom - Palette.gap * CGFloat(blocks.count + 2) - (chat ? Self.shortChatMin : 0)
        var kept: [(key: String, view: NSView, width: CGFloat, droppable: Bool)] = []
        for b in blocks where b.width <= room {
            room -= b.width
            kept.append(b)
        }
        if chat {
            let width = room + Self.shortChatMin
            var commands = commandButtons(limit: 3, always: true)
            func box() -> ChatBoxView {
                ChatBoxView(field: ComposeFieldButton(placeholder: "Write…") { [weak self] in self?.onAction?(.write) },
                            commands: commands, compact: true)
            }
            var b = box()
            while !commands.isEmpty && b.commandsWidth + 56 > width {
                commands.removeLast()
                b = box()
            }
            kept.append(("chat", b, width, true))
        }
        // Your order; else the chat line before the tools, as on the whole bar.
        // The chat line gives way first where the bar is narrower than 628 pt.
        let natural = ["name", "meters", "reset", "model", "agents", "lines", "branch", "cost", "chat", "templates", "shot", "mic"]
        let keys = kept.map(\.key).sorted { (natural.firstIndex(of: $0) ?? natural.count) < (natural.firstIndex(of: $1) ?? natural.count) }
        let places = Dictionary(zip(keys, Self.places(keys, order: model.order)), uniquingKeysWith: { a, _ in a })
        func place(_ key: String) -> Double { places[key] ?? Double(model.order.count) }
        for b in kept.enumerated().sorted(by: { (place($0.element.key), $0.offset) < (place($1.element.key), $1.offset) }).map(\.element) {
            add(b.view, b.key == "chat" ? .flex(weight: 1, min: Self.shortChatMin) : .fixed(b.width), droppable: b.droppable, key: b.key)
        }
        if !chat { add(NSView(), .flex(weight: 1, min: 0)) }
        if let icon = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Whole bar") {
            add(BarButton("Whole bar", icon: icon) { [weak self] in self?.onAction?(.expand) }, .fixed(Self.shortWhole))
        }
    }

    /// Where each block goes (BarLayout).
    static func places(_ keys: [String], order: [String]) -> [Double] { BarLayout.places(keys, order: order) }

    /// The reset block, its countdown set as it changes.
    private weak var resetBlock: BarButton?
    /// The question's words, swapped for their short form in place.
    private weak var questionMessage: MessageView?
    /// Done: the answer's start, its words swapped in place.
    private weak var doneMessage: MessageView?

    /// The short bar: Cloud and "Whole bar" at its ends, the chat line at
    /// the least room to tap and write.
    static let shortCloud: CGFloat = 44
    static let shortWhole: CGFloat = 36
    static let shortChatMin = BarLayout.shortChatMin
    /// What the short bar has for its blocks, beside Cloud and "Whole bar".
    static var shortRoom: CGFloat { narrowWidth - Palette.edge * 2 - shortCloud - shortWhole }

    /// Each short-bar block's own size; the chat line takes what's left.
    static func shortWidth(_ key: String, shows: Set<String>) -> CGFloat { BarLayout.shortWidth(key, shows: shows) }

    /// Whether these fit on the short bar, each block at its size.
    static func shortFits(_ shows: Set<String>) -> Bool { BarLayout.shortFits(shows, room: shortRoom, gap: Palette.gap) }

    private func add(_ view: NSView, _ width: Slot.Width, droppable: Bool = false, key: String? = nil) {
        addSubview(view)
        slots.append(Slot(droppable: droppable, view: view, width: width, key: key))
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

    private func refreshValues() {
        mascot.variant = model.cloudVariant
        mascot.activity = model.activity
        mascot.awake = model.awake
        if case let .question(text, _, _, _) = model.mode { questionMessage?.setDetail(text) }
        if case .done = model.mode, let answer = model.doneAnswer { doneMessage?.setDetail(answer) }
        if let b = resetBlock {
            b.setTitle(model.resetCountdown ?? "—")
            b.setAccessibilityLabel("Resets in " + (model.resetCountdown ?? "—"))
        }
        // The short bar: no countdown to the reset (owner, 24.10).
        meters?.set(session: model.sessionPercent,
                    // The bar's own: the reset is a block of its own.
                    countdown: model.mode == .normal ? nil : model.resetCountdown,
                    context: model.contextPercent)
        mini?.set(session: model.sessionPercent, context: model.contextPercent)
        if case let .typing(text) = model.mode { field?.set(text: text) }
    }

    // MARK: Layout

    /// Diagnostics: the width the Touch Bar really gives, and what holds it.
    var onWidth: ((String) -> Void)?
    private var reportedWidth = ""

    static func fitWidths(_ widths: [CGFloat], total: CGFloat, floor: CGFloat = 72) -> [CGFloat] {
        BarLayout.fitWidths(widths, total: total, floor: floor)
    }

    override func layout() {
        super.layout()
        let report = "bounds \(Int(bounds.width)), superview \(Int(superview?.bounds.width ?? -1)), window \(Int(window?.frame.width ?? -1)), narrow \(narrow)"
        if report != reportedWidth { reportedWidth = report; onWidth?(report) }
        let available = bounds.width - Palette.edge * 2
        // Too much even when shrunk: leave out droppable things from the right.
        func need(_ list: [Int]) -> CGFloat { BarLayout.need(list.map { slots[$0].width }, gap: Palette.gap) }
        let shown = BarLayout.shown(slots.map { (width: $0.width, droppable: $0.droppable) }, available: available, gap: Palette.gap)
        // Dragged wider, a block is fixed at that width: it may take the room
        // left over plus what the others give way down to.
        let used = need(shown)
        widest = [:]
        for i in shown { if let key = slots[i].key { widest[key] = available - used + need([i]) } }
        for i in slots.indices { slots[i].view.isHidden = !shown.contains(i) }
        let vis = shown.map { slots[$0] }

        // The model picker doesn't fit in one row: models and effort take turns.
        if model.mode == .models && !pagedModels && BarLayout.overflow(vis.map(\.width), available: available, gap: Palette.gap) > 0 && bounds.width > 0 {
            pagedModels = true
            rebuild()
            layout()
            return
        }
        let widths = BarLayout.widths(vis.map(\.width), available: available, gap: Palette.gap)

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

    /// The warning's dot before the words: `dotted` false for words that
    /// don't wait on you (a done chat's answer).
    private let dotted: Bool

    init(verb: String?, detail: String, monospaced: Bool, quiet: Bool, dotted: Bool = true) {
        self.dotted = dotted
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
        if dotted {
            layer?.addSublayer(dot)
            if !quiet { dot.pulse(low: 0.35, period: 1.4) }
        }
        if let verbLabel { addSubview(verbLabel) }
        addSubview(detailLabel)
        setAccessibilityElement(true)
        setAccessibilityLabel([verb, detail].compactMap { $0 }.joined(separator: " "))
        // A finger on the Touch Bar: direct touches only — asking for indirect
        // ones too throws on macOS 27 ("only NSTouchTypeDirect is supported").
        let tap = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        tap.allowedTouchTypes = .direct
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// A tap: the whole question or command.
    var onTap: (() -> Void)?

    /// The words changed in place (the question's short form came): no rebuild.
    func setDetail(_ text: String) {
        guard detailLabel.stringValue != text else { return }
        detailLabel.stringValue = text
        setAccessibilityLabel([verbLabel?.stringValue, text].compactMap { $0 }.joined(separator: " "))
        needsLayout = true
    }

    @objc private func tapped() { onTap?() }

    override func layout() {
        super.layout()
        let pad: CGFloat = 8
        let spacing: CGFloat = 7
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dot.frame = CGRect(x: pad, y: (bounds.height - 6) / 2, width: 6, height: 6)
        CATransaction.commit()
        var x = dotted ? pad + 6 + spacing : pad
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
