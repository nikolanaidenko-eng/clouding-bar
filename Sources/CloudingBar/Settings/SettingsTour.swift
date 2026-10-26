import SwiftUI

/// The tour (owner's request, 20.10: the Spotlight direction of the
/// design canvas), right in the settings window. Everything dims but one
/// thing, ringed in blue; a white card by it says what it is and what to
/// try; Cloud hops onto it. Seven stops across the tabs (cut down from
/// thirteen, owner, 25.10).
struct TourStop {
    let tab: String
    /// The `tourAnchor` it lights up.
    let anchor: String
    let title: String
    let text: String
    /// "Try it: …", and what counts as tried.
    var tryText: String? = nil
    var tried: Tried? = nil
    /// Lit up when `anchor` isn't there (the notch switch, with the widget off).
    var fallback: String? = nil

    enum Tried { case notch, more }
}

enum SettingsTour {
    static let stops: [TourStop] = [
        TourStop(tab: "general", anchor: "cloud", title: "Hi, I'm Cloud.",
                 text: "Seven stops, about a minute. Everything here can be changed later, and you can skip any time."),
        TourStop(tab: "general", anchor: "hooks", title: "This is the link to Claude Code",
                 text: "Connected means I can see your sessions. If not, press Connect: your settings.json is backed up first."),
        TourStop(tab: "widget", anchor: "widget.show", title: "The floating widget",
                 text: "A small pill over your windows: the 5-hour limit and how full the chat is. Hover it for the panel. It can live in the notch too; the rest is behind More."),
        TourStop(tab: "widget", anchor: "widget.preview", title: "Arrange it your way",
                 text: "Your widget as it is now. Drag an item onto another to swap them, its right edge to make it wider; in the panel, pull a block by the bar over it. It works in the widget itself too."),
        TourStop(tab: "touchbar", anchor: "touchbar.preview", title: "The same on the Touch Bar",
                 text: "Your Touch Bar, live: the whole bar and the short one beside Apple's buttons. Drag a block to move it, its right edge to size it. Claude's questions and permission requests show up there too: answer with a tap."),
        TourStop(tab: "buttons", anchor: "buttons.list", title: "Your own buttons",
                 text: "A phrase, a /command, a key or a link, on the Touch Bar and in the widget, all of them behind Commands. A tap sends it to the chat you're in, or puts text in for you to finish."),
        TourStop(tab: "stats", anchor: "stats.limits", title: "Your week in numbers",
                 text: "The 5-hour limit and the weekly one, and below them your sessions, time and projects. Blue is fine, orange from 70%, red from 90%."),
    ]
}

private struct TourAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    /// Something the tour can light up.
    func tourAnchor(_ id: String) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [id: $0] }
            .id("tour." + id) // to scroll it into view
    }

    /// The tour over the settings window, while `model.tourStep` is set.
    /// (The overlay's closure runs again only when the anchors move, so the
    /// step is read inside, by a view that watches the model.)
    func settingsTour(model: AppModel, cloud: SettingsCloud) -> some View {
        overlayPreferenceValue(TourAnchorKey.self) { anchors in
            GeometryReader { g in
                TourLayer(model: model, cloud: cloud, rects: anchors.mapValues { g[$0] }, size: g.size)
            }
        }
    }
}

/// The tour at its stop, or nothing.
struct TourLayer: View {
    @ObservedObject var model: AppModel
    let cloud: SettingsCloud
    let rects: [String: CGRect]
    let size: CGSize

    var body: some View {
        if let step = model.tourStep, SettingsTour.stops.indices.contains(step) {
            let stop = SettingsTour.stops[step]
            TourOverlay(model: model, cloud: cloud, step: step,
                        target: rects[stop.anchor] ?? stop.fallback.flatMap { rects[$0] }, size: size)
        }
    }
}

/// The dimming with its spotlight, the blue ring, the card.
struct TourOverlay: View {
    @ObservedObject var model: AppModel
    let cloud: SettingsCloud
    let step: Int
    let target: CGRect?
    let size: CGSize
    @Environment(\.grayButtons) private var gray
    @AppStorage("settings.more.widget") private var widgetMore = false
    @State private var spot: CGRect = .zero
    @State private var tried = false
    @State private var startConfig: Config?
    @State private var ring = false
    /// The stop already scrolled into view.
    @State private var revealed: Int?

    private var stop: TourStop { SettingsTour.stops[step] }
    private var last: Bool { step == SettingsTour.stops.count - 1 }
    private var accent: Color { gray ? Color(hex: 0x6E6E73) : Color(hex: 0x0A64D0) }
    private var ringColor: Color { gray ? Color(hex: 0x98989D) : Color(hex: 0x0A84FF) }

    static let cardWidth: CGFloat = 284

