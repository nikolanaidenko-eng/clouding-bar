import SwiftUI

// The floating widget, drawn to design/Main.dc.html and design/Widget-*.dc.html.
// Sizes are in points; colors and timings come from the mockups.

enum WidgetMode { case strip, pill, panel, sessions }

final class WidgetState: ObservableObject {
    @Published var mode: WidgetMode = .pill
    /// What it collapses to: the pill, or the thin line.
    var rest: WidgetMode = .pill
    /// Set by WidgetController: the pill hands its mouse-downs over for dragging.
    var pillMouseDown: ((NSEvent) -> Void)?
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
    static let cbHairline = Color.white.opacity(0.14)

    static func meter(_ percent: Double) -> Color {
        percent >= 90 ? Color(hex: 0xFF453A) : percent >= 70 ? .cbWarning : .cbFill
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

    func makeNSView(context: Context) -> MascotView { MascotView(size: size) }
    func updateNSView(_ view: MascotView, context: Context) { view.activity = activity }
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
    var height: CGFloat = 4
    var track = Color.white.opacity(0.12)
    var color: Color? = nil
    var delay: Double = 0
    @State private var shown: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(color ?? Color.meter(percent ?? 0))
                    .frame(width: geo.size.width * CGFloat(min(max(shown, 0), 100) / 100))
            }
        }
        .frame(height: height)
        .onAppear { animate(to: percent ?? 0, delay: delay) }
        .onChange(of: percent ?? 0) { animate(to: $0, delay: 0) }
    }

    private func animate(to value: Double, delay: Double) {
        if reduceMotion { shown = value; return }
        withAnimation(.cb(0.9).delay(delay)) { shown = value }
    }
}

/// The orange "waiting for you" dot, pulsing 1.4 s (still in Do not disturb).
struct PulseDot: View {
    var size: CGFloat = 8
    var still = false
    @State private var dim = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle().fill(Color.cbWarning)
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(foreground)
            .frame(width: size, height: size)
            .background(Circle().fill(background.opacity(configuration.isPressed ? 0.6 : 1)))
            .contentShape(Circle())
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

    var body: some View {
        Group {
            switch state.mode {
            case .strip: StripView(model: model)
            case .pill: PillView(model: model, state: state)
            case .panel:
                if model.request != nil { RequestCardView(model: model, state: state) }
                else if !model.hasSession { EmptyPanel(model: model) }
                else { MainPanel(model: model, state: state) }
            case .sessions: SessionsPanel(model: model, state: state)
            }
        }
        .fixedSize()
        .environment(\.colorScheme, .dark)
    }
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

// MARK: - Pill

struct PillView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState

    var body: some View {
        content
            .lineLimit(1)
            .fixedSize() // numbers never wrap or squeeze
            .font(.system(size: 13).monospacedDigit())
            .foregroundColor(.cbText)
            .padding(.leading, 10)
            .padding(.trailing, 20)
            .frame(height: 44)
            .modifier(Glass(radius: 22, border: model.request != nil ? Color.cbWarning.opacity(0.5) : .cbHairline))
            .overlay(PillDragHandle(state: state))
            .transition(.scale(scale: 0.9).combined(with: .opacity))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Show Clouding Bar")
    }

    @ViewBuilder private var content: some View {
        if model.listening {
            // The words as they come; the newest stay in view.
            HStack(spacing: 10) {
                MascotIcon(activity: .work, size: 30).frame(width: 30, height: 30)
                Icon(kind: .mic, size: 15, lineWidth: 1.8).foregroundColor(.cbAction)
                Text(model.heard.isEmpty ? "Listening…" : model.heard)
                    .foregroundColor(model.heard.isEmpty ? .cbSecondary : .cbText)
                    .truncationMode(.head)
                    .frame(width: 300, alignment: .leading)
            }
        } else if model.request != nil {
            HStack(spacing: 10) {
                MascotIcon(activity: .wait, size: 30).frame(width: 30, height: 30)
                Text(model.statusTitle)
                PulseDot(still: model.config.doNotDisturb)
            }
        } else if !model.hasSession {
            HStack(spacing: 10) {
                MascotIcon(activity: .sleep, size: 30).frame(width: 30, height: 30)
                Text(model.sessionPercent.map { "\(Int($0.rounded()))%" } ?? "—").foregroundColor(.cbSecondary)
            }
        } else {
            HStack(spacing: 16) {
                MascotIcon(activity: model.activity, size: 30).frame(width: 30, height: 30)
                HStack(spacing: 8) {
                    MeterBar(percent: model.sessionPercent, height: 3, track: .white.opacity(0.14)).frame(width: 44)
                    Text(model.sessionPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                }
                if model.config.pillShows.contains("context"), let c = model.contextPercent {
                    HStack(spacing: 4) {
                        Text("ctx").font(.system(size: 11)).foregroundColor(.cbSecondary)
                        Text("\(Int(c.rounded()))%")
                    }
                }
                if model.config.pillShows.contains("reset"), let r = model.resetShort {
                    HStack(spacing: 4) {
                        Icon(kind: .clock, size: 12, lineWidth: 2.2).foregroundColor(.cbSecondary)
                            .accessibilityLabel("resets in")
                        Text(r)
                    }
                }
                if model.config.pillShows.contains("cost"), let cost = model.cost {
                    Text(String(format: "$%.2f", cost)).foregroundColor(.cbFill)
                }
            }
        }
    }
}

/// Lets the pill be dragged (and clicked) — the strip and the panel can't.
struct PillDragHandle: NSViewRepresentable {
    let state: WidgetState

