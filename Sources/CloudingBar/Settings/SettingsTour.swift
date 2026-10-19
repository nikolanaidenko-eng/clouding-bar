import SwiftUI

/// The tour (owner's request, 20.10), right in the settings window: it dims
/// but for one thing at a time, a note in handwriting points at it with an
/// arrow drawing itself, Cloud hops onto it, and a line underneath says
/// what it's for. Eight stops across the tabs; one switch to try on the way.
struct TourStop {
    let tab: String
    /// The `tourAnchor` it points at.
    let anchor: String
    /// In handwriting, by the arrow.
    let note: String
    let text: String
    /// A setting that, changed here, counts as tried.
    var tryKey: String? = nil
    /// Pointed at when `anchor` isn't there (the notch switch, with the widget off).
    var fallback: String? = nil
}

enum SettingsTour {
    static let stops: [TourStop] = [
        TourStop(tab: "general", anchor: "tabs", note: "it all lives in these tabs",
                 text: "Hi, I'm Cloud! Eight quick stops and you know everything. Skip any time."),
        TourStop(tab: "general", anchor: "hooks", note: "this is how I see Claude",
                 text: "Connected: Claude Code tells me what it's doing. If not, press Connect — your settings.json is backed up first."),
        TourStop(tab: "widget", anchor: "widget.show", note: "your pill on the screen",
                 text: "A small pill over your windows: the 5-hour limit and how full the chat is. Hover it for the whole panel."),
        TourStop(tab: "widget", anchor: "widget.notch", note: "or tuck it in the notch",
                 text: "Try it: flip the switch. Drag the pill out of the notch to put it anywhere.", tryKey: "notch",
                 fallback: "widget.show"),
        TourStop(tab: "touchbar", anchor: "touchbar.preview", note: "the same on the Touch Bar",
                 text: "Claude's questions and permission requests show up here and in the widget: answer with a tap."),
        TourStop(tab: "buttons", anchor: "buttons.list", note: "your own buttons",
                 text: "A phrase, a /command or a link. One tap sends it to the chat you're in."),
        TourStop(tab: "stats", anchor: "stats.map", note: "how your week went",
                 text: "Each square is an hour of Claude's work. Point at one to see what happened."),
        TourStop(tab: "general", anchor: "help", note: "I'm right here",
                 text: "The tour is behind the ? any time. Want to see the widget at work?"),
    ]

    /// The note's handwriting and its colour.
    static let ink = Color(hex: 0x66E3C4)
    static func hand(_ size: CGFloat) -> Font {
        NSFont(name: "Noteworthy-Bold", size: size) != nil ? .custom("Noteworthy-Bold", size: size)
            : .custom("Bradley Hand", size: size).weight(.bold)
    }
}

private struct TourAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Something the tour can point at.
    func tourAnchor(_ id: String) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [id: $0] }
    }

    /// The tour over the settings window, while `step` is set.
    func settingsTour(model: AppModel, cloud: SettingsCloud) -> some View {
        overlayPreferenceValue(TourAnchorKey.self) { anchors in
            GeometryReader { g in
                if let step = model.tourStep, SettingsTour.stops.indices.contains(step) {
                    let stop = SettingsTour.stops[step]
                    let anchor = anchors[stop.anchor] ?? stop.fallback.flatMap { anchors[$0] }
                    TourOverlay(model: model, cloud: cloud, step: step, target: anchor.map { g[$0] }, size: g.size)
                }
            }
        }
    }
}

/// The dimming with its hole, the note and its arrow, the line of text and
/// the buttons.
struct TourOverlay: View {
    @ObservedObject var model: AppModel
    let cloud: SettingsCloud
    let step: Int
    let target: CGRect?
    let size: CGSize
    @State private var hole: CGRect = .zero
    @State private var drawn: CGFloat = 0
    @State private var tried = false
    @State private var startConfig: Config?

    private var stop: TourStop { SettingsTour.stops[step] }
    private var last: Bool { step == SettingsTour.stops.count - 1 }

