import SwiftUI
import UniformTypeIdentifiers

// The floating widget, drawn to design/Main.dc.html and design/Widget-*.dc.html.
// Sizes are in points; colors and timings come from the mockups.

/// `chats`: the open widget's Chats tab, every chat to write to.
enum WidgetMode { case strip, pill, panel, chats }

final class WidgetState: ObservableObject {
    @Published var mode: WidgetMode = .pill
    /// While an item's right edge is dragged: the widths as they'd be on
    /// letting go (the pill and its window follow at once).
    @Published var itemWidthsLive: [String: Double]?
    /// The item whose edge is held, and its width when the drag began.
    var itemResizing: (id: String, width: CGFloat)?
    /// What it collapses to: the pill, or the thin line.
    var rest: WidgetMode = .pill
    /// Set when collapsing means something else (the drawer slides away).
    var collapse: (() -> Void)?
    /// Cloud already stands on top of the island; no second one in the header.
    var hidesHeaderCharacter = false
    /// Set by WidgetController: the pill hands its mouse over for moving,
    /// resizing and clicks.
    var pillMouseDown: ((NSEvent) -> Void)?
    var pillMouseDragged: ((NSEvent) -> Void)?
    var pillMouseUp: ((NSEvent) -> Void)?
    /// The pointer went over (true) or off a control on the pill.
    var controlHover: ((Bool) -> Void)?
    /// A click on the pill's numbers: open the panel.
    var openPanel: (() -> Void)?
    /// Dragging the pill's items onto each other.
    let pillRearrange = Rearrange(space: "pill")
    /// Writing in the pill's chat: everything else steps aside for the text.
    @Published var pillTyping = false
    @Published var pillDraft = ""
    /// Set by WidgetController: the window takes the keyboard for the chat
    /// and gives it back.
    var startTyping: (() -> Void)?
    var endTyping: (() -> Void)?
    /// While the pill's outline is pulled: its size, following the pointer.
    @Published var pillEditSize: CGSize?
    /// The pointer is on the pill: its outline shows faintly.
    @Published var pillHover = false
    /// Files are being dragged over the widget.
    @Published var dropHover = false
    /// Docked in the notch (or dragged over it, about to dock): the pill is
    /// the black island, the panel grows out of it.
    @Published var notched = false
    /// The camera's width (0 on Macs without a notch: one is drawn) and the
    /// notch's height.
    @Published var notchWidth: CGFloat = 0
    @Published var notchHeight: CGFloat = 32
    /// Goes up by one to put the cursor in the panel's message field.
    @Published var focusMessage = 0
    /// The Chats tab: the chat whose composer is open under its row (one at
    /// a time), and a nudge to put the cursor in it.
    @Published var composerChat: String?
    @Published var focusComposer = 0
    /// Set by the controllers: the window takes the keyboard for that
    /// composer (without activating the app, so your editor stays in front).
    var composerKeyboard: (() -> Void)?
    /// How close to an end a press resizes instead of moving.
    static let pillEdge: CGFloat = 14
    /// How close to the top or bottom of the outline.
    static let pillRim: CGFloat = 7

    /// Which sides a press on the pill's outline pulls — always one end and
    /// the top or bottom, so one drag sizes it both ways (free form): `h`
    /// −1 left, 1 right (the nearer end); `v` 1 top (only from the band
    /// along the top), else −1 bottom. Nil: not on the outline. `p` in
    /// window points, y up.
    static func pillRim(_ p: NSPoint, in size: NSSize) -> (h: Int, v: Int)? {
        let onRim = p.x <= pillEdge || p.x >= size.width - pillEdge || p.y <= pillRim || p.y >= size.height - pillRim
        guard onRim else { return nil }
        return (p.x > size.width / 2 ? 1 : -1, p.y >= size.height - pillRim ? 1 : -1)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
    static let cbText = Color(hex: 0xF5F5F7)
    static let cbSecondary = Color(hex: 0xA1A1A6)
    static let cbMuted = Color(hex: 0x8E8E93)
    static let cbAction = Color(hex: 0x0071E3)
    static let cbWarning = Color(hex: 0xFF9F0A)
    static let cbWarningText = Color(hex: 0xFFB340)
    static let cbDeny = Color(hex: 0xFF6961)
    static let cbFill = Color(hex: 0xE5E5EA)
    /// A limit's bar below 70%: the blue of Settings' charts.
    static let cbMeter = Color(hex: 0x64A8FF)
    static let cbHairline = Color.white.opacity(0.14)

    static func meter(_ percent: Double) -> Color {
        percent >= 90 ? Color(hex: 0xFF453A) : percent >= 70 ? .cbWarning : .cbMeter
    }
}

extension Animation {
    /// cubic-bezier(.2,.8,.2,1)
    static func cb(_ duration: Double) -> Animation { .timingCurve(0.2, 0.8, 0.2, 1, duration: duration) }
}

// MARK: - Building blocks

struct MascotIcon: NSViewRepresentable {
    let activity: Activity
    let size: CGFloat
    /// Idle but up, not asleep.
    var awake = false
    /// Goes up by one per poke; each one makes it jump and smile.
    var pokes = 0
    /// Goes up by one per wave (Claude's ☁️): it sways and smiles.
    var waves = 0

    final class Coordinator { var pokes = 0; var waves = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MascotView {
        context.coordinator.pokes = pokes
        context.coordinator.waves = waves
        return MascotView(size: size)
    }
    func updateNSView(_ view: MascotView, context: Context) {
        view.activity = activity
        view.awake = awake
        if pokes != context.coordinator.pokes {
            context.coordinator.pokes = pokes
            view.poke()
        }
        if waves != context.coordinator.waves {
            context.coordinator.waves = waves
            view.wave()
        }
    }
}

/// The open widget's background: glass, or — docked in the notch — black,
/// flush with the top of the screen and clear of the camera, so the panel
/// looks grown out of the notch.
struct PanelMaterial: ViewModifier {
    @Environment(\.cbNotch) private var notch

    @ViewBuilder func body(content: Content) -> some View {
        if let notch {
            content
                .padding(.top, max(0, notch - 4))
                .padding(.horizontal, NotchView.shoulder)
                .background(NotchShape(radius: 22).fill(Color.black))
        } else {
            content.modifier(Glass(radius: 18))
        }
    }
}

/// The widget's material: dark blur, rgba(40,40,42,0.78), 0.5 pt hairline.
struct Glass: ViewModifier {
    let radius: CGFloat
    var border = Color.cbHairline

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    VisualEffect(radius: radius)
                    Color(red: 40 / 255, green: 40 / 255, blue: 42 / 255).opacity(0.78)
                }
                .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            )
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(border, lineWidth: 0.5))
    }
}

/// Blur of what's behind the window, blur 28 + saturate in the mockup.
/// SwiftUI can't clip an AppKit view, so the rounded shape is a mask image
/// (which also gives the window's shadow its shape).
struct VisualEffect: NSViewRepresentable {
    var radius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        v.maskImage = Self.mask(radius)
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}

    static func mask(_ radius: CGFloat) -> NSImage? {
        guard radius > 0 else { return nil }
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// A meter bar that fills from 0 on appear and slides on change (900 ms).
struct MeterBar: View {
    let percent: Double?
    /// The bar's thickness.
    var height: CGFloat = 4
    var track = Color.white.opacity(0.12)
    var color: Color? = nil
    var delay: Double = 0
    /// Upright, filling from the bottom (the column pill).
    var vertical = false
    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.cbStill) private var still

    var body: some View {
        GeometryReader { geo in
            let f = CGFloat(min(max(shown, 0), 100) / 100)
            ZStack(alignment: vertical ? .bottom : .leading) {
                Capsule().fill(track)
                Capsule().fill(color ?? Color.meter(percent ?? 0))
                    .frame(width: vertical ? nil : geo.size.width * f, height: vertical ? geo.size.height * f : nil)
            }
        }
        .frame(width: vertical ? height : nil, height: vertical ? nil : height)
        .onAppear { animate(to: percent ?? 0, delay: delay) }
        .onChange(of: percent ?? 0) { animate(to: $0, delay: 0) }
    }

    private func animate(to value: Double, delay: Double) {
        if reduceMotion || still { shown = value; return }
        withAnimation(.cb(0.9).delay(delay)) { shown = value }
    }
}

/// The orange "waiting for you" dot, pulsing 1.4 s (still in Do not disturb).
struct PulseDot: View {
    var size: CGFloat = 8
    var still = false
    /// Orange: needs you. The subagents' list uses the working colour.
    var color = Color.cbWarning
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle().fill(color)
            .frame(width: size, height: size)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !still && !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
            }
            .accessibilityHidden(true)
    }
}

struct WidgetButtonStyle: ButtonStyle {
    var background = Color.white.opacity(0.08)
    var foreground = Color.cbText
    var weight: Font.Weight = .regular
    var height: CGFloat = 44
    var radius: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: weight))
            .foregroundColor(foreground)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(background.opacity(configuration.isPressed ? 0.6 : 1)))
            .contentShape(Rectangle())
    }
}

