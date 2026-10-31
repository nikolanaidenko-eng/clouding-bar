import SwiftUI

/// The tour (owner's request, 20.10: the Spotlight direction of the
/// design canvas), right in the settings window. Everything dims but one
/// thing, ringed in blue; a white card by it says what it is; Cloud hops onto
/// it. Five stops, one for each tab; within a stop, one small block for each
/// setting, lit up where it is (owner, 31.10: not a list on one card).
struct TourStop {
    let tab: String
    /// The `tourAnchor` it lights up.
    let anchor: String
    let title: String
    let text: String
    /// Lit up when `anchor` isn't there (the notch switch, with the widget off).
    var fallback: String? = nil
    /// The General group the anchor sits in: opened for the block (groups
    /// are folded, owner, 27.10).
    var group: String? = nil
    /// Only on a Mac that has it (VS Code, Codex): looked at as the tour starts.
    var only: (() -> Bool)? = nil

    /// Where it is, set as the tour starts: which tab of the five, which block of its.
    var section = 0
    var sectionName = ""
    /// What the tab is for: on its first block.
    var summary: String? = nil
    var block = 0
    var blocks = 1
}

enum SettingsTour {
    struct Section {
        let tab: String
        let name: String
        let summary: String
        let blocks: [TourStop]
    }

    /// This tour's blocks in order, fixed as it starts (`begin`): nothing comes or goes midway.
    private(set) static var stops: [TourStop] = lay(all)

    /// The blocks for this Mac, before the first one shows.
    static func begin() { stops = lay(all) }

    private static func lay(_ sections: [Section]) -> [TourStop] {
        sections.enumerated().flatMap { index, section -> [TourStop] in
            let blocks = section.blocks.filter { $0.only?() ?? true }
            return blocks.enumerated().map { i, block in
                var s = block
                s.section = index
                s.sectionName = section.name
                s.summary = i == 0 ? section.summary : nil
                s.block = i
                s.blocks = blocks.count
                return s
            }
        }
    }

    private static func general(_ anchor: String, _ title: String, _ text: String, group: String, only: (() -> Bool)? = nil) -> TourStop {
        TourStop(tab: "general", anchor: anchor, title: title, text: text, fallback: "hooks", group: group, only: only)
    }

    private static func widget(_ anchor: String, _ title: String, _ text: String, fallback: String? = "widget.preview") -> TourStop {
        TourStop(tab: "widget", anchor: anchor, title: title, text: text, fallback: fallback)
    }

    private static func touchBar(_ anchor: String, _ title: String, _ text: String, fallback: String? = "touchbar.preview") -> TourStop {
        TourStop(tab: "touchbar", anchor: anchor, title: title, text: text, fallback: fallback)
    }

    private static func buttons(_ anchor: String, _ title: String, _ text: String) -> TourStop {
        TourStop(tab: "buttons", anchor: anchor, title: title, text: text, fallback: "buttons.list")
    }

    private static func stats(_ anchor: String, _ title: String, _ text: String) -> TourStop {
        TourStop(tab: "stats", anchor: anchor, title: title, text: text, fallback: "stats.limits")
    }