    final class HandleView: NSView {
        var onMouseDown: ((NSEvent) -> Void)?
        override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    func makeNSView(context: Context) -> HandleView {
        let v = HandleView()
        v.onMouseDown = { [weak state] in state?.pillMouseDown?($0) }
        return v
    }
    func updateNSView(_ nsView: HandleView, context: Context) {}
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
            .modifier(Glass(radius: 18))
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

/// The open widget, wide and low (the owner's request, 15.10): one header
/// line, Session and Context side by side, the buttons and the mic in a row.
struct MainPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState
    @State private var queueDraft = ""

    var body: some View {
        PanelChrome(padding: EdgeInsets(top: 8, leading: 12, bottom: 12, trailing: 8), spacing: 10, width: 420) {
            HStack(spacing: 8) {
                MascotIcon(activity: model.activity, size: 24).frame(width: 24, height: 24)
                Text(model.statusTitle).font(.system(size: 13, weight: .semibold)).foregroundColor(.cbText)
                if let project = model.project {
                    Text(project).font(.system(size: 12)).foregroundColor(.cbSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if model.config.sessionsList {
                    Button {
                        withAnimation(.cb(0.26)) { state.mode = .sessions }
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(model.sessions.count) session\(model.sessions.count == 1 ? "" : "s")")
                            Icon(kind: .chevronRight, size: 11, lineWidth: 2.2)
                        }
                        .font(.system(size: 12))
                        .foregroundColor(.cbSecondary)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button { withAnimation(.cb(0.22)) { state.mode = state.rest } } label: { Icon(kind: .chevronUp, size: 14) }
                    .buttonStyle(IconButtonStyle(size: 30))
                    .accessibilityLabel("Collapse")
            }
            HStack(alignment: .top, spacing: 16) {
                MeterBlock(title: "Session", percent: model.sessionPercent,
                           caption: model.resetLong.map { "Resets in \($0)" })
                MeterBlock(title: "Context", percent: model.contextPercent, caption: tokens, delay: 0.12)
            }
            .padding(.trailing, 4)
            if !metricItems.isEmpty {
                HStack(spacing: 12) { ForEach(Array(metricItems.enumerated()), id: \.offset) { $0.element } }
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundColor(.cbSecondary)
            }
            HStack(spacing: 6) {
                ForEach(Array(model.buttons.enumerated()), id: \.offset) { i, b in
                    Button(b.label) { model.perform(.button(i)) }
                        .buttonStyle(WidgetButtonStyle(height: 32, radius: 9))
                        .lineLimit(1)
                }
                if model.config.templatesEnabled && !model.config.templates.isEmpty {
                    Menu {
                        ForEach(model.config.templates, id: \.self) { t in
                            Button(t) { model.insertTemplate(t) }
                        }
                    } label: {
                        Image(systemName: "text.bubble").font(.system(size: 14))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white.opacity(0.1)))
                    .help("Templates")
                    .accessibilityLabel("Templates")
                }
                if model.config.screenshot {
                    Button { model.takeScreenshot() } label: { Image(systemName: "camera.viewfinder").font(.system(size: 14)) }
                        .buttonStyle(IconButtonStyle(background: Color.white.opacity(0.1), foreground: .cbText, size: 32))
                        .help("Screenshot an area; its path goes to Claude")
                        .accessibilityLabel("Screenshot")
                }
                MicButton(model: model)
            }
            .padding(.trailing, 4)
            if model.config.taskQueue { queueView }
        }
    }

    /// Model · effort, ±lines, branch, subagents, cost — whichever are on.
    private var metricItems: [AnyView] {
        let on = Set(model.config.metrics)
        var items: [AnyView] = []
        if on.contains("model"), let name = model.modelName {
            items.append(AnyView(Button { model.changeModel() } label: {
                Text(name + (model.effort.map { " · \($0)" } ?? ""))
            }
            .buttonStyle(.plain)
            .help("Change the model (/model)")))
        }
        if on.contains("lines") {
            items.append(AnyView(Text("+\(model.linesAdded) −\(model.linesRemoved)")))
        }
        if on.contains("git"), let b = model.branch {
            items.append(AnyView(HStack(spacing: 3) { Image(systemName: "arrow.triangle.branch"); Text(b).lineLimit(1) }))
        }
        if on.contains("agents") {
            items.append(AnyView(Text("\(model.agents) subagent\(model.agents == 1 ? "" : "s")")))
        }
        if on.contains("cost"), model.isAPI, let c = model.cost {
            items.append(AnyView(Text(String(format: "$%.2f", c))))
        }
        return items
    }

    /// Requests that go out one by one after each reply.
    private var queueView: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(model.queue.prefix(4).enumerated()), id: \.element.id) { i, item in
                HStack(spacing: 6) {
                    Text("\(i + 1).").foregroundColor(.cbSecondary)
                    Text(item.text).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { model.removeFromQueue(item.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                        .buttonStyle(.plain).foregroundColor(.cbSecondary)
                        .accessibilityLabel("Remove from queue")
                }
                .font(.system(size: 12))
            }
            if model.queue.count > 4 {
                Text("+\(model.queue.count - 4) more").font(.system(size: 11)).foregroundColor(.cbSecondary)
            }
            HStack(spacing: 6) {
                TextField("Queue a request for after this reply", text: $queueDraft)
                    .textFieldStyle(.plain).font(.system(size: 12))
                    .padding(.horizontal, 8).frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.25)))
                    .onSubmit(addToQueue)
                Button(action: addToQueue) { Image(systemName: "plus").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(IconButtonStyle(background: Color.white.opacity(0.1), foreground: .cbText, size: 28))
                    .accessibilityLabel("Add to queue")
            }
        }
        .padding(.trailing, 4)
    }