struct IconButtonStyle: ButtonStyle {
    var background = Color.clear
    var foreground = Color.cbSecondary
    var size: CGFloat = 44
    /// Wider than tall when its slot was dragged wider.
    var width: CGFloat?
    /// In a frame, like a key on the Touch Bar (owner, 24.10): a rounded
    /// square, filled faintly even when plain, with a hairline round it.
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: max(6, size * 0.26), style: .continuous)
        return configuration.label
            .foregroundColor(foreground)
            .frame(width: max(size, width ?? size), height: size)
            .background(shape.fill((background == .clear ? Color.white.opacity(0.07) : background)
                .opacity(configuration.isPressed ? 0.6 : 1)))
            .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
            .contentShape(shape)
    }
}

/// SVG icons from the mockups.
struct Icon: View {
    enum Kind { case chevronUp, chevronRight, chevronLeft, mic, clock, send }
    let kind: Kind
    var size: CGFloat = 16
    var lineWidth: CGFloat = 2

    var body: some View {
        Canvas { ctx, sz in
            let s = sz.width / 24
            var p = Path()
            switch kind {
            case .chevronUp: p.move(to: .init(x: 6 * s, y: 15 * s)); p.addLine(to: .init(x: 12 * s, y: 9 * s)); p.addLine(to: .init(x: 18 * s, y: 15 * s))
            case .chevronRight: p.move(to: .init(x: 9 * s, y: 6 * s)); p.addLine(to: .init(x: 15 * s, y: 12 * s)); p.addLine(to: .init(x: 9 * s, y: 18 * s))
            case .chevronLeft: p.move(to: .init(x: 15 * s, y: 6 * s)); p.addLine(to: .init(x: 9 * s, y: 12 * s)); p.addLine(to: .init(x: 15 * s, y: 18 * s))
            case .mic:
                p.addRoundedRect(in: CGRect(x: 9 * s, y: 3 * s, width: 6 * s, height: 11 * s), cornerSize: CGSize(width: 3 * s, height: 3 * s))
                p.move(to: .init(x: 5 * s, y: 11 * s))
                p.addCurve(to: .init(x: 19 * s, y: 11 * s), control1: .init(x: 5 * s, y: 20.3 * s), control2: .init(x: 19 * s, y: 20.3 * s))
                p.move(to: .init(x: 12 * s, y: 18 * s)); p.addLine(to: .init(x: 12 * s, y: 21 * s))
            case .clock:
                p.addEllipse(in: CGRect(x: 3 * s, y: 3 * s, width: 18 * s, height: 18 * s))
                p.move(to: .init(x: 12 * s, y: 7 * s)); p.addLine(to: .init(x: 12 * s, y: 12 * s)); p.addLine(to: .init(x: 15 * s, y: 14 * s))
            case .send:
                p.move(to: .init(x: 12 * s, y: 19 * s)); p.addLine(to: .init(x: 12 * s, y: 5 * s))
                p.move(to: .init(x: 6 * s, y: 11 * s)); p.addLine(to: .init(x: 12 * s, y: 5 * s)); p.addLine(to: .init(x: 18 * s, y: 11 * s))
            }
            ctx.stroke(p, with: .foreground, style: StrokeStyle(lineWidth: lineWidth * s, lineCap: .round, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Root

struct WidgetView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState
    /// Settings' copy: never Claude's request (its keys — Esc, the numbers,
    /// Return in its field — would answer it from the Settings window).
    @Environment(\.cbPreview) private var preview

    var body: some View {
        Group {
            switch state.mode {
            case .strip: StripView(model: model)
            case .pill:
                if state.notched { NotchView(model: model, state: state) } else { PillView(model: model, state: state) }
            case .panel:
                if model.request != nil && !preview { RequestCardView(model: model, state: state) }
                else { MainPanel(model: model, state: state) }
            case .chats: ChatsPanel(model: model, state: state)
            }
        }
        .fixedSize()
        .overlay(dropTarget)
        // A real notch: the panel starts under the camera. A drawn one: right away.
        .environment(\.cbNotch, state.notched ? (state.notchWidth > 0 ? state.notchHeight : 8) : nil)
        .environment(\.colorScheme, .dark)
    }

    /// Files dragged over the open panel: where they'll go — with a chat's
    /// composer open in the Chats tab, to that chat.
    @ViewBuilder private var dropTarget: some View {
        if state.dropHover && (state.mode == .panel || state.mode == .chats) {
            let composer = state.mode == .chats ? state.composerChat.flatMap { id in model.sessions.first { $0.id == id } } : nil
            RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.6))
                .overlay(VStack(spacing: 6) {
                    Image(systemName: "paperclip").font(.system(size: 20))
                    Text((composer?.name ?? model.project).map { "Attach for \($0)" } ?? "Attach").font(.system(size: 13, weight: .semibold))
                    Text("Sent to its chat with your next message").font(.system(size: 11)).foregroundColor(.cbSecondary)
                }
                .foregroundColor(.cbText))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.cbAction, style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

/// The floating widget's window content: the widget at the top center.
/// The window may be roomier for a moment while one view turns into
/// another; the widget stays put at the top.
struct WidgetWindow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState

    var body: some View {
        WidgetView(model: model, state: state)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

extension Animation {
    /// Between the panel and the chats: a soft spring, like a sheet.
    static let cbSwap = Animation.spring(response: 0.42, dampingFraction: 0.88)
}

/// At rest: a 4 pt line in the state's color, under the menu bar.
struct StripView: View {
    @ObservedObject var model: AppModel
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var waiting: Bool { model.request != nil || model.activity == .wait }

    var body: some View {
        let color: Color = waiting ? .cbWarning
            : model.listening ? .cbAction
            : !model.hasSession ? Color.cbMuted.opacity(0.5)
            : model.activity == .work ? .cbFill : Color.cbMuted
        VStack(spacing: 0) {
            Capsule().fill(color).frame(width: 64, height: 4)
                .opacity(dim ? 0.35 : 1)
            Spacer(minLength: 0)
        }
        // Barely bigger than the line itself, so it isn't in the way.
        .frame(width: 72, height: 6)
        .contentShape(Rectangle())
        .onAppear(perform: pulseIfNeeded)
        .onChange(of: waiting) { _ in pulseIfNeeded() }
        .accessibilityElement()
        .accessibilityLabel("Clouding Bar: \(model.statusTitle)")
    }

    private func pulseIfNeeded() {
        guard waiting && !model.config.doNotDisturb && !reduceMotion else {
            withAnimation(.default) { dim = false }
            return
        }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true }
    }
}

// MARK: - Panels

struct PanelChrome<Content: View>: View {
    var padding = EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 14)
    var spacing: CGFloat = 16
    var width: CGFloat = 320
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(padding)
            .frame(width: width)
            .modifier(PanelMaterial())
            .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                                        .combined(with: .offset(y: -6)),
                                    removal: .opacity))
    }
}

struct PanelHeader: View {
    let activity: Activity
    let title: String
    let subtitle: String?
    var waiting = false
    var dnd = false
    var onCollapse: (() -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            MascotIcon(activity: activity, size: 32).frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundColor(.cbText)
                if let subtitle { Text(subtitle).font(.system(size: 12)).foregroundColor(.cbSecondary) }
            }
            Spacer(minLength: 0)
            if waiting { PulseDot(still: dnd) }
            if let onCollapse {
                Button(action: onCollapse) { Icon(kind: .chevronUp) }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Collapse")
            }
        }
    }
}

struct MeterBlock: View {
    let title: String
    let percent: Double?
    let caption: String?
    var delay: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).foregroundColor(.cbSecondary)
                Spacer()
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "—").fontWeight(.semibold).monospacedDigit()
                    .foregroundColor(.cbText)
            }
            .font(.system(size: 12))
            MeterBar(percent: percent, delay: delay)
            if let caption {
                Text(caption).font(.system(size: 11).monospacedDigit()).foregroundColor(.cbSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One metric of the open panel (and the wide pill): model · effort,
/// ±lines, branch, subagents, cost — whichever are on.
struct Metric {
    /// "model", "lines", "git", "agents", "cost".
    let id: String
    let icon: String
    let text: String
    var action: (() -> Void)? = nil
    var help = ""

    /// Its icon's colour, as Settings' section icons.
    var tint: UInt32 {
        switch id {
        case "model": return 0xBF5AF2
        case "lines": return 0x30D158
        case "git": return 0xFF9F0A
        case "agents": return 0x40C8E0
        case "time": return 0x64A8FF
        default: return 0x30D158
        }
    }

    var width: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]).width)
            + 14 + 5 + 16 + 2
    }

    /// On the pill: icon and text, no capsule.
    var plainWidth: CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)]).width)
            + 14 + 4 + 3
    }

    static let ids = ["model", "time", "lines", "git", "agents", "cost"]

    /// The metrics that are on and known, in the owner's order.
    static func list(_ model: AppModel) -> [Metric] {
        let on = Set(model.config.metrics)
        var items: [Metric] = []
        // Switched on, it shows: "—" until it's known (owner, 25.10).
        if on.contains("model") {
            let name = model.modelName
            items.append(Metric(id: "model", icon: "cpu", text: name.map { $0 + (model.effort.map { " · \($0)" } ?? "") } ?? "—",
                                // Codex switches models its own way: no Claude picker there.
                                action: model.agentName != nil || name == nil ? nil : { [weak model] in
                                    withAnimation(.cb(0.24)) { model?.pickingModel.toggle(); model?.showingAgents = false }
                                },
                                help: "Switch the model or effort"))
        }
        // How long it's been at it — once under the chat's name (owner, 24.10).
        if on.contains("time") {
            items.append(Metric(id: "time", icon: "clock", text: model.chatTime ?? "—", help: "How long the chat has been working, or idle"))
        }
        if on.contains("lines") {
            items.append(Metric(id: "lines", icon: "plus.forwardslash.minus", text: "+\(model.linesAdded) −\(model.linesRemoved)"))
        }
        if on.contains("git") {
            items.append(Metric(id: "git", icon: "arrow.triangle.branch", text: model.branch ?? "—"))
        }
        if on.contains("agents") {
            items.append(Metric(id: "agents", icon: "person.2", text: "\(model.agents) subagent\(model.agents == 1 ? "" : "s")",
                                action: { [weak model] in
                                    withAnimation(.cb(0.24)) { model?.showingAgents.toggle(); model?.pickingModel = false }
                                },
                                help: "Which subagents are working"))
        }
        if on.contains("cost") {
            items.append(Metric(id: "cost", icon: "dollarsign.circle", text: PillLayout.cost(model.cost)))
        }
        return items.sorted { model.rank("metric:" + $0.id) < model.rank("metric:" + $1.id) }
    }
}

