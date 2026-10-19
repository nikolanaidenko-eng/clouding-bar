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
    }

    var mode: Mode = .normal
    var activity: Activity = .sleep
    var sessionPercent: Double?
    var resetCountdown: String?
    var contextPercent: Double?
    var buttons: [ButtonSpec] = []
    /// Do not disturb: nothing pulses.
    var quiet = false
    /// What shows besides the character: "session", "reset", "context",
    /// "model", "buttons", "mic", "shot" (Settings → Touch Bar).
    var shows: Set<String> = ["session", "reset", "context", "buttons"]
    /// The model button: "Opus 5.5 1M · xhigh".
    var modelLabel: String?
    /// For the picker: the model's alias ("opus[1m]") and the effort.
    var modelAlias: String?
    var effort: String?
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
    case models, pickModel(String), pickEffort(String), closeModels
}

/// The whole Touch Bar as one view, laid out like design/TB-*.dc.html:
///
///   normal      [character] · Session ─── · Context ── · buttons
///   permission  [character] · ● Run `command` · Allow · Always · Deny
///   question    [character] · ● Question? · option · option · Other…
///   typing      [character] · ═ · Other [answer________] · Send · 🎤
///   context     [character] · Session ─── · Context ── (red) · Compact · Later
///   models      [character] · Model  Opus 1M · Opus · … · Effort  low · … · Done
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
        NSSize(width: Self.preferredWidth, height: Palette.height)
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
        switch m.mode {
        case .normal: return "normal|\(buttons)|\(m.modelLabel ?? "")"
        case .models: return "models|\(m.modelAlias ?? "")|\(m.effort ?? "")"
        case .contextWarning: return "context"
        case let .permission(verb, detail): return "permission|\(verb)|\(detail)"
        case let .question(text, options, multi, picked):
            return "question|\(text)|\(options.joined(separator: "\u{1}"))|\(multi)|\(picked.sorted())"
        case .typing: return "typing"
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
            let shows = model.shows
            let session = shows.contains("session"), context = shows.contains("context")
            if session || context {
                let pair = MetersPair(padding: 6, showSession: session, showContext: context)
                meters = pair
                add(pair, .flex(weight: 1, min: 80))
            }
            if shows.contains("model"), let label = model.modelLabel {
                let b = BarButton(label, fontSize: 12) { [weak self] in self?.onAction?(.models) }
                add(b, .shrinkable(min(170, b.fittingWidth(padding: 14))))
            }
            if shows.contains("buttons") {
                for (i, spec) in model.buttons.enumerated() {
                    let b = customButton(spec.label) { [weak self] in self?.onAction?(.button(i)) }
                    add(b.button, .shrinkable(b.width))
                    animate(b.button) { $0.popIn() }
                }
            }
            if shows.contains("shot"), let icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Screenshot") {
                add(BarButton("Screenshot", icon: icon) { [weak self] in self?.onAction?(.screenshot) }, .fixed(48))
            }
            if shows.contains("mic") {
                add(BarButton("Dictate", icon: Self.micImage()) { [weak self] in self?.onAction?(.dictate) }, .fixed(48))
            }
            // No meters: the rest stays at the left, after the character.
            if meters == nil { add(NSView(), .flex(weight: 1, min: 0)) }

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
            let message = MessageView(verb: verb, detail: detail, monospaced: true, quiet: model.quiet)
            add(message, .flex(weight: 1, min: 120))
            animate(message) { $0.slideIn() }
            let allow = BarButton("Allow", style: .primary) { [weak self] in self?.onAction?(.allow) }
            let always = BarButton("Always") { [weak self] in self?.onAction?(.always) }
            let deny = BarButton("Deny", style: .deny) { [weak self] in self?.onAction?(.deny) }
            add(allow, .fixed(100))
            add(always, .fixed(100))
            add(deny, .fixed(75))
            [allow, always, deny].forEach { b in animate(b) { $0.slideIn(delay: 0.06) } }

        case let .question(text, options, multi, picked):
            let message = MessageView(verb: nil, detail: text, monospaced: false, quiet: model.quiet)
            add(message, .flex(weight: 1, min: 120))
            animate(message) { $0.slideIn() }
            var group: [NSView] = []
            for (i, label) in options.enumerated() {
                let b = BarButton(label, style: picked.contains(i) ? .selected : .normal) { [weak self] in
                    self?.onAction?(.option(i))
                }
                add(b, .shrinkable(min(b.fittingWidth(padding: 14), 180)))
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
            let done = BarButton("Done", style: .outline) { [weak self] in self?.onAction?(.closeModels) }
            add(done, .fixed(done.fittingWidth(padding: 14)))
            group.append(done)
            group.forEach { b in animate(b) { $0.slideIn(delay: 0.04) } }

        case .typing:
            let mini = MiniMetersView()
            self.mini = mini
            add(mini, .fixed(60))
            let label = NSTextField(labelWithString: "Other")
            label.font = .systemFont(ofSize: Palette.labelFont)
            label.textColor = Palette.secondary
            label.alignment = .right
            add(label, .fixed(ceil(label.intrinsicContentSize.width) + 4))
            let field = TypingFieldView()
            self.field = field
            add(field, .flex(weight: 1, min: 120))
            animate(field) { $0.slideIn(duration: 0.24) }
            let send = BarButton("Send", style: .primary) { [weak self] in self?.onAction?(.send) }
            let mic = BarButton("Dictate", icon: Self.micImage()) { [weak self] in self?.onAction?(.mic) }
            add(send, .fixed(85))
            add(mic, .fixed(48))
        }
        needsLayout = true
    }

    /// A small grey word before a group of buttons.
    private func sectionLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: Palette.labelFont)
        label.textColor = Palette.secondary
        label.alignment = .right
        return label
    }

    private func add(_ view: NSView, _ width: Slot.Width) {
        addSubview(view)
        slots.append(Slot(view: view, width: width))
    }

    private func animate(_ view: NSView, _ animation: @escaping (CALayer) -> Void) {
        view.wantsLayer = true
        animatedViews.append(view)
        pendingAnimations.append(animation)
    }

    /// A configured button: 13 pt, 15 pt padding, at most 130 pt wide; a
    /// long name drops to 11 pt, then gets "…".
    private func customButton(_ label: String, onTap: @escaping () -> Void) -> (button: BarButton, width: CGFloat) {
        var b = BarButton(label, onTap: onTap)
        var width = b.fittingWidth(padding: 15)
        if width > 130 {
            b = BarButton(label, fontSize: 11, onTap: onTap)
            width = b.fittingWidth(padding: 12)
        }
        return (b, min(130, max(60, width)))
    }

    // MARK: Values

    private func refreshValues() {
        mascot.activity = model.activity
        meters?.set(session: model.sessionPercent,
                    countdown: model.mode == .normal && !model.shows.contains("reset") ? nil : model.resetCountdown,
                    context: model.contextPercent)
        mini?.set(session: model.sessionPercent, context: model.contextPercent)
        if case let .typing(text) = model.mode { field?.set(text: text) }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let available = bounds.width - Palette.edge * 2
        let gaps = Palette.gap * CGFloat(max(0, slots.count - 1))
        var widths: [CGFloat] = slots.map {
            switch $0.width {
            case let .fixed(w), let .shrinkable(w): return w
            case .flex: return 0
            }
        }
        let fixed = widths.reduce(0, +)
        let flexMin = slots.reduce(CGFloat(0)) {
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
        // Not enough room: shrinkable slots give way first.
        let overflow = fixed + gaps + flexMin - available
        if overflow > 0 {
            let shrinkable = slots.indices.filter { if case .shrinkable = slots[$0].width { return true }; return false }
            let total = shrinkable.reduce(CGFloat(0)) { $0 + widths[$1] }
            if total > 0 {
                for i in shrinkable {
                    widths[i] = max(36, widths[i] - overflow * widths[i] / total)
                }
            }
        }
        let remaining = max(0, available - gaps - widths.reduce(0, +))
        let weights = slots.reduce(CGFloat(0)) {
            if case let .flex(w, _) = $1.width { return $0 + w }
            return $0
        }
        for (i, slot) in slots.enumerated() {
            if case let .flex(w, _) = slot.width, weights > 0 {
                widths[i] = remaining * w / weights
            }
        }

        var x = Palette.edge
        for (slot, width) in zip(slots, widths) {
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