    private func addToQueue() {
        let text = queueDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.addToQueue(text)
        queueDraft = ""
    }

    private var tokens: String? {
        guard let i = model.tokensIn, let o = model.tokensOut else { return nil }
        return "\(AppModel.compact(i)) in · \(AppModel.compact(o)) out"
    }
}

/// Tap to dictate: the panel folds into the pill, which shows the words as
/// they come. It stops by itself after a pause, or tap the pill.
struct MicButton: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Button { model.voiceToggle() } label: {
            Icon(kind: .mic, size: 16, lineWidth: 1.8)
        }
        .buttonStyle(IconButtonStyle(background: model.listening ? .cbAction : Color.white.opacity(0.1),
                                     foreground: model.listening ? .white : .cbText, size: 32))
        .accessibilityLabel("Dictate")
    }
}

struct EmptyPanel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        PanelChrome(padding: EdgeInsets(top: 20, leading: 16, bottom: 16, trailing: 16), spacing: 12) {
            VStack(spacing: 12) {
                MascotIcon(activity: .sleep, size: 56).frame(width: 56, height: 56)
                VStack(spacing: 4) {
                    Text("No Claude Code session").font(.system(size: 13, weight: .semibold))
                    Text("Start Claude Code in VS Code or Terminal.").font(.system(size: 12)).foregroundColor(.cbSecondary)
                }
                .multilineTextAlignment(.center)
                if let p = model.sessionPercent {
                    VStack(spacing: 6) {
                        HStack {
                            Text("Session" + (model.limitAge.map { " · \($0)" } ?? "")).foregroundColor(.cbSecondary)
                            Spacer()
                            Text("\(Int(p.rounded()))%").monospacedDigit().foregroundColor(Color(hex: 0xC7C7CC))
                        }
                        .font(.system(size: 12))
                        MeterBar(percent: p, color: .cbMuted)
                    }
                    .padding(.top, 12)
                    .overlay(Rectangle().fill(Color.white.opacity(0.1)).frame(height: 0.5), alignment: .top)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Requests

struct RequestCardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState
    @FocusState private var otherFocused: Bool

    var body: some View {
        if let r = model.request {
            if r.kind == .permission {
                // Wider and lower than the mockup, at the owner's request.
                PanelChrome(padding: EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12), spacing: 10, width: 420) {
                    permission(r)
                }
            } else {
                PanelChrome(spacing: 14) { question(r) }
            }
        }
    }

    /// One line of header, the command, one row of buttons.
    @ViewBuilder private func permission(_ r: AppModel.RequestCard) -> some View {
        HStack(spacing: 8) {
            MascotIcon(activity: .wait, size: 24).frame(width: 24, height: 24)
            Text("Needs your OK").font(.system(size: 13, weight: .semibold)).foregroundColor(.cbText)
            Text([r.project, r.verb == "Run" ? "run in terminal" : r.verb.lowercased()]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 12)).foregroundColor(.cbSecondary).lineLimit(1)
            Spacer(minLength: 0)
            PulseDot(still: model.config.doNotDisturb)
        }
        Text(r.detail)
            .font(.system(size: 12, design: .monospaced))
            .lineSpacing(2)
            .lineLimit(3)
            .foregroundColor(.cbText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black.opacity(0.3)))
            .textSelection(.enabled)
        HStack(spacing: 6) {
            Button("Allow") { model.perform(.allow) }
                .buttonStyle(WidgetButtonStyle(background: .cbAction, foreground: .white, weight: .semibold,
                                               height: 32, radius: 9))
                .keyboardShortcut(.defaultAction)
                .help("Return")
            Button("Always allow") { model.perform(.always) }
                .buttonStyle(WidgetButtonStyle(height: 32, radius: 9))
            Button("Deny") { model.perform(.deny) }
                .buttonStyle(WidgetButtonStyle(foreground: .cbDeny, height: 32, radius: 9))
                .keyboardShortcut(.cancelAction)
                .help("Esc")
        }
    }

    @ViewBuilder private func question(_ r: AppModel.RequestCard) -> some View {
        PanelHeader(activity: .wait, title: "Claude asks",
                    subtitle: [r.project, r.count > 1 ? "\(r.index + 1) of \(r.count)" : nil].compactMap { $0 }.joined(separator: " · "),
                    waiting: true, dnd: model.config.doNotDisturb)
        Text(r.question).font(.system(size: 14, weight: .medium)).lineSpacing(2).foregroundColor(.cbText)
            .fixedSize(horizontal: false, vertical: true)
        VStack(spacing: 0) {
            ForEach(Array(r.options.enumerated()), id: \.offset) { i, label in
                OptionRow(label: label, description: r.descriptions.indices.contains(i) ? r.descriptions[i] : "",
                          picked: r.multiSelect ? r.picked.contains(i) : nil, delay: 0.08 + 0.04 * Double(i)) {
                    model.perform(.option(i))
                }
                .numberKey(i + 1, enabled: i < 9 && !otherFocused)
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

// MARK: - Sessions

struct SessionsPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Button { withAnimation(.cb(0.26)) { state.mode = .panel } } label: { Icon(kind: .chevronLeft, lineWidth: 2.2) }
                    .buttonStyle(IconButtonStyle())
                    .padding(.leading, -12)
                    .accessibilityLabel("Back")
                Text("Sessions").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Session \(model.sessionPercent.map { "\(Int($0.rounded()))%" } ?? "—")")
                    .font(.system(size: 12)).foregroundColor(.cbSecondary)
            }
            VStack(spacing: 0) {
                ForEach(model.sessions) { s in
                    Button {
                        if s.waiting { model.showRequest(s.id); state.mode = .panel } else { model.openSession(s.id) }
                    } label: { row(s) }
                    .buttonStyle(.plain)
                    Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
                }
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("Click to open its VS Code window · % = context")
                .font(.system(size: 11)).foregroundColor(.cbSecondary).padding(.horizontal, 2)
        }
        .foregroundColor(.cbText)
        .padding(EdgeInsets(top: 8, leading: 14, bottom: 14, trailing: 14))
        .frame(width: 320)
        .modifier(Glass(radius: 18))
        .transition(.opacity.combined(with: .offset(x: 12)))
    }

    private func row(_ s: AppModel.SessionRow) -> some View {
        HStack(spacing: 10) {
            MascotIcon(activity: s.activity, size: 28).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(s.name).font(.system(size: 13))
                Text(s.status).font(.system(size: 11)).foregroundColor(s.waiting ? .cbWarningText : .cbSecondary)
            }
            Spacer(minLength: 0)
            Text(s.context.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor((s.context ?? 0) >= 90 ? .cbDeny : (s.context ?? 0) >= 70 ? .cbWarningText : .cbSecondary)
        }
        .padding(.leading, 8).padding(.trailing, 12)
        .frame(height: 52)
        .background(s.waiting ? Color.cbWarning.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
    }
}

extension View {
    /// 1–9 picks an option, but not while you type in the Other field.
    @ViewBuilder func numberKey(_ n: Int, enabled: Bool) -> some View {
        if enabled {
            keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: [])
        } else {
            self
        }
    }
}