    static let all: [Section] = [
        Section(tab: "general", name: "General", summary: "What Clouding Bar reads from, and how it behaves.", blocks: [
            general("hooks", "Claude Code", "Connect once, for Terminal and VS Code. Chats, permission requests and the 5-hour limit then come here. Your settings are backed up first.", group: "Claude"),
            general("vscode", "VS Code", "Set Up adds a small wrapper: the limit comes, and the widget's messages go straight into the chat. For chats opened after it.", group: "Claude", only: { Setup.hasVSCode }),
            general("claudeai", "claude.ai", "Optional. Sign In for Cowork tasks on claude.ai, your recent chats and the whole account's limit. It goes against Anthropic's terms for third-party apps: at your own risk.", group: "Claude"),
            general("general.localcowork", "Cowork on this Mac", "These tasks show by themselves. Claude Desktop has no way in from outside, so words go through its window, which has to be open, with Accessibility on. The bar switches it to the right task when you aren't using it. Closed, they wait. A screenshot brings Desktop to the front. The bar answers questions only for the task the window shows.", group: "Claude"),
            general("general.accessibility", "Accessibility", "Lets the bar's buttons type into your chats, and find Claude Desktop's questions. Open Settings takes you to the switch.", group: "Claude"),
            general("codex", "Codex", "Its chats, limits and context show by themselves. Connect adds hooks for permission requests: Codex asks you to trust them once.", group: "Codex", only: { Setup.hasCodex }),
            general("general.context", "Context", "The bar turns red and offers /compact when a chat fills up, at the share you pick.", group: "Context"),
            general("general.app", "Login and quiet", "Open at login. Do not disturb keeps requests waiting quietly: nothing pops open.", group: "App"),
            general("general.voice", "Voice", "Hold the right ⌥ key alone, or use the mic, and speak in the language set here.", group: "App"),
            general("app.more", "Under More…", "Appearance, short chat names, colours, updates, problem reports. Every box here keeps its rarer settings behind More….", group: "App"),
        ]),
        Section(tab: "widget", name: "Widget", summary: "The pill over your windows: the chat, its limit and context.", blocks: [
            widget("widget.preview", "Arrange it", "Here, and only here: drag an item onto another to swap them, an item's right edge to size it. Pill, Panel and Notch each have their own.", fallback: nil),
            widget("widget.preview", "Resize it", "Pull the outline, here or on the widget itself. Taller than wide, it stands up as a column. Pulled all the way, it shows everything.", fallback: nil),
            widget("widget.show", "Show the widget", "Click the pill for the panel: chats as tabs, a message line, screenshot, mic, your buttons."),
            widget("widget.notch", "In the notch", "Around the camera, or a drawn notch on a Mac without one. Drag it out to move it, back in to dock.", fallback: "widget.show"),
            widget("widget.position", "Place it", "Drag the pill anywhere, on any screen: it stays, and goes back when that monitor returns. Reset brings it home.", fallback: "widget.show"),
            widget("widget.more", "Under More…", "Follow the chat at work, tell when another is done, the start of the answer, and whether the pill stays visible.", fallback: "widget.show"),
            widget("widget.shows", "What it shows", "Numbers, details and controls: what's on is on the pill. Chat sends to the chat the widget shows, once Claude is free.", fallback: "widget.show"),
        ]),
        Section(tab: "touchbar", name: "Touch Bar", summary: "Only on a Mac with a Touch Bar. Without one, nothing here is needed.", blocks: [
            touchBar("touchbar.preview", "Arrange it", "Drag a block to move it, pull its edge to size it.", fallback: nil),
            touchBar("touchbar.chips", "What's on it", "These chips switch blocks on and off, for the whole bar and for the short one."),
            touchBar("touchbar.more", "In every app", "Under More…: not only while Claude's apps are in front. Outside them, the short bar beside Apple's keys, or the whole bar.", fallback: "touchbar.chips"),
            touchBar("touchbar.note", "Using it", "Tap the chat's name to switch chats. Write sends a message, typed or dictated. Questions and permission requests always show: answer with a tap."),
        ]),
        Section(tab: "buttons", name: "Buttons", summary: "What you send over and over: on the Touch Bar and in the panel.", blocks: [
            TourStop(tab: "buttons", anchor: "buttons.list", title: "Your buttons", text: "Click one to change it, + adds one. A phrase, a /command, a key or a link: a tap sends it to the chat you're in. A text button puts words in for you to finish."),
            TourStop(tab: "buttons", anchor: "buttons.list", title: "Filled in, and hotkeys", text: "In a phrase or a text, {project}, {branch}, {clipboard} and {date} become what they say. A button can also have its own key combination."),
            buttons("buttons.commands", "Commands", "In the widget, on the Touch Bar and in the menu bar, it lists them all. A button kept only in Commands stays out of the row."),
            buttons("buttons.profile", "Profile", "A set of buttons for one project: change one under its name to give it its own. Until then it uses the default."),
        ]),
        Section(tab: "stats", name: "Stats", summary: "Where your limit and time went, read from your sessions on this Mac.", blocks: [
            TourStop(tab: "stats", anchor: "stats.limits", title: "Limits", text: "The 5-hour and weekly limits, as Claude Code reports them, and how they moved."),
            stats("stats.map", "Your Claude", "Sessions, active time, tokens and your streak, day by day. Both, Code or Cowork; week, month or all."),
            stats("stats.time", "Where the time went", "The projects Claude worked on. More has the week hour by hour, the models and the tools. This tour is here again behind ?."),
        ]),
    ]
}

private struct TourCardHeight: PreferenceKey {
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
        // Added to what's inside, not over it: a block inside a block keeps its own.
        transformAnchorPreference(key: TourAnchorKey.self, value: .bounds) { $0[id] = $1 }
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
    @State private var spot: CGRect = .zero
    @State private var ring = false
    /// The stop already scrolled into view.
    @State private var revealed: Int?

    private var stop: TourStop { SettingsTour.stops[step] }
    private var last: Bool { step == SettingsTour.stops.count - 1 }
    private var accent: Color { gray ? Color(hex: 0x6E6E73) : Color(hex: 0x0A64D0) }
    private var ringColor: Color { gray ? Color(hex: 0x98989D) : Color(hex: 0x0A84FF) }

    static let cardWidth: CGFloat = 340
    /// The card, as drawn.
    @State private var cardHeight: CGFloat = 170

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
            cloud.touring = true
            arrive(target)
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { ring = true }
        }
        .onDisappear { cloud.touring = false; cloud.goHome() }
        .onChange(of: target) { arrive($0) }
    }

    /// The white card: which tab and block, what it is, and the way on.
    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                Text("\(stop.sectionName.uppercased()) · \(stop.block + 1) OF \(stop.blocks)")
                    .font(.system(size: 11, weight: .semibold)).tracking(0.5)
                    .foregroundColor(accent)
                if let summary = stop.summary {
                    Text(summary).font(.system(size: 12)).foregroundColor(Color(hex: 0x6E6E73)).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(stop.title).font(.system(size: 15, weight: .semibold)).foregroundColor(Color(hex: 0x1C1C1E))
                Text(stop.text).font(.system(size: 12)).foregroundColor(Color(hex: 0x48484A)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .id(step)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)).combined(with: .scale(scale: 0.97)),
                                    removal: .opacity))
            HStack(spacing: 6) {
                // The five tabs; the one you're in fills as its blocks go by.
                HStack(spacing: 3) {
                    ForEach(0..<SettingsTour.all.count, id: \.self) { i in
                        let wide: CGFloat = i == stop.section ? 26 : 8
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color(hex: 0xD1D1D6))
                            Capsule().fill(accent)
                                .frame(width: i < stop.section ? wide : i == stop.section ? wide * CGFloat(stop.block + 1) / CGFloat(stop.blocks) : 0)
                        }
                        .frame(width: wide, height: 4)
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