/// A metric as a small labelled chip, so several never run together. On
/// the pill (`plain`) just the icon and the text: the pill is busy enough.
struct MetricChip: View {
    let metric: Metric
    var plain = false
    @Environment(\.clickGate) private var gate

    var body: some View {
        let label = HStack(spacing: plain ? 4 : 5) {
            Image(systemName: metric.icon).font(.system(size: 10, weight: .semibold)).frame(width: 14)
                .foregroundColor(Color(hex: metric.tint))
            Text(metric.text).lineLimit(1).fixedSize()
        }
        .font(.system(size: plain ? 12 : 11).monospacedDigit())
        .foregroundColor(.cbSecondary)
        .padding(.horizontal, plain ? 0 : 8)
        .frame(height: 22)
        .background(Capsule().fill(Color.white.opacity(plain ? 0 : 0.06)))
        if let action = metric.action {
            Button { if gate() { action() } } label: { label }.buttonStyle(.plain).help(metric.help)
        } else {
            label.contentShape(Capsule())
        }
    }
}

/// The open widget (owner's requests, 15.10–20.10): the chats as tabs —
/// the one it shows lit in its colour — then the two limits as tidy lines,
/// one quiet line of details, and the message box saying which chat it
/// writes to, with the buttons and the tools in it.
struct MainPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState
    @Environment(\.cbPreview) private var preview
    @State private var queueDraft = ""
    @FocusState private var typing: Bool
    @StateObject private var metricsRearrange = Rearrange(space: "panel-metrics")
    @StateObject private var buttonsRearrange = Rearrange(space: "panel-buttons")
    /// A block being dragged up or down by its grip, and how far.
    @State private var moving: String?
    @State private var movedBy: CGFloat = 0
    @State private var blockFrames: [String: CGRect] = [:]
    /// Where the blocks stood when the drag began, and the one it's over.
    @State private var startFrames: [String: CGRect] = [:]
    @State private var dropOn: String?
    /// A block's grip shows only while the pointer is on it or its grip.
    @State private var hoverBlock: String?
    @State private var hoverGrip: String?

    private static let chrome: CGFloat = 12 + 12
    /// The text field never gets narrower than this.
    private static let fieldMin: CGFloat = 170
    /// Inside the message box.
    private static let boxPad: CGFloat = 8
    private static let tool: CGFloat = 24

    /// Wide enough for the details line and the buttons in a row, 440 to
    /// 600 pt; past that they wrap instead of crowding.
    private var panelWidth: CGFloat {
        let metrics = metricWidths
        let detailsRow = metrics.reduce(0, +) + 14 * CGFloat(max(0, metrics.count - 1)) + Self.chrome
        let buttons = buttonWidths
        let field = model.config.taskQueue
        // With the field the buttons have a line of their own, under it.
        let buttonsRow = buttons.reduce(0, +) + 6 * CGFloat(max(0, buttons.count - 1)) + (field ? 0 : toolsWidth)
            + Self.chrome + Self.boxPad * 2
        let fieldRow = field ? Self.fieldMin + toolsWidth + Self.chrome + Self.boxPad * 2 : 0
        return min(600, max(440, detailsRow, buttonsRow, fieldRow))
    }

    private var showTemplates: Bool { !model.config.widgetHides.contains("menu") }

    /// Templates · screenshot · mic, at the end of the message box.
    private var tools: [String] {
        (showTemplates ? ["templates"] : []) + (model.config.screenshot ? ["shot"] : [])
            + (model.config.widgetHides.contains("mic") ? [] : ["mic"])
    }
    /// The tools and Send at the end of the first line, with their gaps.
    private var toolsWidth: CGFloat {
        let n = CGFloat(tools.count + (model.config.taskQueue ? 1 : 0))
        return n == 0 ? 0 : n * Self.tool + 6 * (n - 1) + 6
    }

    private func metrics(_ order: [String]) -> [(id: String, width: CGFloat)] {
        Metric.list(model).map { (id: "metric:" + $0.id, width: $0.plainWidth) }
            .sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }
    private var metricWidths: [CGFloat] { metrics(model.itemIDs).map(\.width) }
    /// The buttons (index into model.buttons), in `order`.
    private func buttons(_ order: [String]) -> [(id: String, width: CGFloat, index: Int)] {
        model.buttons.indices.map { (id: "button:" + model.buttons[$0].label,
                                     width: max(56, Self.textWidth(model.buttons[$0].label, 12) + 24), index: $0) }
            .sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }
    private var buttonWidths: [CGFloat] { buttons(model.itemIDs).map(\.width) }

    /// The message box's row: the buttons, the tools and Send, in `order`.
    private func boxItems(_ order: [String], field: Bool) -> [(id: String, width: CGFloat)] {
        let all = buttons(order).map { (id: $0.id, width: $0.width) }
            + tools.map { (id: $0, width: Self.tool) } + (field ? [(id: "send", width: Self.tool)] : [])
        return all.enumerated().sorted {
            (order.firstIndex(of: $0.element.id) ?? order.count + $0.offset) < (order.firstIndex(of: $1.element.id) ?? order.count + $1.offset)
        }.map(\.element)
    }

    static func textWidth(_ text: String, _ size: CGFloat, weight: NSFont.Weight = .regular) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight)]).width)
    }

    /// Greedy line breaking: indices of items per row within `width`.
    static func rows(_ widths: [CGFloat], within width: CGFloat, gap: CGFloat) -> [[Int]] {
        var rows: [[Int]] = [[]]
        var used: CGFloat = 0
        for (i, w) in widths.enumerated() {
            if !rows[rows.count - 1].isEmpty && used + gap + w > width {
                rows.append([])
                used = 0
            }
            used += (rows[rows.count - 1].isEmpty ? 0 : gap) + w
            rows[rows.count - 1].append(i)
        }
        return rows
    }

    var body: some View {
        let width = panelWidth
        let inner = width - Self.chrome
        PanelChrome(padding: EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12), spacing: 12, width: width) {
            header(inner: inner)
            ForEach(blockOrder, id: \.self) { id in block(id, inner: inner) }
        }
        .coordinateSpace(name: "panel-blocks")
        .onPreferenceChange(BlockFrames.self) { blockFrames = $0 }
        .animation(.cb(0.28), value: width)
        .animation(.cb(0.28), value: blockOrder)
        // Files just dropped: the cursor waits in the field for a message.
        .onChange(of: state.focusMessage) { _ in if model.config.taskQueue { typing = true } }
    }

    // MARK: Blocks

    /// The blocks under the chats, top to bottom: the limits, the details,
    /// the message box — in the owner's order, dragged by their grips.
    private var blockOrder: [String] {
        let all = ["meters", "details", "box"]
        let order = model.config.panelOrder
        return all.enumerated().sorted {
            (order.firstIndex(of: $0.element) ?? order.count + $0.offset) < (order.firstIndex(of: $1.element) ?? order.count + $1.offset)
        }.map(\.element)
    }

    @ViewBuilder private func block(_ id: String, inner: CGFloat) -> some View {
        switch id {
        case "meters":
            if !model.config.widgetHides.contains("session") || model.config.pillShows.contains("context") {
                movable(id) { meters }
            }
        case "details":
            if !metrics(model.itemIDs).isEmpty || model.pickingModel || model.showingAgents {
                movable(id) {
                    VStack(alignment: .leading, spacing: 12) {
                        if !metrics(model.itemIDs).isEmpty { details(inner: inner) }
                        if model.pickingModel { ModelPicker(model: model) }
                        if model.showingAgents { AgentsList(model: model) }
                    }
                }
            }
        default:
            if model.config.taskQueue || !model.buttons.isEmpty || !model.attachments.isEmpty || !tools.isEmpty {
                movable(id) { messageBox(inner: inner) }
            }
        }
    }

    /// A block with a grip over its top edge, shown while the pointer is on
    /// it: drag it up or down onto another block to put it there (owner,
    /// 24.10). The grip sits in the gap between blocks, never past the
    /// panel's edge (owner, 25.10).
    private func movable<C: View>(_ id: String, @ViewBuilder _ content: () -> C) -> some View {
        let shown = moving == id || (moving == nil && (hoverBlock == id || hoverGrip == id))
        return content()
            .background(GeometryReader { g in
                Color.clear.preference(key: BlockFrames.self, value: [id: g.frame(in: .named("panel-blocks"))])
            })
            .onHover { inside in
                if inside { hoverBlock = id } else if hoverBlock == id { hoverBlock = nil }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(dropOn == id ? 0.35 : 0), lineWidth: 1.5)
                    .padding(-3)
                    .allowsHitTesting(false)
            )
            .overlay(alignment: .top) {
                Capsule()
                    .fill(Color.white.opacity(moving == id ? 0.55 : shown ? 0.3 : 0))
                    .frame(width: 28, height: 4)
                    .frame(width: 64, height: 12)
                    .contentShape(Rectangle())
                    .offset(y: -12)
                    .onHover { inside in
                        if inside {
                            hoverGrip = id
                            NSCursor.openHand.push()
                        } else {
                            if hoverGrip == id { hoverGrip = nil }
                            NSCursor.pop()
                        }
                    }
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("panel-blocks"))
                        .onChanged { v in drag(id, by: v.translation.height) }
                        .onEnded { v in drop(id, by: v.translation.height) })
                    .help("Drag up or down to move this block")
                    .accessibilityLabel("Move this block")
                    .animation(.cb(0.18), value: shown)
            }
            .offset(y: moving == id ? movedBy : 0)
            .shadow(color: .black.opacity(moving == id ? 0.4 : 0), radius: moving == id ? 10 : 0, y: moving == id ? 5 : 0)
            .zIndex(moving == id ? 1 : 0)
    }

    /// The block under the dragged one's middle, from where the blocks stood
    /// when the drag began: the dragged block's own frame moves with it.
    private func target(_ id: String, by dy: CGFloat) -> String? {
        guard let from = startFrames[id] else { return nil }
        let y = from.midY + dy
        return startFrames.first { $0.key != id && $0.value.minY - 6 <= y && y <= $0.value.maxY + 6 }?.key
    }

    private func drag(_ id: String, by dy: CGFloat) {
        if moving != id {
            startFrames = blockFrames
            moving = id
        }
        movedBy = dy
        let over = target(id, by: dy)
        if over != dropOn { withAnimation(.cb(0.18)) { dropOn = over } }
    }

    /// Let go over another block: the dragged one takes its place, the ones
    /// between shift over.
    private func drop(_ id: String, by dy: CGFloat) {
        let over = target(id, by: dy)
        withAnimation(.cb(0.28)) {
            moving = nil
            movedBy = 0
            dropOn = nil
        }
        startFrames = [:]
        var order = blockOrder
        guard let over, let i = order.firstIndex(of: id), let j = order.firstIndex(of: over) else { return }
        order.remove(at: i)
        order.insert(id, at: j)
        model.setConfig("panelOrder", order)
    }

    private struct BlockFrames: PreferenceKey {
        static var defaultValue: [String: CGRect] = [:]
        static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
            value.merge(nextValue(), uniquingKeysWith: { $1 })
        }
    }

    // MARK: Header

    /// The Panel and Chats tabs, then which chat this is: with several, all
    /// of them as tabs; with one, its name. Under it where it runs and what
    /// it's doing.
    private func header(inner: CGFloat) -> some View {
        let several = model.sessions.count > 1
        let character: CGFloat = state.hidesHeaderCharacter ? 0 : 28 + 10
        let tabs: CGFloat = model.hasSession ? PanelTabs.width + 10 : 0
        // One line (a chat's name): centred on Cloud and the button.
        return HStack(alignment: several || !model.hasSession ? .top : .center, spacing: 10) {
            if !state.hidesHeaderCharacter {
                MascotIcon(activity: model.activity, size: 28, waves: model.cloudWaves).frame(width: 28, height: 28)
            }
            if model.hasSession { PanelTabs(state: state) }
            VStack(alignment: .leading, spacing: several ? 6 : 1) {
                if several {
                    ChatTabs(model: model, state: state, width: inner - character - tabs - 30 - 8)
                } else {
                    // Where it runs and what it's doing: on hover (owner, 26.10).
                    Text(model.hasSession ? model.chatName ?? model.statusTitle : "No chat open")
                        .font(.system(size: 13, weight: .semibold)).foregroundColor(.cbText).lineLimit(1)
                        .help(model.hasSession ? [model.chatPlace, model.chatStatus].compactMap { $0 }.joined(separator: " · ") : "")
                }
                // Where it runs and what it's doing: on hover, not a line of
                // its own (owner, 26.10). With no chat, how to start one.
                if !model.hasSession {
                    Text(model.pluginActive ? "Start Claude Code, or type /reload-plugins in a chat that's open"
                         // A chat open since before the plugin came doesn't run its hooks.
                         : "Start Claude Code in VS Code or Terminal")
                        .font(.system(size: 11)).foregroundColor(.cbSecondary)
                        .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            Button {
                if let collapse = state.collapse { collapse() } else { withAnimation(.cb(0.22)) { state.mode = state.rest } }
            } label: { Icon(kind: .chevronUp, size: 14) }
                .buttonStyle(IconButtonStyle(size: 30))
                .accessibilityLabel("Collapse")
        }
        .disabled(preview) // Settings' copy: the chats aren't opened from it, not even by keyboard
    }

    // MARK: Limits

    /// The 5-hour limit and the context, one tidy line each.
    @ViewBuilder private var meters: some View {
        let showsSession = !model.config.widgetHides.contains("session")
        let showsContext = model.config.pillShows.contains("context")
        if showsSession || showsContext {
            VStack(spacing: 8) {
                if showsSession {
                    MeterLine(title: model.agentName.map { "\($0) 5h" } ?? "5-hour", percent: model.sessionPercent,
                              caption: model.config.pillShows.contains("reset") ? model.resetLong.map { "resets in \($0)" } : nil)
                }
                if showsContext {
                    MeterLine(title: "Context", percent: model.contextPercent, caption: contextCaption, delay: 0.12)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.22)))
        }
    }

    /// "327k of 1M": how much of this chat's window is used.
    private var contextCaption: String? {
        guard let t = model.contextTokens, let w = model.contextWindow else { return nil }
        return "\(AppModel.short(t)) of \(AppModel.short(w))"
    }

    // MARK: Details

    /// The model, ±lines, branch, subagents, cost: one quiet line, in the
    /// owner's order (drag one onto another to swap them).
    private func details(inner: CGFloat) -> some View {
        let all = Metric.list(model)
        let items = metrics(metricsRearrange.order(model.itemIDs))
        let board = flowSlots(items, width: inner, rowHeight: 22, gap: 14, rowGap: 4)
        return RearrangeBoard(ids: items.map(\.id), slots: board.slots, size: board.size, rearrange: metricsRearrange,
                              commit: { model.swapItems($0, $1) }) { id in
            if let m = all.first(where: { "metric:" + $0.id == id }) { MetricChip(metric: m, plain: true) }
        }
        .padding(.horizontal, 4)
    }

    // MARK: Message box

    /// The text field — saying which chat it writes to — with the tools and
    /// Send at the end of its line, the buttons under it (owner, 25.10: not
    /// the mic and Send left alone on a line of their own). While you type,
    /// the buttons step back and can't be clicked by accident. Drag a button
    /// onto another, or a tool onto a tool, to swap them.
    private func messageBox(inner: CGFloat) -> some View {
        let boxInner = inner - Self.boxPad * 2
        let field = model.config.taskQueue
        let items = boxItems(buttonsRearrange.order(model.itemIDs), field: field)
        let index = Dictionary(buttons(model.itemIDs).map { ($0.id, $0.index) }, uniquingKeysWith: { a, _ in a })
        buttonsRearrange.accepts = { a, b in (index[a] == nil) == (index[b] == nil) }
        let tools = items.filter { index[$0.id] == nil }
        let row = items.filter { index[$0.id] != nil }
        let toolsWidth = tools.map(\.width).reduce(0, +) + 6 * CGFloat(max(0, tools.count - 1))
        let toolsAt = boxInner - toolsWidth
        var slots: [String: CGRect] = [:]
        var x = toolsAt
        for t in tools {
            slots[t.id] = CGRect(x: x, y: 0, width: t.width, height: 26)
            x += t.width + 6
        }
        // No field: as many buttons as fit go before the tools.
        let room = toolsAt - (tools.isEmpty ? 0 : 6)
        var firstCount = 0
        var used: CGFloat = 0
        if !field {
            for b in row {
                let add = (firstCount == 0 ? 0 : 6) + b.width
                guard used + add <= room else { break }
                used += add
                firstCount += 1
            }
        }
        x = 0
        for b in row.prefix(firstCount) {
            slots[b.id] = CGRect(x: x, y: 0, width: b.width, height: 26)
            x += b.width + 6
        }
        let fieldWidth = field ? room : 0
        let rest = flowSlots(row.dropFirst(firstCount).map { (id: $0.id, width: $0.width) },
                             width: boxInner, rowHeight: 26, gap: 6, rowGap: 6)
        for (id, r) in rest.slots { slots[id] = r.offsetBy(dx: 0, dy: 32) }
        let height = row.count > firstCount ? 32 + rest.size.height : 26
        let busy = typing || !queueDraft.isEmpty
        let sendable = !queueDraft.isEmpty || !model.attachments.isEmpty
        return VStack(alignment: .leading, spacing: 8) {
            if field && !model.queue.isEmpty { queueList.disabled(preview) }
            if !model.attachments.isEmpty { attachmentRows(width: boxInner, field: field).disabled(preview) }
            ZStack(alignment: .topLeading) {
                if field {
                    TextField(placeholder, text: $queueDraft)
                        .textFieldStyle(.plain).font(.system(size: 12))
                        .padding(.horizontal, 4)
                        .frame(width: max(0, fieldWidth), height: 26)
                        .focused($typing)
                        .onSubmit(addToQueue)
                        .onExitCommand { typing = false }
                        // Settings' copy: not even Tab reaches it, nothing is sent from it. No chat: nowhere to send.
                        .disabled(preview || !model.hasSession)
                }
                RearrangeBoard(ids: items.map(\.id), slots: slots, size: CGSize(width: boxInner, height: height),
                               rearrange: buttonsRearrange, commit: { model.swapItems($0, $1) }) { id in
                    switch id {
                    case "templates": TemplatesButton(model: model, size: Self.tool)
                    case "shot": ShotButton(model: model, size: Self.tool)
                    case "mic": MicButton(model: model, size: Self.tool)
                    case "send":
                        Button { if buttonsRearrange.clickAllowed { addToQueue() } } label: { Icon(kind: .send, size: 13, lineWidth: 2.4) }
                            .buttonStyle(IconButtonStyle(background: sendable ? .cbAction : Color.white.opacity(0.1),
                                                         foreground: .white, size: Self.tool))
                            .accessibilityLabel(model.activity == .work ? "Queue" : "Send")
                    default:
                        if let i = index[id] {
                            Button(model.buttons[i].label) { if buttonsRearrange.clickAllowed { model.perform(.button(i)) } }
                                .buttonStyle(ComposerButtonStyle())
                                .disabled(busy)
                                .opacity(busy ? 0.35 : 1)
                                .animation(.easeOut(duration: 0.15), value: busy)
                        }
                    }
                }
            }
            .frame(width: boxInner, height: height, alignment: .topLeading)
        }
        .padding(Self.boxPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.white.opacity(typing ? 0.28 : 0.12),
                          lineWidth: typing ? 1 : 0.5))
    }

    /// Says where the words go: "Write to “Status bar”".
    private var placeholder: String {
        if !model.hasSession { return "No chat to write to" }
        if !model.attachments.isEmpty { return "Add a message, or just send" }
        let name = model.chatName.map { "“" + ($0.count > 20 ? String($0.prefix(19)) + "…" : $0) + "”" } ?? "Claude"
        return model.activity == .work ? "Queue for \(name)" : "Write to \(name)"
    }

    /// Requests that go out one by one after each reply.
    private var queueList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(model.queue.prefix(4).enumerated()), id: \.element.id) { i, item in
                HStack(spacing: 6) {
                    Text("\(i + 1).").foregroundColor(.cbSecondary)
                    Text(item.text).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { model.sendQueuedNow(item.id) } label: {
                        Label("Send now", systemImage: "paperplane.fill").labelStyle(.titleAndIcon).font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain).foregroundColor(.cbMeter)
                    .help("Opens its chat and sends it now")
                    Button { model.removeFromQueue(item.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                        .buttonStyle(.plain).foregroundColor(.cbSecondary)
                        .accessibilityLabel("Remove from queue")
                }
                .font(.system(size: 12))
            }
            if model.queue.count > 4 {
                Text("+\(model.queue.count - 4) more").font(.system(size: 11)).foregroundColor(.cbSecondary)
            }
            Text("Goes out when Claude is free and its chat is in front")
                .font(.system(size: 10)).foregroundColor(.cbSecondary)
        }
        .padding(.horizontal, 4)
    }

    /// The dropped files as small chips (× takes one off). With no message
    /// field, Insert after them types them into the chat right away; with
    /// one, Send takes them along.
    private func attachmentRows(width: CGFloat, field: Bool) -> some View {
        let chips = model.attachments.map { (id: $0, width: AttachmentChip.width($0)) }
        let insertID = "\u{1}insert"
        let insertWidth = max(56, Self.textWidth("Insert", 12) + 28)
        let board = flowSlots(chips + (field ? [] : [(id: insertID, width: insertWidth)]), width: width,
                              rowHeight: 24, gap: 6, rowGap: 6)
        let insert = board.slots[insertID] ?? .zero
        return ZStack(alignment: .topLeading) {
            ForEach(model.attachments, id: \.self) { path in
                let slot = board.slots[path] ?? .zero
                AttachmentChip(path: path) { model.removeAttachment(path) }
                    .frame(width: slot.width, height: 24)
                    .offset(x: slot.minX, y: slot.minY)
                    .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            if !field {
                Button("Insert") { model.insertAttachments() }
                    .buttonStyle(ComposerButtonStyle(height: 24))
                    .disabled(!model.chatInFront)
                    .opacity(model.chatInFront ? 1 : 0.4)
                    .help(model.chatInFront ? "Type the paths into the chat now, without Enter"
                          : "Open \(model.chatName ?? "its") chat to insert them")
                    .frame(width: insert.width, height: 24)
                    .offset(x: insert.minX, y: insert.minY)
            }
        }
        .frame(width: width, height: board.size.height, alignment: .topLeading)
        .animation(.cb(0.22), value: model.attachments)
    }

    private func addToQueue() {
        // No chat (it went away while you wrote): the words stay.
        guard model.hasSession else { NSSound.beep(); return }
        let text = queueDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !model.attachments.isEmpty else { return }
        model.addToQueue(text)
        queueDraft = ""
        typing = false
    }
}

