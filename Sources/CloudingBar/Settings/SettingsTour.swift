import SwiftUI

/// The tour (owner's request, 20.10: the Spotlight direction of the
/// design canvas), right in the settings window. Everything dims but one
/// thing, ringed in blue; a white card by it says what it is; Cloud hops onto
/// it. Rewritten 30.10 (owner: there's a lot in Settings, explain it properly):
/// five stops, one for each tab, and on each what's inside it and what it does.
struct TourStop {
    /// One thing inside the tab: its name there, and what it does.
    struct Point {
        let name: String
        let text: String
        /// Only on a Mac that has it (VS Code, Codex): looked at as the tour starts.
        var only: (() -> Bool)? = nil
    }

    let tab: String
    /// The `tourAnchor` it lights up.
    let anchor: String
    let title: String
    let text: String
    var points: [Point] = []
    /// "Try it: …", and what counts as tried.
    var tryText: String? = nil
    var tried: Tried? = nil
    /// Lit up when `anchor` isn't there (the notch switch, with the widget off).
    var fallback: String? = nil
    /// The General group the anchor sits in: opened for the stop (groups
    /// are folded, owner, 27.10).
    var group: String? = nil

    enum Tried { case notch, more }
}

enum SettingsTour {
    /// This tour's stops, fixed as it starts (`begin`): nothing comes or goes midway.
    private(set) static var stops: [TourStop] = all

    /// The stops for this Mac, before the first one shows.
    static func begin() {
        stops = all.map { stop in
            var s = stop
            s.points = stop.points.filter { $0.only?() ?? true }
            return s
        }
    }

    static let all: [TourStop] = [
        TourStop(tab: "general", anchor: "tabs", title: "General: connect it, and how it behaves",
                 text: "Clouding Bar follows the chat in front and shows its limit and context. Here you connect what it reads from.",
                 points: [
                    .init(name: "Claude Code", text: "Connect, once, for Terminal and VS Code: chats, permission requests and the 5-hour limit come here. Your settings.json is backed up first."),
                    .init(name: "VS Code", text: "Claude's panel there doesn't pass the limit on. Set Up adds a small wrapper: the limit comes, and the widget's messages go straight into the chat, no window switched. For chats opened after it.", only: { Setup.hasVSCode }),
                    .init(name: "claude.ai", text: "Optional. Sign In for Cowork tasks, your chats of the last half hour and the whole account's limit. The key stays in Keychain. It goes against Anthropic's terms for third-party apps: at your own risk."),
                    .init(name: "Accessibility", text: "Lets the bar's buttons type into your chats, and find the chat in front and Claude Desktop's questions. Shows On or Off; Open Settings takes you to it."),
                    .init(name: "Codex", text: "Its chats, limits and context show by themselves, read from its own files. Connect adds hooks for permission requests: Codex asks you to trust them once.", only: { Setup.hasCodex }),
                    .init(name: "Context", text: "The bar turns red and offers /compact when a chat fills up, at the share you pick. Compact by itself types it for you, when Claude is idle and its chat is in front."),
                    .init(name: "App", text: "Open at login. Do not disturb: requests wait quietly. Voice language: hold the right ⌥ key alone to dictate; Check before sending lets you edit the words first. Under More: appearance, short chat names, colours, updates."),
                 ],
                 group: "Claude"),
        TourStop(tab: "widget", anchor: "widget.preview", title: "Widget: the pill over your windows",
                 text: "The chat, its limit and context. Click the pill for the panel: chats as tabs, a message line, screenshot, mic, your buttons.",
                 points: [
                    .init(name: "Arrange", text: "Here, and only here: drag an item onto another to swap them, an item's right edge to size it. Pill, Panel and Notch each have their own."),
                    .init(name: "Size", text: "Pull the outline, here or on the widget. Taller than wide, it stands up as a column. Pulled all the way, it shows everything."),
                    .init(name: "Place", text: "Drag the pill anywhere, on any screen: it stays there, and goes back when that monitor returns. Position → Reset brings it home."),
                    .init(name: "In the notch", text: "Around the camera, or a drawn notch on a Mac without one. Drag it out to move it, back in to dock."),
                    .init(name: "What it shows", text: "Numbers, details and controls: what's on is on the pill. Chat sends to the chat the widget shows, once Claude is free."),
                    .init(name: "Under More", text: "Follow the chat at work. Tell when another chat is done: Cloud pops out and says which. Start of the answer: how the reply begins. Keep the pill visible: off, a thin line until you hover it."),
                 ]),
        TourStop(tab: "touchbar", anchor: "touchbar.preview", title: "Touch Bar: Claude under your fingers",
                 text: "Only on a Mac with a Touch Bar. Without one, nothing here is needed.",
                 points: [
                    .init(name: "Arrange", text: "Drag a block to move it, pull its edge to size it. The chips below switch blocks on and off, for the whole bar and the short one."),
                    .init(name: "What it does", text: "Tap the chat's name to switch chats. Write sends Claude a message, typed or dictated. Commands has all your buttons, the model switches it, the subagents show who's working."),
                    .init(name: "Questions", text: "Claude's questions and permission requests always show here: answer with a tap."),
                    .init(name: "In every app", text: "Not only while Claude Code, VS Code or Claude is in front."),
                    .init(name: "Outside Claude", text: "Short: what you keep on it, beside Apple's brightness and volume. Whole: the full bar, with those hidden."),
                 ]),
        TourStop(tab: "buttons", anchor: "buttons.list", title: "Buttons: what you send over and over",
                 text: "On the Touch Bar and in the panel. Click one in the list to change it.",
                 points: [
                    .init(name: "Kinds", text: "A phrase, a /command, a key or a link. A tap sends it to the chat you're in; a text button puts words in for you to finish."),
                    .init(name: "Commands", text: "In the widget, on the Touch Bar and in the menu bar, it lists them all. A button kept only in Commands stays out of the row."),
                    .init(name: "Filled in", text: "In a phrase or a text, {project}, {branch}, {clipboard} and {date} become what they say."),
                    .init(name: "Hotkey", text: "A button can have its own key combination."),
                    .init(name: "Profile", text: "A set of buttons for one project: change one under its name to give it its own; until then it uses the default."),
                 ]),
        TourStop(tab: "stats", anchor: "stats.limits", title: "Stats: where your limit and time went",
                 text: "Read from your sessions on this Mac. This tour is here again behind ?.",
                 points: [
                    .init(name: "Limits", text: "The 5-hour and weekly limits, as Claude Code reports them, and how they moved."),
                    .init(name: "Your Claude", text: "Sessions, active time, tokens and your streak, day by day. Both, Code or Cowork; week, month or all."),
                    .init(name: "Where the time went", text: "The projects Claude worked on. More has the week hour by hour, the models and the tools."),
                 ]),
    ]
}