    var body: some View {
        let h = hole.insetBy(dx: -7, dy: -6)
        let below = h.midY < size.height * 0.52
        let noteWidth: CGFloat = 330
        let noteX = min(max(24, h.midX - 70), size.width - noteWidth - 24)
        let noteY = below ? h.maxY + 34 : h.minY - 34 - 104
        ZStack(alignment: .topLeading) {
            // The dimming, with a hole that glides from stop to stop. A click
            // in the hole goes through (to try the switch); elsewhere it doesn't.
            Hole(rect: h)
                .fill(Color.black.opacity(0.66), style: FillStyle(eoFill: true))
                .contentShape(Hole(rect: h), eoFill: true)
                .onTapGesture {}
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(SettingsTour.ink, lineWidth: 2)
                .frame(width: h.width, height: h.height)
                .offset(x: h.minX, y: h.minY)
                .allowsHitTesting(false)
            // The arrow, from the note to what it's about.
            Arrow(from: CGPoint(x: noteX + 40, y: below ? noteY - 4 : noteY + 108),
                  to: CGPoint(x: min(max(h.midX, h.minX + 20), h.maxX - 20), y: below ? h.maxY + 6 : h.minY - 6))
                .trim(from: 0, to: drawn)
                .stroke(SettingsTour.ink, style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 6) {
                Text(tried ? "nice!" : stop.note)
                    .font(SettingsTour.hand(24))
                    .foregroundColor(SettingsTour.ink)
                    .rotationEffect(.degrees(-3), anchor: .leading)
                    .id("note\(step)\(tried)")
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                Text(stop.text)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.94))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: 0x1C1C1E).opacity(0.92)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
                    .id("text\(step)")
                    .transition(.opacity)
            }
            .frame(width: noteWidth, alignment: .leading)
            .offset(x: noteX, y: noteY)
            .allowsHitTesting(false)
            controls
                .frame(width: size.width)
                .offset(y: size.height - 58)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(.spring(response: 0.5, dampingFraction: 0.82), value: hole)
        .onAppear {
            startConfig = model.config
            cloud.touring = true
            arrive(target)
        }
        .onDisappear { cloud.touring = false; cloud.goHome() }
        .onChange(of: target) { arrive($0) }
        .onChange(of: step) { _ in
            tried = false
            startConfig = model.config
        }
        .onChange(of: model.config) { config in
            // The switch to try was flipped: a cheer, and on.
            guard stop.tryKey == "notch", !tried, let start = startConfig,
                  config.widgetAtNotch != start.widgetAtNotch else { return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.6)) { tried = true }
            cloud.cheer(times: 2)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { if model.tourStep == step { go(step + 1) } }
        }
    }

    /// The stop's target is known (its tab drawn): the hole, the arrow, Cloud.
    private func arrive(_ rect: CGRect?) {
        guard let rect, rect != .zero else { return }
        if hole == .zero {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { hole = rect }
        } else {
            hole = rect
        }
        drawn = 0
        withAnimation(.easeInOut(duration: 0.55).delay(0.35)) { drawn = 1 }
        cloud.visit(rect)
    }

    private func go(_ next: Int) {
        guard next >= 0 else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            model.tourStep = next < SettingsTour.stops.count ? next : nil
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(SettingsTour.stops.indices, id: \.self) { i in
                    Capsule().fill(i == step ? SettingsTour.ink : Color.white.opacity(i < step ? 0.6 : 0.25))
                        .frame(width: i == step ? 18 : 6, height: 6)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: step)
            Spacer(minLength: 10)
            Button("Skip") { go(SettingsTour.stops.count) }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.white.opacity(0.7))
                .keyboardShortcut(.cancelAction)
            if step > 0 {
                Button("Back") { go(step - 1) }
                    .buttonStyle(TourButtonStyle(fill: Color.white.opacity(0.14)))
            }
            if last {
                Button("Watch it work") { model.showFilm(); go(step + 1) }
                    .buttonStyle(TourButtonStyle(fill: Color.white.opacity(0.14)))
            }
            Button(last ? "Done" : "Next") { go(step + 1) }
                .buttonStyle(TourButtonStyle(fill: Color(hex: 0x0A84FF)))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(Capsule().fill(Color(hex: 0x1C1C1E).opacity(0.94)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 24)
    }
}

struct TourButtonStyle: ButtonStyle {
    let fill: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(fill.opacity(configuration.isPressed ? 0.7 : 1)))
            .contentShape(Capsule())
    }
}

/// The whole window, less a rounded hole.
private struct Hole: Shape {
    var rect: CGRect

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(rect.minX, rect.minY), AnimatablePair(rect.width, rect.height)) }
        set { rect = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in r: CGRect) -> Path {
        var p = Path(r)
        p.addRoundedRect(in: rect, cornerSize: CGSize(width: 11, height: 11), style: .continuous)
        return p
    }
}

/// A hand-drawn arrow: a gentle curve and its head.
private struct Arrow: Shape {
    let from: CGPoint
    let to: CGPoint

    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: from)
        let bend = CGPoint(x: (from.x + to.x) / 2 + (to.y > from.y ? -36 : 36), y: (from.y + to.y) / 2)
        p.addQuadCurve(to: to, control: bend)
        // The head, along the curve's last direction.
        let angle = atan2(to.y - bend.y, to.x - bend.x)
        for side in [-1.0, 1.0] {
            let a = angle + .pi - side * 0.5
            p.move(to: to)
            p.addLine(to: CGPoint(x: to.x + 11 * cos(a), y: to.y + 11 * sin(a)))
        }
        return p
    }
}