/// One limit as a line: what it is, its bar, the number, a note.
struct MeterLine: View {
    let title: String
    let percent: Double?
    let caption: String?
    var delay: Double = 0

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundColor(.cbSecondary)
                .frame(width: 58, alignment: .leading)
            MeterBar(percent: percent, height: 5, delay: delay)
            Text(PillLayout.percent(percent)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundColor(.cbText)
                .frame(width: 38, alignment: .trailing)
            Text(caption ?? "").font(.system(size: 11).monospacedDigit()).foregroundColor(.cbSecondary)
                .lineLimit(1)
                .frame(width: 128, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A chat's colour.
struct ChatDot: View {
    let color: UInt32
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(Color(hex: color)).frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// The chat something belongs to: its dot and name, and a tag when it
/// isn't the chat the widget shows.
struct ChatTag: View {
    let name: String
    let color: UInt32
    var elsewhere = false
    var maxWidth: CGFloat = 180

    var body: some View {
        HStack(spacing: 5) {
            ChatDot(color: color)
            // Gives way when the line is short of room, never pushes past it.
            Text(name).font(.system(size: 12)).foregroundColor(.cbText).lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: maxWidth, alignment: .leading)
            if elsewhere {
                Text("other chat").font(.system(size: 10, weight: .semibold)).foregroundColor(.cbWarningText)
                    .fixedSize()
                    .padding(.horizontal, 6).frame(height: 16)
                    .background(Capsule().fill(Color.cbWarning.opacity(0.16)))
            }
        }
        .layoutPriority(1)
        .help(elsewhere ? "From \(name), not the chat the widget shows" : name)
    }
}

/// A name too long for its room goes round like a carousel: the name, a
/// gap, the name again, sliding slowly left without a stop.
struct MarqueeText: View {
    let text: String
    let size: CGFloat
    var weight: NSFont.Weight = .regular
    let maxWidth: CGFloat
    @State private var shift: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let gap: CGFloat = 28

    var body: some View {
        let width = ceil(MainPanel.textWidth(text, size, weight: weight)) + 1
        let font = Font.system(size: size, weight: weight == .semibold ? .semibold : weight == .bold ? .bold : .regular)
        if width <= maxWidth || reduceMotion {
            Text(text).font(font)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
        } else {
            HStack(spacing: Self.gap) {
                Text(text).font(font).lineLimit(1).fixedSize()
                Text(text).font(font).lineLimit(1).fixedSize()
            }
            .offset(x: shift)
            .frame(width: maxWidth, alignment: .leading)
            .clipped()
            .id(text)
            .onAppear {
                shift = 0
                withAnimation(.linear(duration: Double(width + Self.gap) / 22).repeatForever(autoreverses: false)) {
                    shift = -(width + Self.gap)
                }
            }
        }
    }
}

/// Every live chat as a tab (owner's request, 20.10): the one the widget
/// follows lit in its colour, the light gliding over when you pick another
/// (which brings that chat up). The ones that don't fit wait behind "+n".
struct ChatTabs: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState
    let width: CGFloat
    @Namespace private var lit

    static let nameMax: CGFloat = 140

    static func tabWidth(_ r: AppModel.SessionRow) -> CGFloat {
        let weight: NSFont.Weight = r.current ? .semibold : .regular
        let name: CGFloat = min(nameMax, MainPanel.textWidth(r.name, 12, weight: weight) + 1)
        let pulse: CGFloat = r.waiting ? 13 : 0
        return 23 + name + pulse + 10
    }

    /// As many as fit, the current one and the waiting ones first to stay.
    private var visible: (shown: [AppModel.SessionRow], hidden: Int) {
        let all = model.sessions
        let keep = all.filter { $0.current || $0.waiting }
        var shown: [AppModel.SessionRow] = []
        var used: CGFloat = 0
        let moreWidth: CGFloat = 36
        for r in keep + all.filter({ !$0.current && !$0.waiting }) {
            let w = Self.tabWidth(r) + (shown.isEmpty ? 0 : 6)
            let left = all.count - shown.count - 1
            guard used + w + (left > 0 ? 6 + moreWidth : 0) <= width || shown.isEmpty else { continue }
            shown.append(r)
            used += w
        }
        // Back in their steady order.
        let ids = all.map(\.id)
        return (shown.sorted { (ids.firstIndex(of: $0.id) ?? 0) < (ids.firstIndex(of: $1.id) ?? 0) }, all.count - shown.count)
    }

    var body: some View {
        let v = visible
        HStack(spacing: 6) {
            ForEach(v.shown) { r in tab(r) }
            if v.hidden > 0 {
                Button { withAnimation(.cbSwap) { state.mode = .chats } } label: {
                    Text("+\(v.hidden)").font(.system(size: 12)).foregroundColor(.cbSecondary)
                        .frame(width: 36, height: 26)
                        .background(Capsule().fill(Color.white.opacity(0.06)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("All chats")
            }
        }
        .animation(.spring(response: 0.36, dampingFraction: 0.78), value: model.sessions.first(where: \.current)?.id)
    }

    private func tab(_ r: AppModel.SessionRow) -> some View {
        Button { if !r.current { model.focusSession(r.id) } } label: {
            HStack(spacing: 6) {
                ChatDot(color: r.color)
                MarqueeText(text: r.name, size: 12, weight: r.current ? .semibold : .regular, maxWidth: Self.nameMax)
                if r.waiting { PulseDot(size: 7, still: model.config.doNotDisturb) }
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .foregroundColor(r.current ? .cbText : .cbSecondary)
            .background {
                if r.current {
                    // A lighter pill, no coloured ring (owner, 24.10: the neon
                    // outline cheapened the panel); the dot keeps the chat's colour.
                    Capsule().fill(Color.white.opacity(0.16))
                        .matchedGeometryEffect(id: "lit", in: lit)
                } else {
                    Capsule().fill(Color.white.opacity(0.06))
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help([r.place, r.status, r.context.map { "context \(Int($0.rounded()))%" }].compactMap { $0 }.joined(separator: " · "))
        .accessibilityLabel(r.name + (r.current ? ", shown" : ""))
    }
}

/// Model and effort, picked right in the panel (owner's request, 19.10): a
/// tap types /model or /effort into Claude's chat, like a button. The pick
/// lights up at once; the panel's model line follows when Claude confirms.
struct ModelPicker: View {
    @ObservedObject var model: AppModel
    @State private var pendingModel: String?
    @State private var pendingEffort: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Model", ModelChoice.models.map { (id: $0.alias, label: $0.label) },
                selected: pendingModel ?? ModelChoice.alias(of: model.modelId)) { alias in
                pendingModel = alias
                model.setModel(alias)
                forget { pendingModel = nil }
            }
            row("Effort", ModelChoice.efforts.map { (id: $0, label: $0) }, selected: pendingEffort ?? model.effort) { level in
                pendingEffort = level
                model.setEffort(level)
                forget { pendingEffort = nil }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .onChange(of: model.modelId) { _ in pendingModel = nil }
        .onChange(of: model.effort) { _ in pendingEffort = nil }
        .transition(.opacity.combined(with: .offset(y: -4)))
    }

    /// If Claude never confirms (the chat wasn't in front), show what's real again.
    private func forget(_ clear: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: clear)
    }

    private func row(_ title: String, _ options: [(id: String, label: String)], selected: String?,
                     pick: @escaping (String) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11)).foregroundColor(.cbSecondary).frame(width: 38, alignment: .leading)
            HStack(spacing: 0) {
                ForEach(options, id: \.id) { option in
                    let on = selected == option.id
                    Button { if !on { pick(option.id) } } label: {
                        Text(option.label).font(.system(size: 11)).lineLimit(1).fixedSize()
                            .padding(.horizontal, 7)
                            .frame(height: 22)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Color.cbAction : .clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(on ? .white : .cbText)
                    .help(title == "Model" ? "/model \(option.id)" : "/effort \(option.id)")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
            .animation(.easeOut(duration: 0.15), value: selected)
        }
    }
}

/// The subagents at work in this session (owner's request, 19.10): what
/// each was asked, what it's doing right now, and for how long.
struct AgentsList: View {
    @ObservedObject var model: AppModel
    private static let shown = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.agentRows.isEmpty {
                Text("No subagents are working right now")
                    .font(.system(size: 11)).foregroundColor(.cbSecondary)
                    .padding(.vertical, 4)
            }
            ForEach(Array(model.agentRows.prefix(Self.shown).enumerated()), id: \.element.id) { i, agent in
                row(agent)
                    .overlay(i > 0 ? Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5) : nil, alignment: .top)
                    .transition(.opacity.combined(with: .offset(y: -3)))
            }
            if model.agentRows.count > Self.shown {
                Text("+\(model.agentRows.count - Self.shown) more").font(.system(size: 11)).foregroundColor(.cbSecondary)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .animation(.cb(0.22), value: model.agentRows.map(\.id))
        .transition(.opacity.combined(with: .offset(y: -4)))
    }

    private func row(_ agent: AppModel.AgentRow) -> some View {
        HStack(alignment: .center, spacing: 10) {
            PulseDot(size: 6, still: model.config.doNotDisturb, color: .cbFill)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(agent.type).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    if agent.background {
                        Text("background").font(.system(size: 9)).foregroundColor(.cbSecondary)
                            .padding(.horizontal, 5).frame(height: 14)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                }
                Text(agent.task ?? "—").font(.system(size: 11)).foregroundColor(.cbSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(agent.doing ?? "starting…").font(.system(size: 11).monospacedDigit())
                    .foregroundColor(agent.doing == nil ? .cbMuted : .cbText)
                    .lineLimit(1).truncationMode(.middle)
                Text(agent.elapsed).font(.system(size: 10).monospacedDigit()).foregroundColor(.cbSecondary)
            }
            .frame(maxWidth: 200, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

/// A file waiting to go to Claude: its icon and name; × takes it off.
struct AttachmentChip: View {
    let path: String
    let remove: () -> Void

    static let nameMax: CGFloat = 150
    static func width(_ path: String) -> CGFloat {
        8 + 12 + 5 + min(nameMax, MainPanel.textWidth((path as NSString).lastPathComponent, 11)) + 5 + 14 + 4
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: FileDrop.symbol(path)).font(.system(size: 10)).frame(width: 12)
                .foregroundColor(.cbSecondary)
            Text((path as NSString).lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: Self.nameMax, alignment: .leading)
            Button(action: remove) { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                .buttonStyle(.plain).foregroundColor(.cbSecondary)
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
                .accessibilityLabel("Remove \((path as NSString).lastPathComponent)")
        }
        .padding(.leading, 8).padding(.trailing, 4)
        .frame(height: 24, alignment: .leading)
        .background(Capsule().fill(Color.cbAction.opacity(0.22)))
        .overlay(Capsule().strokeBorder(Color.cbAction.opacity(0.45), lineWidth: 0.5))
        .help(path)
    }
}

/// A button inside the message box: a quick reply chip.
struct ComposerButtonStyle: ButtonStyle {
    var height: CGFloat = 26

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundColor(.cbText)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(minWidth: 56, minHeight: height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(configuration.isPressed ? 0.18 : 0.09)))
            .contentShape(Rectangle())
    }
}

/// Tap to dictate: the panel folds into the pill, which shows the words as
/// they come. It stops by itself after a pause, or tap the pill.
struct MicButton: View {
    @ObservedObject var model: AppModel
    var size: CGFloat = 32
    /// Just the icon, no circle (the pill).
    var plain = false
    var width: CGFloat?
    @Environment(\.clickGate) private var gate

    var body: some View {
        Button { if gate() { model.voiceToggle() } } label: {
            Icon(kind: .mic, size: size * 0.5, lineWidth: 1.8)
        }
        .buttonStyle(IconButtonStyle(background: model.listening ? .cbAction : plain ? .clear : Color.white.opacity(0.1),
                                     foreground: model.listening ? .white : plain ? .cbSecondary : .cbText, size: size, width: width))
        .help("Dictate")
        .accessibilityLabel("Dictate")
    }
}

struct ShotButton: View {
    @ObservedObject var model: AppModel
    var size: CGFloat = 32
    var plain = false
    var width: CGFloat?
    @Environment(\.clickGate) private var gate

    var body: some View {
        Button { if gate() { model.takeScreenshot() } } label: { Image(systemName: "camera.viewfinder").font(.system(size: size * 0.44)) }
            .buttonStyle(IconButtonStyle(background: plain ? .clear : Color.white.opacity(0.1),
                                         foreground: plain ? .cbSecondary : .cbText, size: size, width: width))
            .help("Screenshot an area; its path goes to Claude")
            .accessibilityLabel("Screenshot")
    }
}

struct TemplatesButton: View {
    @ObservedObject var model: AppModel
    var size: CGFloat = 32
    var plain = false
    var width: CGFloat?
    @Environment(\.cbPreview) private var preview
    @Environment(\.clickGate) private var gate

    var body: some View {
        // A plain button, the menu at the pointer (as the chats'): a SwiftUI
        // Menu drew its icon off the middle (owner, 27.10).
        Button { if gate() { CommandMenu.show(model) } } label: {
            Image(systemName: "text.bubble").font(.system(size: size * 0.44))
                .frame(width: max(size, width ?? size), height: size)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(preview) // Settings' copy: nothing typed from it
        .foregroundColor(plain ? .cbSecondary : .cbText)
        .background(RoundedRectangle(cornerRadius: max(6, size * 0.26), style: .continuous)
            .fill(Color.white.opacity(plain ? 0.07 : 0.1)))
        .overlay(RoundedRectangle(cornerRadius: max(6, size * 0.26), style: .continuous)
            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .help("Your commands")
        .accessibilityLabel("Commands")
    }
}

/// Your buttons as a menu at the pointer; with none, where to make some.
enum CommandMenu {
    final class Target: NSObject {
        let run: (Int) -> Void
        init(_ run: @escaping (Int) -> Void) { self.run = run }
        @objc func chosen(_ item: NSMenuItem) { run(item.tag) }
    }
    private static var target: Target?

    static func show(_ model: AppModel) {
        let menu = NSMenu()
        let t = Target { [weak model] i in
            guard let model else { return }
            if i < 0 { model.openSettingsTab("buttons") } else { model.runMenuButton(i) }
        }
        target = t
        let titles = model.menuButtons.map(\.label)
        for (i, title) in (titles.isEmpty ? ["Add buttons…"] : titles).enumerated() {
            let item = NSMenuItem(title: title, action: #selector(Target.chosen(_:)), keyEquivalent: "")
            item.target = t
            item.tag = titles.isEmpty ? -1 : i
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

// MARK: - Requests

struct RequestCardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState
    @Environment(\.cbPreview) private var preview
    @FocusState private var otherFocused: Bool
    /// The card whose keys work: a moment after it came. You may have been
    /// typing when it took the panel's place — the next key must not answer
    /// it (Esc, the numbers). Allow has no key at all.
    @State private var armed: UUID?

    var body: some View {
        cards
            .allowsHitTesting(!preview) // Settings' copy never answers Claude
            .task(id: model.request?.id) {
                armed = nil
                do { try await Task.sleep(nanoseconds: 1_200_000_000) } catch { return } // another card came
                armed = model.request?.id
            }
    }

    @ViewBuilder private var cards: some View {
        if let r = model.request {
            if r.kind == .permission {
                // Wider and lower than the mockup, at the owner's request.
                PanelChrome(padding: EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12), spacing: 10, width: 420) {
                    permission(r)
                }
            } else {
                // As wide as the permission card: a long question, long
                // descriptions and another chat's long name fit (owner, 26.10:
                // a 320-pt card came out cut off at both sides).
                PanelChrome(spacing: 14, width: 420) { question(r) }
            }
        }
    }

    /// One line of header, the command, one row of buttons.
    @ViewBuilder private func permission(_ r: AppModel.RequestCard) -> some View {
        HStack(spacing: 8) {
            MascotIcon(activity: .wait, size: 24).frame(width: 24, height: 24)
            Text("Needs your OK").font(.system(size: 13, weight: .semibold)).foregroundColor(.cbText)
            if let chat = r.chat {
                ChatTag(name: chat, color: r.color ?? 0x0A84FF, elsewhere: r.elsewhere, maxWidth: 150)
            }
            Text(r.verb == "Run" ? "run in terminal" : r.verb.lowercased())
                .font(.system(size: 12)).foregroundColor(.cbSecondary).lineLimit(1)
            Spacer(minLength: 0)
            PulseDot(still: model.config.doNotDisturb)
        }
        // All of it, scrolling past a few lines: Allow shouldn't be pressed
        // on the first three lines of a longer command.
        ScrollView(.vertical) {
            Text(r.detail)
                .font(.system(size: 12, design: .monospaced))
                .lineSpacing(2)
                .foregroundColor(.cbText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .frame(maxHeight: 132)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 8).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.3)))
        HStack(spacing: 6) {
            Button("Allow") { model.perform(.allow) }
                .buttonStyle(WidgetButtonStyle(background: .cbAction, foreground: .white, weight: .semibold,
                                               height: 32, radius: 9))
            if r.offersAlways {
                Button("Always allow") { model.perform(.always) }
                    .buttonStyle(WidgetButtonStyle(height: 32, radius: 9))
            }
            Button("Deny") { model.perform(.deny) }
                .buttonStyle(WidgetButtonStyle(foreground: .cbDeny, height: 32, radius: 9))
                .cancelKey(enabled: armed == r.id)
                .help("Esc")
        }
    }

    @ViewBuilder private func question(_ r: AppModel.RequestCard) -> some View {
        HStack(spacing: 10) {
            MascotIcon(activity: .wait, size: 32).frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Claude asks").font(.system(size: 13, weight: .semibold)).foregroundColor(.cbText)
                    if r.count > 1 {
                        Text("\(r.index + 1) of \(r.count)").font(.system(size: 12)).foregroundColor(.cbSecondary)
                    }
                }
                if let chat = r.chat {
                    ChatTag(name: chat, color: r.color ?? 0x0A84FF, elsewhere: r.elsewhere)
                }
            }
            Spacer(minLength: 0)
            PulseDot(still: model.config.doNotDisturb)
        }
        Text(r.question).font(.system(size: 14, weight: .medium)).lineSpacing(2).foregroundColor(.cbText)
            .fixedSize(horizontal: false, vertical: true)
        VStack(spacing: 0) {
            ForEach(Array(r.options.enumerated()), id: \.offset) { i, label in
                OptionRow(label: label, description: r.descriptions.indices.contains(i) ? r.descriptions[i] : "",
                          picked: r.multiSelect ? r.picked.contains(i) : nil, delay: 0.08 + 0.04 * Double(i)) {
                    model.perform(.option(i))
                }
                .numberKey(i + 1, enabled: i < 9 && !otherFocused && armed == r.id)
                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
            }
            HStack(spacing: 8) {
                Text("Other").font(.system(size: 13)).foregroundColor(.cbSecondary)
                TextField("", text: $model.otherDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.25)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                    .focused($otherFocused)
                    .onSubmit(sendOther)
                Button(action: sendOther) { Icon(kind: .send, size: 16, lineWidth: 2.4) }
                    .buttonStyle(IconButtonStyle(background: .cbAction, foreground: .white))
                    .accessibilityLabel("Send")
            }
            .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 8)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        if r.multiSelect && !r.picked.isEmpty {
            Button("Send \(r.picked.count) selected") { model.perform(.sendPicked) }
                .buttonStyle(WidgetButtonStyle(background: .cbAction, foreground: .white, weight: .semibold))
        }
        Text(r.options.isEmpty ? "Hold right ⌥ to answer by voice"
             : "1–\(min(9, r.options.count)) to pick · hold right ⌥ to answer by voice")
            .font(.system(size: 11)).foregroundColor(.cbSecondary)
    }

    private func sendOther() {
        let text = model.otherDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.answerText(text)
    }

    private var meters: String {
        "Session \(model.sessionPercent.map { "\(Int($0.rounded()))%" } ?? "—") · Context \(model.contextPercent.map { "\(Int($0.rounded()))%" } ?? "—")"
    }

    private func footer(left: String, right: String) -> some View {
        HStack {
            Text(left)
            Spacer()
            Text(right)
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundColor(.cbSecondary)
    }
}

struct OptionRow: View {
    let label: String
    let description: String
    /// nil for single choice; picked or not for multiple choice.
    let picked: Bool?
    let delay: Double
    let action: () -> Void
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let picked {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .foregroundColor(picked ? .cbAction : .cbSecondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    title.font(.system(size: 13)).foregroundColor(.cbText)
                    if !description.isEmpty {
                        Text(description).font(.system(size: 11)).foregroundColor(.cbSecondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8).padding(.horizontal, 12)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 4)
        .onAppear {
            if reduceMotion { shown = true } else { withAnimation(.easeOut(duration: 0.24).delay(delay)) { shown = true } }
        }
    }

    /// "SQLite (Recommended)" → "SQLite · recommended", as in the mockup.
    private var title: Text {
        let marker = "(Recommended)"
        if label.contains(marker) {
            let name = label.replacingOccurrences(of: marker, with: "").trimmingCharacters(in: .whitespaces)
            return Text(name) + Text(" · recommended").foregroundColor(.cbSecondary)
        }
        return Text(label)
    }
}

// MARK: - Chats

/// The open widget's two tabs (owner, 27.10): the panel for the chat it
/// follows, and every chat to write to without switching to it.
struct PanelTabs: View {
    @ObservedObject var state: WidgetState
    @Namespace private var lit

    static let width: CGFloat = 112

    var body: some View {
        HStack(spacing: 2) {
            tab("Panel", .panel)
            tab("Chats", .chats)
        }
        .padding(3)
        .frame(width: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.25)))
    }

    private func tab(_ title: String, _ mode: WidgetMode) -> some View {
        let on = state.mode == mode
        return Button { if !on { withAnimation(.cbSwap) { state.mode = mode } } } label: {
            Text(title).font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundColor(on ? .cbText : .cbSecondary)
                .frame(maxWidth: .infinity, minHeight: 20)
                .background {
                    if on {
                        RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.16))
                            .matchedGeometryEffect(id: "tab", in: lit)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title + (on ? ", shown" : ""))
    }
}

/// Every chat, to write to where it is (owner, 27.10: from "Status bar", a
/// screenshot for another chat, nothing switching). A click on a chat opens
/// a line under it — words, a screenshot of an area, your voice, Send — all
/// for that chat, whatever the widget follows; no window comes forward.
/// ↗ is the one way into a chat: followed here and opened, as a click on
/// it did before.
struct ChatsPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState
    @Environment(\.cbPreview) private var preview
    @FocusState private var typing: Bool

    static let width: CGFloat = 440
    private static let tool: CGFloat = 28
    /// The composer under a row starts where the row's words do.
    private static let indent: CGFloat = 8 + 28 + 10

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            VStack(spacing: 0) {
                ForEach(model.sessions) { s in
                    row(s)
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
                }
                if model.sessions.isEmpty {
                    Text("No chat open").font(.system(size: 12)).foregroundColor(.cbSecondary)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            // Where the words went, a moment after Send; else what a click does.
            Text(model.sentNote?.text ?? "Click a chat to write to it from here · ↗ opens it · % = context")
                .font(.system(size: 11)).foregroundColor(model.sentNote == nil ? .cbSecondary : .cbText)
                .lineLimit(1).padding(.horizontal, 2)
                .animation(.easeOut(duration: 0.2), value: model.sentNote)
        }
        .foregroundColor(.cbText)
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
        .frame(width: Self.width)
        .modifier(PanelMaterial())
        // In from the right as the panel fades back, like a page turning.
        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)).combined(with: .scale(scale: 0.98, anchor: .top)),
                                removal: .opacity.combined(with: .offset(x: 24))))
        // A composer just opened (a click, a screenshot back): the cursor in it.
        .onChange(of: state.focusComposer) { _ in DispatchQueue.main.async { typing = true } }
    }

    /// Cloud, the tabs, the chat the widget follows, the collapse button.
    private var header: some View {
        HStack(spacing: 10) {
            if !state.hidesHeaderCharacter {
                MascotIcon(activity: model.activity, size: 28, waves: model.cloudWaves).frame(width: 28, height: 28)
            }
            PanelTabs(state: state)
            Spacer(minLength: 0)
            if let name = model.chatName {
                Text("Following: \(name)").font(.system(size: 12)).foregroundColor(.cbSecondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Button {
                if let collapse = state.collapse { collapse() } else { withAnimation(.cb(0.22)) { state.mode = state.rest } }
            } label: { Icon(kind: .chevronUp, size: 14) }
                .buttonStyle(IconButtonStyle(size: 30))
                .accessibilityLabel("Collapse")
        }
        .disabled(preview)
    }

    private func row(_ s: AppModel.SessionRow) -> some View {
        let open = state.composerChat == s.id
        let queued = model.queue.filter { $0.sessionId == s.id }.count
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button { toggle(s.id) } label: {
                    HStack(spacing: 10) {
                        MascotIcon(activity: s.activity, size: 28).frame(width: 28, height: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                ChatDot(color: s.color)
                                Text(s.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                if s.current {
                                    Text("followed").font(.system(size: 10)).foregroundColor(.cbSecondary)
                                }
                            }
                            Text(([s.place, s.status] + (queued > 0 ? ["\(queued) queued"] : [])).filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 11)).foregroundColor(s.waiting ? .cbWarningText : .cbSecondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(open ? "Close" : "Write to \(s.name) from here — nothing switches")
                .accessibilityLabel((open ? "Close the message to " : "Write to ") + s.name)
                Text(s.context.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundColor((s.context ?? 0) >= 90 ? .cbDeny : (s.context ?? 0) >= 70 ? .cbWarningText : .cbSecondary)
                // Today's click on a chat: followed here and opened.
                Button {
                    if s.waiting { model.showRequest(s.id) }
                    model.focusSession(s.id)
                    withAnimation(.cbSwap) { state.mode = .panel }
                } label: { Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(IconButtonStyle(size: 26))
                    .help("Follow it here and open it")
                    .accessibilityLabel("Open \(s.name)")
            }
            .padding(.leading, 8).padding(.trailing, 8)
            .frame(height: 50)
            if open { composer(s).transition(.opacity) }
        }
        .background(open ? Color.white.opacity(0.05) : s.waiting ? Color.cbWarning.opacity(0.10) : Color.clear)
        .disabled(preview) // Settings' copy: nothing sent or opened from it
    }

    /// The line under an open row: its queue (Send now brings that chat up),
    /// its files, then the field, a screenshot and the mic for it, Send.
    private func composer(_ s: AppModel.SessionRow) -> some View {
        let width = Self.width - 24 - Self.indent - 8
        let files = model.chatFiles[s.id] ?? []
        let queued = model.queue.filter { $0.sessionId == s.id }
        let listening = model.listeningFor == s.id
        let draft = Binding(get: { model.chatDrafts[s.id] ?? "" }, set: { model.chatDrafts[s.id] = $0 })
        let sendable = !(model.chatDrafts[s.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !files.isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(queued) { item in
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 9)).foregroundColor(.cbSecondary)
                    Text(item.text).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { model.sendQueuedNow(item.id) } label: {
                        Label("Send now", systemImage: "paperplane.fill").labelStyle(.titleAndIcon).font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.plain).foregroundColor(.cbMeter)
                    .help("Opens its chat and sends it now")
                    Button { model.removeFromQueue(item.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                        .buttonStyle(.plain).foregroundColor(.cbSecondary)
                        .accessibilityLabel("Remove from queue")
                }
                .font(.system(size: 11))
            }
            if !files.isEmpty { fileChips(files, chat: s.id, width: width) }
            if listening {
                Text(model.heard.isEmpty ? "Listening… it stops after a pause" : model.heard)
                    .font(.system(size: 11)).foregroundColor(.cbMeter).lineLimit(2)
            }
            HStack(spacing: 6) {
                TextField("Write to \(s.name)…", text: draft)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .frame(height: Self.tool)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.25)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(typing ? 0.28 : 0.12), lineWidth: typing ? 1 : 0.5))
                    .focused($typing)
                    .onSubmit { send(s) }
                    .onExitCommand { toggle(s.id) }
                Button { model.screenshotTo(s.id) } label: { Image(systemName: "camera.viewfinder").font(.system(size: Self.tool * 0.44)) }
                    .buttonStyle(IconButtonStyle(background: Color.white.opacity(0.1), foreground: .cbText, size: Self.tool))
                    .help("Screenshot an area for \(s.name)")
                    .accessibilityLabel("Screenshot for \(s.name)")
                Button { model.voiceTo(s.id) } label: { Icon(kind: .mic, size: Self.tool * 0.5, lineWidth: 1.8) }
                    .buttonStyle(IconButtonStyle(background: listening ? .cbAction : Color.white.opacity(0.1),
                                                 foreground: listening ? .white : .cbText, size: Self.tool))
                    .help("Dictate to \(s.name)")
                    .accessibilityLabel("Dictate to \(s.name)")
                // In the chat's colour, as the mockup has it; dark on a light one.
                Button { send(s) } label: { Icon(kind: .send, size: 13, lineWidth: 2.4) }
                    .buttonStyle(IconButtonStyle(background: sendable ? Color(hex: s.color) : Color.white.opacity(0.1),
                                                 foreground: sendable && Self.light(s.color) ? .black : .white, size: Self.tool))
                    .disabled(!sendable)
                    .help("Send to \(s.name)")
                    .accessibilityLabel("Send to \(s.name)")
            }
        }
        .frame(width: width, alignment: .leading)
        .padding(.leading, Self.indent).padding(.bottom, 10)
    }

    private func fileChips(_ files: [String], chat id: String, width: CGFloat) -> some View {
        let board = flowSlots(files.map { (id: $0, width: AttachmentChip.width($0)) }, width: width, rowHeight: 24, gap: 6, rowGap: 6)
        return ZStack(alignment: .topLeading) {
            ForEach(files, id: \.self) { path in
                let slot = board.slots[path] ?? .zero
                AttachmentChip(path: path) { model.removeAttachmentFrom(path, id) }
                    .frame(width: slot.width, height: 24)
                    .offset(x: slot.minX, y: slot.minY)
            }
        }
        .frame(width: width, height: board.size.height, alignment: .topLeading)
    }

    /// One composer open at a time; a click on its row again closes it.
    private func toggle(_ id: String) {
        let opening = state.composerChat != id
        withAnimation(.cb(0.22)) { state.composerChat = opening ? id : nil }
        if opening {
            state.composerKeyboard?()
            state.focusComposer += 1
        } else {
            typing = false
        }
    }

    private func send(_ s: AppModel.SessionRow) {
        let text = (model.chatDrafts[s.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !(model.chatFiles[s.id] ?? []).isEmpty else { return }
        model.sendTo(text, s.id)
        model.chatDrafts[s.id] = nil
    }

    /// A chat colour light enough for a dark icon on it (yellow, mint).
    static func light(_ hex: UInt32) -> Bool {
        let r = Double((hex >> 16) & 0xFF), g = Double((hex >> 8) & 0xFF), b = Double(hex & 0xFF)
        return (0.299 * r + 0.587 * g + 0.114 * b) / 255 > 0.7
    }
}

extension View {
    @ViewBuilder func cancelKey(enabled: Bool) -> some View {
        if enabled { keyboardShortcut(.cancelAction) } else { self }
    }

    /// 1–9 picks an option, but not while you type in the Other field.
    @ViewBuilder func numberKey(_ n: Int, enabled: Bool) -> some View {
        if enabled {
            keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [])
        } else {
            self
        }
    }
}