private struct TourCardHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct TourPointsHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
    @AppStorage("settings.more.app") private var appMore = false
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

    static let cardWidth: CGFloat = 448
    /// The card and what's listed in it, as drawn.
    @State private var cardHeight: CGFloat = 300
    @State private var pointsHeight: CGFloat = 0
    /// Over the list: the stop's number, title, line and buttons.
    private let cardChrome: CGFloat = 150

    var body: some View {
        let s = spot.insetBy(dx: -4, dy: -4)
        let below = s.maxY + 14 + cardHeight <= size.height - 8
        let above = s.minY - 14 - cardHeight >= 8
        let x = min(max(16, s.midX - Self.cardWidth / 2), size.width - Self.cardWidth - 16)
        // Under or over what it lights up; with no room for either (the
        // window can be short), at the window's foot.
        let y = below ? s.maxY + 14 : above ? s.minY - 14 - cardHeight : max(8, size.height - cardHeight - 8)
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
                .background(GeometryReader { Color.clear.preference(key: TourCardHeight.self, value: $0.size.height) })
                .onPreferenceChange(TourCardHeight.self) { cardHeight = $0 }
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
        .onChange(of: appMore) { open in
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
                if !stop.points.isEmpty {
                    // A short window scrolls the list; the buttons stay.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(stop.points, id: \.name) { point in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(point.name).font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: 0x1C1C1E))
                                    Text(point.text).font(.system(size: 12)).foregroundColor(Color(hex: 0x48484A)).lineSpacing(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .background(GeometryReader { Color.clear.preference(key: TourPointsHeight.self, value: $0.size.height) })
                    }
                    .onPreferenceChange(TourPointsHeight.self) { pointsHeight = $0 }
                    .frame(height: min(pointsHeight, max(120, size.height - 16 - cardChrome)))
                }
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