    var body: some View {
        let s = spot.insetBy(dx: -4, dy: -4)
        // Roughly: the lines of text it holds.
        let lines = CGFloat((stop.text.count + 41) / 42)
        let cardHeight: CGFloat = 112 + lines * 18 + (stop.tryText == nil ? 0 : 22)
        let below = s.maxY + 14 + cardHeight <= size.height - 8
        let x = min(max(16, s.midX - Self.cardWidth / 2), size.width - Self.cardWidth - 16)
        let y = below ? s.maxY + 14 : max(8, s.minY - 14 - cardHeight)
        ZStack(alignment: .topLeading) {
            // The dimming, a hole where the spotlight is. A click in the hole
            // goes through (to try the switch); elsewhere it stops.
            Spotlight(rect: s)
                .fill(Color(red: 8 / 255, green: 8 / 255, blue: 10 / 255).opacity(0.68), style: FillStyle(eoFill: true))
                .contentShape(Spotlight(rect: s), eoFill: true)
                .onTapGesture {}
            // The blue ring, its glow spreading and fading.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(ringColor, lineWidth: 2)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(ringColor.opacity(ring ? 0 : 0.55), lineWidth: ring ? 24 : 2))
                .frame(width: s.width, height: s.height)
                .offset(x: s.minX, y: s.minY)
                .allowsHitTesting(false)
            card
                .frame(width: Self.cardWidth)
                .offset(x: x, y: y)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(.timingCurve(0.34, 1.22, 0.64, 1, duration: 0.62), value: spot)
        .onAppear {
            startConfig = model.config
            cloud.touring = true
            arrive(target)
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { ring = true }
        }
        .onDisappear { cloud.touring = false; cloud.goHome() }
        .onChange(of: target) { arrive($0) }
        .onChange(of: step) { _ in
            tried = false
            startConfig = model.config
        }
        .onChange(of: model.config) { config in
            guard stop.tried == .notch, !tried, let start = startConfig,
                  config.widgetAtNotch != start.widgetAtNotch else { return }
            didTry()
        }
        .onChange(of: widgetMore) { open in
            if open, stop.tried == .more, !tried { didTry() }
        }
    }

    /// The white card: which stop, what it is, what to try, and the way on.
    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("\(step + 1) OF \(SettingsTour.stops.count)")
                        .font(.system(size: 11, weight: .semibold)).tracking(0.5)
                        .foregroundColor(accent)
                    Spacer(minLength: 0)
                    if tried {
                        Text("Nice!").font(.system(size: 11, weight: .bold)).foregroundColor(Color(hex: 0x1D7A3A))
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                Text(stop.title).font(.system(size: 15, weight: .semibold)).foregroundColor(Color(hex: 0x1C1C1E))
                Text(stop.text).font(.system(size: 12)).foregroundColor(Color(hex: 0x48484A)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                if let t = stop.tryText {
                    Text(t).font(.system(size: 12, weight: .semibold)).foregroundColor(accent)
                }
            }
            .id(step)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)).combined(with: .scale(scale: 0.97)),
                                    removal: .opacity))
            HStack(spacing: 6) {
                HStack(spacing: 3) {
                    ForEach(SettingsTour.stops.indices, id: \.self) { i in
                        Capsule().fill(i <= step ? accent : Color(hex: 0xD1D1D6))
                            .frame(width: i == step ? 12 : 4, height: 4)
                    }
                }
                Spacer(minLength: 2)
                Button("Skip") { go(SettingsTour.stops.count) }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(Color(hex: 0x6E6E73))
                    .fixedSize()
                    .keyboardShortcut(.cancelAction)
                if step > 0 {
                    Button("Back") { go(step - 1) }
                        .buttonStyle(CardButtonStyle(fill: .white, text: Color(hex: 0x1C1C1E), border: true))
                        .fixedSize()
                }
                Button(last ? "Done" : "Next") { go(step + 1) }
                    .buttonStyle(CardButtonStyle(fill: accent, text: .white))
                    .fixedSize()
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
            .animation(.spring(response: 0.32, dampingFraction: 0.6), value: step)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white)
            .shadow(color: .black.opacity(0.45), radius: 20, y: 16))
        .environment(\.colorScheme, .light)
        .animation(.easeOut(duration: 0.36), value: step)
    }

    /// The stop's target is drawn: the spotlight slides there, Cloud hops on.
    private func arrive(_ rect: CGRect?) {
        guard let rect, rect != .zero else { return }
        // Below or above what shows (Stats grows as it loads): scroll to it, once.
        let inHeader = ["cloud", "tabs", "help"].contains(stop.anchor)
        if !inHeader, revealed != step, rect.maxY > size.height - 10 || rect.minY < 60 {
            revealed = step
            cloud.reveal?(stop.anchor)
        }
        if spot == .zero {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { spot = rect }
        } else {
            spot = rect
        }
        // Its own seat: it waves from there; anything else, it hops onto.
        if stop.anchor == "cloud" { cloud.goHome(hop: true); cloud.cheer(times: 1) } else { cloud.visit(rect) }
    }

    /// Tried it: "Nice!", a cheer, and on.
    private func didTry() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.56)) { tried = true }
        cloud.cheer(times: 2)
        let at = step
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { if model.tourStep == at { go(at + 1) } }
    }

    private func go(_ next: Int) {
        guard next >= 0 else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            model.tourStep = next < SettingsTour.stops.count ? next : nil
        }
    }
}

struct CardButtonStyle: ButtonStyle {
    let fill: Color
    let text: Color
    var border = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: border ? .regular : .semibold))
            .foregroundColor(text)
            .padding(.horizontal, border ? 10 : 12)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(fill.opacity(configuration.isPressed ? 0.75 : 1)))
            .overlay(border ? RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.black.opacity(0.16), lineWidth: 0.5) : nil)
            .contentShape(Rectangle())
    }
}

/// The whole window, less a rounded hole.
private struct Spotlight: Shape {
    var rect: CGRect

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(rect.minX, rect.minY), AnimatablePair(rect.width, rect.height)) }
        set { rect = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }

    func path(in r: CGRect) -> Path {
        var p = Path(r)
        p.addRoundedRect(in: rect, cornerSize: CGSize(width: 12, height: 12), style: .continuous)
        return p
    }
}
