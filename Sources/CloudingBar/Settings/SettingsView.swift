import SwiftUI

/// The settings window (600×560), one tab per place things show up:
/// General (the app, context, voice), Widget (the pill and the panel),
/// Touch Bar, Buttons (and templates), Cowork, Stats. Each section shows
/// what most people need; the rest waits behind "More", and what only
/// matters once something is on shows up when it is (owner's request,
/// 20.10). Light or dark, as the system or General → Appearance says.
///
/// Cloud lives here (SettingsCloud): it sits in the corner while the
/// pointer rests, hops from floor to floor of a tab — by the rows — as it
/// moves, and walks along the tabs, pressing the one you pick.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var tab: String
    @StateObject private var cloud = SettingsCloud()

    static let tabs: [(id: String, label: String, tint: UInt32)] = [
        ("general", "General", 0x8E8E93), ("widget", "Widget", 0x0A84FF), ("touchbar", "Touch Bar", 0xBF5AF2),
        ("buttons", "Buttons", 0xFF9F0A), ("cowork", "Cowork", 0xFF375F), ("stats", "Stats", 0x30D158)]
    static let width: CGFloat = 600

    init(model: AppModel, tab: String = "general") {
        self.model = model
        _tab = State(initialValue: tab)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                header
                ScrollViewReader { scroller in
                ScrollView {
                    Group {
                        switch tab {
                        case "general": GeneralTab(model: model)
                        case "widget": WidgetTab(model: model)
                        case "touchbar": TouchBarTab(model: model)
                        case "buttons": ButtonsTab(model: model)
                        case "cowork": CoworkTab(model: model, mood: cloud.mood)
                        default: StatsTab(model: model)
                        }
                    }
                    .padding(.leading, SettingsCloud.gutter).padding(.trailing, 18).padding(.vertical, 18)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
                .onAppear {
                    cloud.reveal = { id in
                        withAnimation(.easeInOut(duration: 0.4)) { scroller.scrollTo("tour." + id, anchor: .center) }
                    }
                }
                // The tour's stop in view, once its tab is drawn.
                .onChange(of: model.tourStep) { step in
                    guard let step, SettingsTour.stops.indices.contains(step) else { return }
                    let id = "tour." + SettingsTour.stops[step].anchor
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation(.easeInOut(duration: 0.4)) { scroller.scrollTo(id, anchor: .center) }
                    }
                }
                }
            }
            .settingsTour(model: model, cloud: cloud)
            CloudActor(cloud: cloud)
        }
        .coordinateSpace(name: SettingsCloud.space)
        .environment(\.settingsCloud, cloud)
        .environment(\.grayButtons, model.config.buttonColors == "gray")
        .foregroundColor(.sText)
        .frame(width: Self.width, height: 560)
        .background(Color.sBackground)
        .onAppear {
            cloud.start()
            if let step = model.tourStep { tab = SettingsTour.stops[step].tab }
            if let request = model.settingsTabRequest {
                tab = request
                model.settingsTabRequest = nil
            }
        }
        // Asked to show a tab (an achievement's bubble: Widget).
        .onChange(of: model.settingsTabRequest) { request in
            guard let request else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { tab = request }
            model.settingsTabRequest = nil
        }
        // The tour takes you from tab to tab.
        .onChange(of: model.tourStep) { step in
            guard let step, SettingsTour.stops.indices.contains(step), tab != SettingsTour.stops[step].tab else { return }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { tab = SettingsTour.stops[step].tab }
        }
        .onDisappear { cloud.stop() }
        // Every change gets a cheer.
        .onChange(of: model.config) { _ in cloud.cheer() }
    }

    /// Cloud's corner, the tabs (each with its colour when picked), the tour.
    private var header: some View {
        HStack(spacing: 10) {
            // Cloud's seat: it sits here while the pointer rests.
            Color.clear.frame(width: 32, height: 32)
                .contentShape(Rectangle())
                .onTapGesture { cloud.mood.pokes += 1 }
                .help("Clouding Bar")
                .tourAnchor("cloud")
            Spacer()
            HStack(spacing: 2) {
                ForEach(Self.tabs, id: \.id) { t in
                    let on = tab == t.id
                    CloudButton(byCloud: true, action: {
                        guard tab != t.id else { return }
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { tab = t.id }
                    }) {
                        Text(t.label)
                            .font(.system(size: 12, weight: on ? .semibold : .regular))
                            .foregroundColor(on ? .white : .sText)
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(on ? Color.tint(t.tint, gray: model.config.buttonColors == "gray") : .clear))
                            .contentShape(Rectangle())
                    }
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.sTrack))
            .tourAnchor("tabs")
            Button { model.showTour() } label: {
                Image(systemName: "questionmark").font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Color.sControl))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Take the tour: how everything works")
            .accessibilityLabel("Take the tour")
            .tourAnchor("help")
        }
        // Room on the left for the window's close button.
        .padding(.leading, 40).padding(.trailing, 18).padding(.vertical, 11)
        .overlay(Rectangle().fill(Color.sLine).frame(height: 0.5), alignment: .bottom)
    }
}

/// Where Cloud is in the settings window and where it's going. It sits on
/// its seat in the corner until the pointer moves, then hops — in an arc —
/// to the row the pointer stays on, or onto the tab; 2.2 s of stillness and
/// it hops home. A tab pressed: it jumps onto it, and the tab goes as it
/// lands.
final class SettingsCloud: ObservableObject {
    static let gutter: CGFloat = 32
    static let space = "settings-window"
    /// Its seat in the header, and how big it is there and on the rows.
    static let home = CGPoint(x: 40 + 16, y: 11 + 16)
    static let size: CGFloat = 32
    static let rowScale: CGFloat = 0.62

    let mood = CloudMood()
    /// Scrolls the tab to a `tourAnchor` (set by the settings view).
    var reveal: ((String) -> Void)?
    /// The tour leads: Cloud goes where it points and fidgets there; the
    /// pointer doesn't move it.
    var touring = false {
        didSet {
            fidget?.invalidate()
            fidget = nil
            guard touring else { return }
            idle?.cancel()
            fidget = Timer.scheduledTimer(withTimeInterval: 2.8, repeats: true) { [weak self] _ in
                guard let self, !self.flying else { return }
                self.mood.hops += 1
            }
        }
    }
    private var fidget: Timer?
    /// The hop under way: from, to, how high it arcs; `progress` 0 → 1.
    @Published private(set) var from = SettingsCloud.home
    @Published private(set) var to = SettingsCloud.home
    @Published private(set) var arc: CGFloat = 0
    @Published var progress: CGFloat = 1
    @Published private(set) var scale: CGFloat = 1
    /// Pressing down on a control it landed on.
    @Published private(set) var push: CGFloat = 0

    private var flying = false
    /// Where to go once the hop in the air lands.
    private var next: (point: CGPoint, scale: CGFloat, then: (() -> Void)?)?
    /// The row the pointer is over now, if any, and the choice (a tab, a
    /// chip) it's on.
    private var overRow: CGFloat?
    private var overPerch: CGPoint?
    private var unperch: DispatchWorkItem?
    private var idle: DispatchWorkItem?
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in
            self?.moved()
            return e
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        idle?.cancel()
    }

    /// The tour's stop: onto its top right corner, with a cheer.
    func visit(_ rect: CGRect) {
        let p = CGPoint(x: min(rect.maxX - 16, rect.minX + rect.width * 0.85), y: max(10, rect.minY - 3))
        hop(to: p, scale: Self.rowScale, then: { [weak self] in self?.mood.pokes += 1 })
    }

    /// A few happy jumps.
    func cheer(times: Int) {
        for i in 0..<times {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.45) { [weak self] in self?.mood.pokes += 1 }
        }
    }

    /// Where the pointer is: the top of a choice it's on, else by its row.
    private var target: CGPoint? { overPerch ?? overRow.map { CGPoint(x: Self.gutter / 2, y: $0) } }
    /// Cloud goes where the pointer is only once it stays a moment, so a
    /// pass of the mouse doesn't drag it along.
    private var settle: DispatchWorkItem?
    private var settling = false
    static let rowDwell = 0.3, perchDwell = 0.18, rest = 2.2

    private func follow(after delay: Double) {
        settle?.cancel()
        settling = true
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.settling = false
            guard !self.touring, let p = self.target else { return }
            self.hop(to: p, scale: Self.rowScale)
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The pointer moves: out of the corner if it's over something; a rest later, home.
    func moved() {
        guard !touring else { return }
        if to == Self.home, !flying, !settling, target != nil { follow(after: Self.rowDwell) }
        idle?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.goHome() }
        idle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rest, execute: work)
    }

    /// The pointer is over a row whose middle is at `y`.
    func row(_ y: CGFloat) {
        overRow = y
        guard !touring else { return }
        moved()
        if overPerch == nil { follow(after: Self.rowDwell) }
    }

    /// The pointer is on one of a row of choices (a tab, a chip): Cloud sits
    /// on its top edge, and so walks along them.
    func perch(_ frame: CGRect) {
        guard frame != .zero, !touring else { return }
        overPerch = CGPoint(x: frame.midX, y: max(10, frame.minY - 4))
        moved()
        follow(after: Self.perchDwell)
    }

    /// Off the choice: by its row again, unless the pointer is on the next one.
    func leavePerch() {
        overPerch = nil
        guard !touring else { return }
        follow(after: 0.22)
    }

    /// The pointer left the row at `y`.
    func leftRow(_ y: CGFloat) {
        if overRow == y { overRow = nil }
    }

    func goHome(hop: Bool = false) {
        settle?.cancel()
        settling = false
        if to == Self.home && !flying {
            if hop { mood.hops += 1 }
            return
        }
        self.hop(to: Self.home, scale: 1)
    }

    /// A press on the control at `frame`: Cloud jumps onto it (or, sitting on
    /// it already, jumps up), lands, the control gives a little — `squish` —
    /// and `action` runs.
    func press(_ frame: CGRect, squish: @escaping () -> Void, _ action: @escaping () -> Void) {
        settle?.cancel()
        settling = false
        moved()
        let top = CGPoint(x: frame.midX, y: max(10, frame.minY - 4))
        let land = { [weak self] in
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.07)) { self.push = 3 }
            squish()
            action()
            self.mood.pokes += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { self.push = 0 }
            }
        }
        let already = !flying && hypot(top.x - to.x, top.y - to.y) < 8
        hop(to: top, scale: Self.rowScale, arc: already ? 14 : nil, force: already, then: land)
    }

    func cheer() { mood.pokes += 1 }

    /// `force`: hop even on the spot (a jump up and down, `arc` high).
    private func hop(to point: CGPoint, scale s: CGFloat, arc arcOverride: CGFloat? = nil, force: Bool = false,
                     then: (() -> Void)? = nil) {
        guard !flying else {
            // One hop at a time: this one waits for the landing.
            if let pending = next?.then, then == nil { next = (point, s, pending) } else { next = (point, s, then) }
            return
        }
        let distance = hypot(point.x - to.x, point.y - to.y)
        guard distance > 3 || force else { then?(); return }
        flying = true
        let duration = force ? 0.26 : min(0.5, 0.2 + Double(distance) / 1400)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) {
            from = to
            to = point
            // Up and over: higher for longer hops, a little bob between rows.
            arc = arcOverride ?? min(46, 8 + distance * 0.18)
            progress = 0
        }
        DispatchQueue.main.async {
            withAnimation(.timingCurve(0.35, 0, 0.3, 1, duration: duration)) {
                self.progress = 1
                self.scale = s
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.02) { [weak self] in
            guard let self else { return }
            self.flying = false
            then?()
            if let n = self.next {
                self.next = nil
                self.hop(to: n.point, scale: n.scale, then: n.then)
            }
        }
    }
}

/// Cloud itself, drawn over the window, along its hop's arc.
struct CloudActor: View {
    @ObservedObject var cloud: SettingsCloud

    var body: some View {
        LiveMascot(size: SettingsCloud.size, mood: cloud.mood)
            .frame(width: SettingsCloud.size, height: SettingsCloud.size)
            .scaleEffect(cloud.scale)
            .modifier(HopPath(from: cloud.from, to: cloud.to, arc: cloud.arc, progress: cloud.progress))
            .offset(y: cloud.push)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Along a parabola from `from` to `to`, `arc` high at its top.
struct HopPath: AnimatableModifier {
    let from: CGPoint
    let to: CGPoint
    let arc: CGFloat
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let t = progress
        let x = from.x + (to.x - from.x) * t
        let y = from.y + (to.y - from.y) * t - arc * 4 * t * (1 - t)
        return content.offset(x: x - SettingsCloud.size / 2, y: y - SettingsCloud.size / 2)
    }
}

private struct SettingsCloudKey: EnvironmentKey { static let defaultValue: SettingsCloud? = nil }

extension EnvironmentValues {
    var settingsCloud: SettingsCloud? {
        get { self[SettingsCloudKey.self] }
        set { self[SettingsCloudKey.self] = newValue }
    }
}

/// Tells Cloud which row the pointer is over.
struct BuddyHover: ViewModifier {
    @Environment(\.settingsCloud) private var cloud

    func body(content: Content) -> some View {
        content.background(GeometryReader { g in
            Color.clear.contentShape(Rectangle()).onHover { inside in
                let y = g.frame(in: .named(SettingsCloud.space)).midY
                if inside { cloud?.row(y) } else { cloud?.leftRow(y) }
            }
        })
    }
}

/// A press that goes by way of Cloud.
enum CloudPress {
    /// Runs `action` through Cloud's hop, or at once without Cloud.
    static func run(_ cloud: SettingsCloud?, _ frame: CGRect, squish: @escaping () -> Void = {},
                    _ action: @escaping () -> Void) {
        if let cloud, frame != .zero { cloud.press(frame, squish: squish, action) } else { action() }
    }
}

/// A settings button that gives a little when pressed. The tabs
/// (`byCloud`): Cloud walks along their tops after the pointer and makes
/// the press itself — it jumps onto the tab, lands, and the tab goes. The
/// switches and chips inside a tab Cloud leaves alone (owner's request, 20.10).
struct CloudButton<Label: View>: View {
    var byCloud = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.settingsCloud) private var cloud
    @State private var frame: CGRect = .zero
    /// Cloud landed on it: pressed down a little.
    @State private var squished = false

    var body: some View {
        Button {
            if byCloud { CloudPress.run(cloud, frame, squish: squish, action) } else { squish(); action() }
        } label: {
            label()
                .scaleEffect(x: squished ? 0.96 : 1, y: squished ? 0.86 : 1, anchor: .bottom)
        }
            .buttonStyle(.plain)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { frame = g.frame(in: .named(SettingsCloud.space)) }
                    .onChange(of: g.frame(in: .named(SettingsCloud.space))) { frame = $0 }
            })
            .onHover { inside in
                guard byCloud, let cloud else { return }
                if inside { cloud.perch(frame) } else { cloud.leavePerch() }
            }
    }

    private func squish() {
        withAnimation(.easeOut(duration: 0.07)) { squished = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.45)) { squished = false }
        }
    }
}

/// Rows that wait behind "More" (owner's request, 20.10): the last line of a
/// box opens them, and they stay open next time.
struct MoreRows<Content: View>: View {
    let key: String
    let count: Int
    let content: Content
    @AppStorage private var open: Bool

    init(_ key: String, count: Int, @ViewBuilder content: () -> Content) {
        self.key = key
        self.count = count
        self.content = content()
        _open = AppStorage(wrappedValue: false, "settings.more." + key)
    }

    var body: some View {
        VStack(spacing: 0) {
            if open {
                VStack(spacing: 0) { content }
                    .transition(.opacity.combined(with: .offset(y: -6)))
            }
            CloudButton(action: {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) { open.toggle() }
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(open ? "Less" : "More").font(.system(size: 12))
                    if !open {
                        Text("\(count)").font(.system(size: 10, weight: .semibold).monospacedDigit())
                            .padding(.horizontal, 5).frame(height: 15)
                            .background(Capsule().fill(Color.sControl))
                    }
                    Spacer(minLength: 0)
                }
                .foregroundColor(.sSecondary)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .modifier(BuddyHover())
            .tourAnchor("\(key).more")
            .accessibilityLabel(open ? "Fewer settings" : "\(count) more settings")
        }
        .clipped()
    }
}

/// What Cloud in the settings window is up to.
final class CloudMood: ObservableObject {
    /// A click on it or a change: a happy jump (five quick ones: a spin).
    @Published var pokes = 0
    /// Another tab: a little hop.
    @Published var hops = 0
    /// The key field is open: eyes shut, turned away.
    @Published var shy = false
}

/// Cloud that watches the pointer, dozes off and wakes by itself.
struct LiveMascot: NSViewRepresentable {
    let size: CGFloat
    @ObservedObject var mood: CloudMood

    final class Coordinator { var pokes = 0; var hops = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MascotView {
        context.coordinator.pokes = mood.pokes
        context.coordinator.hops = mood.hops
        let view = MascotView(size: size)
        view.lively = true
        return view
    }

    func updateNSView(_ view: MascotView, context: Context) {
        view.shy = mood.shy
        let c = context.coordinator
        if mood.pokes != c.pokes { c.pokes = mood.pokes; view.poke() }
        if mood.hops != c.hops { c.hops = mood.hops; view.hop() }
    }
}

// MARK: - Pieces

struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.sGroup))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.sLine, lineWidth: 0.5))
    }
}

/// A titled group: a small heading over the rounded box, and a note under it.
struct SettingsSection<Content: View>: View {
    let title: String
    var note = ""
    /// Its little coloured icon, as in System Settings.
    var icon: String? = nil
    var tint: UInt32 = 0x8E8E93
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if let icon { SectionIcon(symbol: icon, tint: tint) }
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundColor(.sSecondary)
            }
            .padding(.leading, icon == nil ? 12 : 4)
            SettingsGroup { content }
            if !note.isEmpty {
                Text(note).font(.system(size: 11)).foregroundColor(.sMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
            }
        }
    }
}

struct SettingsRow<Accessory: View>: View {
    let title: String
    var hint: String = ""
    var divider = true
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13))
                if !hint.isEmpty {
                    Text(hint).font(.system(size: 11)).foregroundColor(.sSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            accessory
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: 46)
        .overlay(divider ? Rectangle().fill(Color.sLine).frame(height: 0.5) : nil, alignment: .bottom)
        .modifier(BuddyHover())
    }
}

/// A few choices side by side; the picked one lit in `tint`.
struct SettingsSegments: View {
    let options: [(id: String, label: String)]
    let selected: String
    var tint: UInt32 = 0x0A84FF
    let pick: (String) -> Void
    @Environment(\.grayButtons) private var gray

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.id) { o in
                let on = o.id == selected
                CloudButton(action: { if !on { pick(o.id) } }) {
                    Text(o.label).font(.system(size: 11, weight: on ? .semibold : .regular))
                        .foregroundColor(on ? .white : .sText)
                        .padding(.horizontal, 9).frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 5).fill(on ? Color.tint(tint, gray: gray) : .clear))
                        .contentShape(Rectangle())
                }
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.sTrack))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
    }
}

/// The 40×24 switch from the mockup.
struct CBSwitch: View {
    let title: String
    @Binding var on: Bool
    @Environment(\.grayButtons) private var gray
    var body: some View {
        CloudButton(action: { withAnimation(.spring(response: 0.28, dampingFraction: 0.62)) { on.toggle() } }) {
            Capsule().fill(on ? (gray ? Color.sGraySwitch : Color(hex: 0x0A84FF)) : Color.sSwitchOff)
                .frame(width: 40, height: 24)
                .overlay(Circle().fill(.white).frame(width: 20, height: 20)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 1)
                    .padding(2), alignment: on ? .trailing : .leading)
        }
        .accessibilityLabel(title)
        .accessibilityValue(on ? "on" : "off")
    }
}

struct CBCheckbox: View {
    let title: String
    var hint = ""
    @Binding var on: Bool
    @Environment(\.grayButtons) private var gray
    var body: some View {
        CloudButton(action: { on.toggle() }) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5).fill(on ? Color.tint(0x0A84FF, gray: gray) : .clear)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(on ? Color.clear : Color.sChipOff, lineWidth: 1))
                    .overlay(Text(on ? "✓" : "").font(.system(size: 12)).foregroundColor(.white))
                    .frame(width: 18, height: 18)
                Text(title).font(.system(size: 12)) + Text(hint.isEmpty ? "" : " \(hint)").font(.system(size: 12)).foregroundColor(.sSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .accessibilityValue(on ? "on" : "off")
    }
}

struct Chip: View {
    let label: String
    let on: Bool
    /// Smaller, for a row of many.
    var small = false
    let action: () -> Void
    @Environment(\.grayButtons) private var gray
    var body: some View {
        CloudButton(action: action) {
            Text(label)
                .font(.system(size: small ? 11 : 12))
                .foregroundColor(on ? .white : .sText)
                .padding(.horizontal, small ? 8 : 10)
                .frame(height: small ? 24 : 26)
                .background(Capsule().fill(on ? Color.tint(0x0A84FF, gray: gray) : .clear))
                .overlay(Capsule().strokeBorder(on ? Color.clear : Color.sChipOff, lineWidth: 1))
                .contentShape(Capsule())
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: on)
        }
        .fixedSize()
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Chips that turn ids in one of the settings' lists on and off.
struct ChipSet: View {
    @ObservedObject var model: AppModel
    /// The config key holding the list.
    let key: String
    let options: [(id: String, label: String)]
    /// Also kept in step: the same ids in another list (cost is both a
    /// number on the pill and a metric in the panel).
    var mirror: String? = nil
    var small = false
    /// A second row starts after this many chips.
    var wrapAfter: Int? = nil

    var body: some View {
        let rows = wrapAfter.map { [Array(options.prefix($0)), Array(options.dropFirst($0))] } ?? [options]
        VStack(alignment: .leading, spacing: small ? 5 : 6) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: small ? 5 : 6) {
                    ForEach(rows[i], id: \.id) { option in
                        Chip(label: option.label, on: list(key).contains(option.id), small: small) { toggle(option.id) }
                    }
                }
            }
        }
    }

    private func list(_ key: String) -> [String] {
        switch key {
        case "pillShows": return model.config.pillShows
        case "metrics": return model.config.metrics
        case "touchBarShows": return model.config.touchBarShows
        default: return []
        }
    }

    private func toggle(_ id: String) {
        let on = !list(key).contains(id)
        for k in [key] + (mirror.map { [$0] } ?? []) {
            var l = list(k).filter { $0 != id }
            if on { l.append(id) }
            if l != list(k) { model.setConfig(k, l) }
        }
    }
}

/// A setting's switch bound to a Bool key.
func settingBinding(_ model: AppModel, _ key: String, _ get: @escaping (Config) -> Bool) -> Binding<Bool> {
    Binding(get: { get(model.config) }, set: { model.setConfig(key, $0) })
}

// MARK: - General

struct GeneralTab: View {
    @ObservedObject var model: AppModel

    private func binding(_ key: String, _ get: @escaping (Config) -> Bool) -> Binding<Bool> {
        settingBinding(model, key, get)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection(title: "App", icon: "gearshape.fill", tint: 0x8E8E93) {
                SettingsRow(title: "Appearance", hint: "Of this window; the widget stays dark") {
                    SettingsSegments(options: [("auto", "Auto"), ("light", "Light"), ("dark", "Dark")],
                                     selected: model.config.appearance, tint: 0x5E5CE6) { model.setConfig("appearance", $0) }
                }
                SettingsRow(title: "Colours", hint: "Grey: buttons, tabs and icons without bright colours") {
                    SettingsSegments(options: [("color", "Colourful"), ("gray", "Grey")],
                                     selected: model.config.buttonColors, tint: 0xFF9F0A) { model.setConfig("buttonColors", $0) }
                }
                SettingsRow(title: "Open at login") {
                    CBSwitch(title: "Open at login", on: Binding(get: { model.openAtLogin }, set: { model.setOpenAtLogin($0) }))
                }
                if model.pluginActive {
                    SettingsRow(title: "Open with Claude", hint: "The plugin opens Clouding Bar when a Claude session starts") {
                        CBSwitch(title: "Open with Claude", on: binding("openWithClaude") { $0.openWithClaude })
                    }
                }
                SettingsRow(title: "Do not disturb", hint: "Requests wait quietly: nothing pops open or pulses",
                            divider: model.updatesPossible) {
                    CBSwitch(title: "Do not disturb", on: binding("doNotDisturb") { $0.doNotDisturb })
                }
                if model.updatesPossible {
                    SettingsRow(title: "Updates",
                                hint: model.updateText + " · GitHub, once a day; nothing about you is sent",
                                divider: false) {
                        HStack(spacing: 10) {
                            if model.updateVersion != nil {
                                Button("Install") { model.installUpdate() }
                            } else {
                                Button("Check Now") { model.checkForUpdates() }
                            }
                            CBSwitch(title: "Check for updates", on: binding("checkUpdates") { $0.checkUpdates })
                        }
                    }
                }
            }

            SettingsSection(title: "Claude Code", icon: "sparkle", tint: 0xD97757) {
                SettingsRow(title: model.pluginActive ? "Plugin and status line" : "Hooks",
                            hint: model.claudeConnected
                                ? (model.pluginActive ? "Claude Code reports here, through Clouding Bar's plugin" : "Claude Code reports here")
                                : model.pluginActive
                                    ? "The plugin is in. Connect adds the status line, for the 5-hour limit (settings.json backed up first)."
                                    : "Not connected yet: Clouding Bar can't see Claude Code. Your settings.json is backed up first.",
                            divider: model.hasCodex || model.hasVSCode || model.setupMessage != nil) {
                    if model.claudeConnected {
                        Label("Connected", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundColor(.sSecondary)
                    } else {
                        Button("Connect") { model.connectClaude() }
                    }
                }
                .tourAnchor("hooks")
                if model.hasCodex {
                    SettingsRow(title: "Codex · beta",
                                hint: model.codexConnected
                                    ? "Beta, little tested · trust the hooks once with /hooks in Codex"
                                    : "Beta, little tested · its own limits and permissions, here too",
                                divider: model.hasVSCode || model.setupMessage != nil) {
                        if model.codexConnected {
                            Label("Connected", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundColor(.sSecondary)
                        } else {
                            Button("Connect") { model.connectCodex() }
                        }
                    }
                }
                if model.hasVSCode {
                    SettingsRow(title: "VS Code: limit and sending",
                                hint: "A small wrapper passes on the 5-hour limit, and takes the widget's messages straight into the chat — no window switched · new chats",
                                divider: model.setupMessage != nil) {
                        if model.vscodeWrapped {
                            Label("On", systemImage: "checkmark.circle.fill").font(.system(size: 12)).foregroundColor(.sSecondary)
                        } else {
                            Button("Set Up") { model.wrapVSCode() }
                        }
                    }
                }
                if let message = model.setupMessage {
                    Text(message).font(.system(size: 11)).foregroundColor(.sSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }

            SettingsSection(title: "Context", icon: "gauge.medium", tint: 0xBF5AF2) {
                SettingsRow(title: "Warn when it fills up", hint: "The bar turns red and offers /compact",
                            divider: model.config.contextWarning) {
                    HStack(spacing: 10) {
                        Picker("", selection: Binding(get: { Int(model.config.contextWarnPercent) },
                                                      set: { model.setConfig("contextWarnPercent", $0) })) {
                            ForEach([60, 70, 80, 90], id: \.self) { Text("at \($0)%").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 90)
                        .disabled(!model.config.contextWarning)
                        .accessibilityLabel("Warn at")
                        CBSwitch(title: "Context warning", on: binding("contextWarning") { $0.contextWarning })
                    }
                }
                if model.config.contextWarning {
                    SettingsRow(title: "Compact by itself",
                                hint: "Types /compact at the warning, when Claude is idle and its chat is in front",
                                divider: false) {
                        CBSwitch(title: "Compact by itself", on: binding("autoCompact") { $0.autoCompact })
                    }
                    .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
            .animation(.spring(response: 0.36, dampingFraction: 0.86), value: model.config.contextWarning)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    SectionIcon(symbol: "mic.fill", tint: 0xFF453A)
                    Text("Voice").font(.system(size: 11, weight: .semibold)).foregroundColor(.sSecondary)
                }
                .padding(.leading, 4)
                VoiceGroup(model: model)
            }
        }
    }
}

/// Dictation language, and whether it works offline on this Mac.
struct VoiceGroup: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsGroup {
            SettingsRow(title: "Check before sending",
                        hint: model.config.voiceReview ? "The words wait in the widget: edit them, then Send"
                            : "Typed into the app in front as you stop") {
                CBSwitch(title: "Check before sending", on: settingBinding(model, "voiceReview") { $0.voiceReview })
            }
            SettingsRow(title: "Language", hint: "Hold the right ⌥ key alone, or use the mic",
                        divider: !model.voiceOffline) {
                Picker("", selection: Binding(get: { model.config.voiceLanguage },
                                              set: { model.setConfig("voiceLanguage", $0) })) {
                    ForEach(VoiceInput.languages, id: \.self) { id in
                        Text(Locale.current.localizedString(forIdentifier: id).map { "\($0) (\(id))" } ?? id).tag(id)
                    }
                }
                .labelsHidden()
                .frame(width: 210)
                .accessibilityLabel("Voice language")
            }
            if !model.voiceOffline {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle").foregroundColor(.cbWarning)
                        Text("This language isn't available offline on this Mac. To use it, your voice is sent to Apple's servers for recognition.")
                            .font(.system(size: 11)).foregroundColor(Color.sText).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    CBCheckbox(title: "Allow sending audio to Apple", on: Binding(
                        get: { model.config.voiceAllowServer }, set: { model.setConfig("voiceAllowServer", $0) }))
                        .padding(.horizontal, -12)
                }
                .padding(12)
            }
        }
    }
}

// MARK: - Widget

struct WidgetTab: View {
    @ObservedObject var model: AppModel

    private func binding(_ key: String, _ get: @escaping (Config) -> Bool) -> Binding<Bool> {
        settingBinding(model, key, get)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            WidgetPreview(model: model)
                .tourAnchor("widget.preview")
            if model.config.achievements.contains("claude-wave") {
                // Unlocked when Claude first waved at Cloud with a ☁️.
                SettingsSection(title: "Cloud", icon: "trophy.fill", tint: 0xFFD60A) {
                    SettingsRow(title: "Cloud's colour", hint: "Unlocked by a wave from Claude ☁️ · in the widget and on the Touch Bar",
                                divider: false) {
                        HStack(spacing: 8) {
                            ForEach(CloudColor.allCases) { c in
                                let picked = model.config.cloudColor == c.rawValue
                                Button { model.setConfig("cloudColor", c.rawValue) } label: {
                                    Circle()
                                        .fill(Color(c.skin))
                                        .frame(width: 20, height: 20)
                                        .overlay(Circle().stroke(Color.accentColor, lineWidth: picked ? 2.5 : 0).padding(-3))
                                        .overlay(Circle().stroke(Color.black.opacity(0.15), lineWidth: 0.5))
                                }
                                .buttonStyle(.plain)
                                .help(c.label)
                                .accessibilityLabel(c.label + (picked ? ", picked" : ""))
                            }
                        }
                        .padding(.trailing, 4)
                    }
                }
            }
            SettingsSection(title: "Floating widget", icon: "capsule.fill", tint: 0x0A84FF) {
                SettingsRow(title: "Show the widget", hint: "A pill over your windows; the panel opens from it",
                            divider: model.config.widget) {
                    CBSwitch(title: "Show the widget", on: binding("widget") { $0.widget })
                }
                .tourAnchor("widget.show")
                if model.config.widget {
                    SettingsRow(title: "In the notch",
                                hint: model.hasNotch ? "Around the camera. Drag it out to move it, back in to dock"
                                    : "A notch is drawn at the top. Drag it out to move it") {
                        CBSwitch(title: "In the notch", on: Binding(
                            get: { model.config.widgetAtNotch && model.config.widgetPosition == nil },
                            set: { on in
                                model.setConfig("widgetAtNotch", on)
                                if on { model.resetWidgetPosition() }
                            }))
                    }
                    .tourAnchor("widget.notch")
                    MoreRows("widget", count: 5) {
                        SettingsRow(title: "Follow the chat at work", hint: "When the one shown is done, it says so, then shows the one still working") {
                            CBSwitch(title: "Follow the chat at work", on: binding("followWorking") { $0.followWorking })
                        }
                        SettingsRow(title: "Tell when another chat is done",
                                    hint: "Cloud pops out and says which; click it to go there. On the Touch Bar too") {
                            CBSwitch(title: "Tell when another chat is done", on: binding("doneAlerts") { $0.doneAlerts })
                        }
                        SettingsRow(title: "Keep the pill visible", hint: "Off: a thin line until you hover it") {
                            CBSwitch(title: "Keep the pill visible", on: binding("pillAlwaysVisible") { $0.pillAlwaysVisible })
                        }
                        SettingsRow(title: "Open on hover", hint: "Off: click the pill to open it") {
                            CBSwitch(title: "Open on hover", on: binding("hoverOpens") { $0.hoverOpens })
                        }
                        SettingsRow(title: "Position",
                                    hint: model.config.widgetPosition != nil ? "Where you dragged it"
                                        : model.config.widgetAtNotch ? "In the notch" : "Top center, under the menu bar") {
                            Button("Reset") { model.resetWidgetPosition() }
                                .disabled(model.config.widgetPosition == nil)
                        }
                    }
                }
            }

            if model.config.widget {
                SettingsSection(title: "What it shows", icon: "eye.fill", tint: 0x30B0C7) {
                    SettingsRow(title: "Numbers") {
                        ToggleChips(items: [hideChip("Session", "session"), listChip("Context", "pillShows", "context"),
                                            listChip("Reset time", "pillShows", "reset"),
                                            listChip("Cost", "pillShows", "cost", mirror: "metrics")])
                    }
                    MoreRows("shows", count: 2) {
                        SettingsRow(title: "Details") {
                            ToggleChips(items: [listChip("Model", "metrics", "model"), listChip("Time", "metrics", "time"),
                                                listChip("Lines", "metrics", "lines"),
                                                listChip("Branch", "metrics", "git"), listChip("Subagents", "metrics", "agents")])
                        }
                        SettingsRow(title: "Controls") {
                            ToggleChips(items: [hideChip("Buttons", "buttons"), boolChip("Chat", "taskQueue") { $0.taskQueue },
                                                hideChip("Menu", "menu"),
                                                boolChip("Screenshot", "screenshot") { $0.screenshot }, hideChip("Mic", "mic")])
                        }
                        Text("Pull the pill's outline to resize it; drag one item onto another to swap them. Chat sends to the chat the widget shows, once Claude is free.")
                            .font(.system(size: 11)).foregroundColor(.sMuted)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .overlay(Rectangle().fill(Color.sLine).frame(height: 0.5), alignment: .bottom)
                    }
                }
                .transition(.opacity.combined(with: .offset(y: -8)))
            }
        }
        .animation(.spring(response: 0.38, dampingFraction: 0.86), value: model.config.widget)
    }

    // MARK: Chips

    private func list(_ key: String) -> [String] {
        switch key {
        case "pillShows": return model.config.pillShows
        case "metrics": return model.config.metrics
        default: return model.config.widgetHides
        }
    }

    /// On while `id` is in the list `key` (and `mirror`, kept in step).
    private func listChip(_ label: String, _ key: String, _ id: String, mirror: String? = nil) -> ToggleChips.Item {
        let on = list(key).contains(id)
        return (label, on, {
            for k in [key] + (mirror.map { [$0] } ?? []) {
                var l = list(k).filter { $0 != id }
                if !on { l.append(id) }
                if l != list(k) { model.setConfig(k, l) }
            }
        })
    }

    /// On unless `id` is in widgetHides (things the widget used to always show).
    private func hideChip(_ label: String, _ id: String) -> ToggleChips.Item {
        let on = !model.config.widgetHides.contains(id)
        return (label, on, {
            var l = model.config.widgetHides.filter { $0 != id }
            if on { l.append(id) }
            model.setConfig("widgetHides", l)
        })
    }

    private func boolChip(_ label: String, _ key: String, _ get: @escaping (Config) -> Bool) -> ToggleChips.Item {
        let on = get(model.config)
        return (label, on, { model.setConfig(key, !on) })
    }
}

/// Chips that each turn one thing on or off.
struct ToggleChips: View {
    typealias Item = (label: String, on: Bool, toggle: () -> Void)
    let items: [Item]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(items.indices, id: \.self) { i in
                Chip(label: items[i].label, on: items[i].on, action: items[i].toggle)
            }
        }
    }
}

// MARK: - Touch Bar

struct TouchBarTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TouchBarEditor(model: model)
                .opacity(model.config.touchBar == "off" ? 0.4 : 1)
                .tourAnchor("touchbar.preview")
            SettingsGroup {
                SettingsRow(title: "Show on Touch Bar",
                            hint: model.touchBarPresent ? "Detected on this Mac" : "No Touch Bar found on this Mac") {
                    CBSwitch(title: "Show on Touch Bar", on: Binding(
                        get: { model.config.touchBar != "off" },
                        set: { model.setConfig("touchBar", $0 ? (model.touchBarPresent ? "auto" : "on") : "off") }))
                }
                if model.config.touchBar != "off" {
                    SettingsRow(title: "In every app",
                                hint: model.config.touchBarEverywhere ? "Not only while Claude Code, VS Code or Claude is in front"
                                    : "Only while Claude Code, VS Code or Claude is in front") {
                        CBSwitch(title: "In every app", on: Binding(
                            get: { model.config.touchBarEverywhere },
                            set: { model.setConfig("touchBarEverywhere", $0) }))
                    }
                    if model.config.touchBarEverywhere {
                        SettingsRow(title: "Outside Claude",
                                    hint: model.config.touchBarOutside == "whole"
                                        ? "The whole Touch Bar, as in Claude's apps; Apple's brightness and volume hidden"
                                        : "Short: the chat and the meters, beside Apple's brightness and volume") {
                            SettingsSegments(options: [("short", "Short bar"), ("whole", "Whole bar")],
                                             selected: model.config.touchBarOutside, tint: 0xBF5AF2) {
                                model.setConfig("touchBarOutside", $0)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("On the bar").font(.system(size: 13))
                    ChipSet(model: model, key: "touchBarShows",
                            options: [("session", "Session"), ("reset", "Reset"), ("context", "Context"),
                                      ("model", "Model"), ("agents", "Agents"), ("lines", "Lines"),
                                      ("branch", "Branch"), ("cost", "Cost"), ("chat", "Write"),
                                      ("templates", "Menu"), ("buttons", "Buttons"),
                                      ("shot", "Screenshot"), ("mic", "Mic")], small: true, wrapAfter: 8)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Claude's questions and permission requests always show. Tap the message field (Write) to send Claude a message, typed or dictated; Templates to type one in; the model to switch it; the subagents to see who's working. Buttons and templates are set up in Buttons.")
                .font(.system(size: 11)).foregroundColor(.sMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
        }
    }
}


/// The Touch Bar itself — drawn by the bar's own code, not a likeness — to
/// arrange as the widget is: drag a block to move it, its right edge to
/// make it wider or narrower; the whole bar and the short one (beside
/// Apple's buttons) each their own way (owner, 24.10).
struct TouchBarEditor: View {
    @ObservedObject var model: AppModel
    @State private var short = false
    @State private var blocks: [(key: String, frame: NSRect)] = []
    /// While dragging: the order and widths as they'd be on letting go.
    @State private var order: [String]?
    @State private var widths: [String: Double]?
    @State private var start: (order: [String], widths: [String: Double], frames: [String: NSRect])?

    private var which: String { short ? "short" : "whole" }
    private var barWidth: CGFloat { short ? BarView.narrowWidth : BarView.preferredWidth }
    /// Fitted to the window: all of it in view (owner, 24.10).
    private var scale: CGFloat { min(1, (SettingsView.width - 64 - 12) / barWidth) }
    private var savedOrder: [String] { model.config.touchBarOrder[which] ?? [] }
    private var savedWidths: [String: Double] { model.config.touchBarWidths[which] ?? [:] }
    private var arranged: Bool { !savedOrder.isEmpty || !savedWidths.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // Which bar to arrange — not which one shows (that's "Outside Claude").
                Text("Arrange").font(.system(size: 12)).foregroundColor(.sSecondary)
                SettingsSegments(options: [("whole", "Whole bar"), ("short", "Short bar")], selected: which, tint: 0x8E8E93) {
                    short = $0 == "short"
                }
                Spacer(minLength: 0)
                if arranged {
                    Button("Reset") { reset() }
                        .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.sSecondary)
                        .help("Back to the bar's own order and widths")
                }
            }
            Group {
                ZStack(alignment: .topLeading) {
                    LiveBar(bar: bar, width: barWidth, scale: scale) { found in
                        if found.map(\.key) != blocks.map(\.key) || found.map(\.frame) != blocks.map(\.frame) { blocks = found }
                    }
                    .frame(width: barWidth * scale, height: Palette.height * scale)
                    ForEach(blocks, id: \.key) { block in handle(block) }
                }
                .frame(width: barWidth * scale, height: Palette.height * scale, alignment: .topLeading)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black))
            }
            Text("Drag a block to move it, its right edge to make it wider or narrower. Double-click a block for its own width again.")
                .font(.system(size: 11)).foregroundColor(.sMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The bar as it is now, with what's being dragged.
    private var bar: BarModel {
        var bar = model.barPreview(short)
        bar.short = short
        if let order { bar.order = order }
        if let widths { bar.widths = widths.mapValues { CGFloat($0) } }
        return bar
    }

    /// One block: its body moves it, its right edge sizes it.
    private func handle(_ block: (key: String, frame: NSRect)) -> some View {
        let x = block.frame.minX * scale, w = block.frame.width * scale, h = Palette.height * scale
        return ZStack(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(start != nil && dragged == block.key ? 0.12 : 0.001))
                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { move(block.key, by: $0.translation.width / scale) }
                    .onEnded { _ in finish() })
                .onTapGesture(count: 2) { resetWidth(block.key) }
            Rectangle().fill(Color.white.opacity(0.35)).frame(width: 2, height: h * 0.5)
                .frame(width: 10, height: h)
                .contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { size(block.key, by: $0.translation.width / scale) }
                    .onEnded { _ in finish() })
        }
        .frame(width: w, height: h)
        .offset(x: x)
        // Its block left the bar mid-drag: the drag ends, it doesn't hang on.
        .onDisappear { if dragged == block.key { finish() } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Touch Bar block: \(block.key)")
    }

    @State private var dragged: String?

    private func begin(_ key: String) {
        guard start == nil else { return }
        dragged = key
        start = (blocks.map(\.key), savedWidths, Dictionary(blocks.map { ($0.key, $0.frame) }, uniquingKeysWith: { a, _ in a }))
    }

    /// Moving: where its middle comes to among the others' middles.
    private func move(_ key: String, by dx: CGFloat) {
        begin(key)
        guard let start, let frame = start.frames[key] else { return }
        let mid = frame.midX + dx
        var rest = start.order.filter { $0 != key }
        let index = rest.firstIndex { (start.frames[$0]?.midX ?? 0) > mid } ?? rest.count
        rest.insert(key, at: index)
        if rest != order { order = rest }
    }

    private func size(_ key: String, by dx: CGFloat) {
        begin(key)
        guard let start, let frame = start.frames[key] else { return }
        var w = start.widths
        // Never past the bar: Cloud, "Whole bar" and a little room stay on it.
        w[key] = Double(min(max(frame.width + dx, 24), barWidth - 120)).rounded()
        if w != widths { widths = w }
    }

    private func finish() {
        if let order {
            var all = model.config.touchBarOrder
            all[which] = order
            model.setConfig("touchBarOrder", all)
        }
        if let widths {
            var all = model.config.touchBarWidths
            all[which] = widths
            model.setConfig("touchBarWidths", all)
        }
        order = nil
        widths = nil
        start = nil
        dragged = nil
    }

    private func resetWidth(_ key: String) {
        var all = model.config.touchBarWidths
        all[which]?[key] = nil
        model.setConfig("touchBarWidths", all)
    }

    private func reset() {
        var o = model.config.touchBarOrder, w = model.config.touchBarWidths
        o[which] = nil
        w[which] = nil
        model.setConfig("touchBarOrder", o)
        model.setConfig("touchBarWidths", w)
    }
}

/// The Touch Bar's own view, live and scaled down, for Settings: what it
/// shows is what the bar shows. Tells where its blocks are.
struct LiveBar: NSViewRepresentable {
    let bar: BarModel
    let width: CGFloat
    let scale: CGFloat
    let blocks: ([(key: String, frame: NSRect)]) -> Void

    /// Shows its bar at full size scaled into its own: whatever frame it's
    /// given, the bar inside keeps its real width.
    final class Holder: NSView {
        var inner = NSSize(width: BarView.preferredWidth, height: Palette.height)
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            setBoundsSize(inner)
        }
        override func layout() {
            super.layout()
            if bounds.size != inner { setBoundsSize(inner) }
            subviews.first?.frame = NSRect(origin: .zero, size: inner)
        }
    }

    func makeNSView(context: Context) -> Holder {
        let holder = Holder(frame: NSRect(x: 0, y: 0, width: width * scale, height: Palette.height * scale))
        holder.wantsLayer = true
        let view = BarView(frame: NSRect(x: 0, y: 0, width: width, height: Palette.height))
        view.onAction = { _ in } // only to look at and arrange here
        holder.addSubview(view)
        return holder
    }

    func updateNSView(_ holder: Holder, context: Context) {
        guard let view = holder.subviews.first as? BarView else { return }
        holder.inner = NSSize(width: width, height: Palette.height)
        holder.setBoundsSize(holder.inner)
        view.frame = NSRect(origin: .zero, size: holder.inner)
        view.update(bar)
        view.layoutSubtreeIfNeeded()
        let found = view.blocks
        DispatchQueue.main.async { blocks(found) }
    }
}

/// The widget itself, live, as it shows now — what's switched on below
/// appears in it at once — scaled to fit, to arrange right here as in the
/// widget: drag an item onto another to swap them, an item's right edge to
/// size it (owner, 24.10). Clicks do nothing here: nothing is sent from it.
struct WidgetPreview: View {
    @ObservedObject var model: AppModel
    @StateObject private var state = WidgetState()
    @State private var panel = false
    @State private var panelSize = CGSize(width: 480, height: 280)

    /// The pill's size as the widget works it out; the panel's, measured.
    private var natural: CGSize {
        panel ? panelSize : PillLayout(model: model).arrange(width: model.pillBudget, height: model.pillHeightBudget).frame
    }

    var body: some View {
        let size = natural
        let room = SettingsView.width - 64 - 24
        let scale = min(1, room / max(size.width, 1), panel ? 300 / max(size.height, 1) : 1)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Arrange").font(.system(size: 12)).foregroundColor(.sSecondary)
                SettingsSegments(options: [("pill", "Pill"), ("panel", "Panel")], selected: panel ? "panel" : "pill",
                                 tint: 0x8E8E93) {
                    panel = $0 == "panel"
                    state.mode = panel ? .panel : .pill
                    measure()
                }
            }
            WidgetView(model: model, state: state)
                .environment(\.colorScheme, .dark)
                .environment(\.cbPreview, true)
                .environment(\.cbScale, scale)
                .environment(\.clickGate, { false })
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: 0x1B1B1D)))
            Text("Drag an item onto another to swap them, an item's right edge to make it wider or narrower — here or in the widget itself. Pull the widget's outline for its whole size.")
                .font(.system(size: 11)).foregroundColor(.sMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { state.mode = panel ? .panel : .pill; measure() }
        .onChange(of: model.config) { _ in measure() }
    }

    private func measure() {
        guard panel else { return }
        let s = WidgetState()
        s.mode = .panel
        let size = NSHostingView(rootView: WidgetView(model: model, state: s).fixedSize()).fittingSize
        if size.width > 0, size.height > 0 { panelSize = size }
    }
}

// MARK: - Buttons

struct ButtonsTab: View {
    @ObservedObject var model: AppModel
    @Environment(\.grayButtons) private var gray
    @State private var profile = ""   // "" = the main list
    @State private var selected: Int?
    @State private var editing = false
    @State private var draftName = ""
    @State private var draftValue = ""
    @State private var draftType: ButtonSpec.Kind = .phrase
    /// The type follows the value until you pick one yourself.
    @State private var typePicked = false
    @State private var draftHotkey: String?
    @State private var draftMenu = false

    private var list: [ButtonSpec] {
        profile.isEmpty ? model.config.effectiveButtons : (model.config.profiles[profile] ?? model.config.effectiveButtons)
    }

    /// The whole bar with the buttons as they're being edited: the row's
    /// in the message line, the menu's behind its button.
    private var previewBar: BarModel {
        var bar = model.barPreview(false)
        let all = list + (editing && selected == nil
            ? [ButtonSpec(label: draftName.isEmpty ? "New" : draftName, type: .phrase, value: "", menu: draftMenu)] : [])
        bar.buttons = all.filter { !$0.menu }
        bar.templates = all.filter(\.menu).map(\.label)
        bar.shows.insert("buttons")
        if !bar.templates.isEmpty { bar.shows.insert("templates") }
        return bar
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Touch Bar · your buttons in the message line, as on the bar").font(.system(size: 11)).foregroundColor(.sSecondary)
                // The whole bar, fitted to the window: here it's only to look at.
                LiveBar(bar: previewBar, width: BarView.preferredWidth, scale: 0.53) { _ in }
                    .frame(width: BarView.preferredWidth * 0.53, height: Palette.height * 0.53)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.black))
            }
            SettingsGroup {
                ForEach(Array(list.enumerated()), id: \.offset) { i, b in
                    Button { startEdit(i) } label: {
                        HStack(spacing: 12) {
                            Text(b.label).font(.system(size: 13)).lineLimit(1).frame(width: 90, alignment: .leading)
                            Text(b.value).font(.system(size: 12)).foregroundColor(.sSecondary).lineLimit(1)
                            Spacer(minLength: 0)
                            Text(b.type.rawValue + (b.menu ? " · in the menu" : "")
                                 + (b.hotkey.map { " · " + HotKeys.display($0) } ?? ""))
                                .font(.system(size: 12)).foregroundColor(.sSecondary)
                        }
                        .padding(.horizontal, 12)
                        .frame(minHeight: 40)
                        .background(selected == i ? Color.tint(0x0A84FF, gray: gray).opacity(0.25) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(Rectangle().fill(Color.sLine).frame(height: 0.5), alignment: .bottom)
                }
                if editing { editor }
                HStack(spacing: 2) {
                    Button("+") { startAdd() }.buttonStyle(.plain).font(.system(size: 17))
                        .frame(width: 36, height: 30).accessibilityLabel("Add button")
                    Button("−") { remove() }.buttonStyle(.plain).font(.system(size: 17)).foregroundColor(.sSecondary)
                        .frame(width: 36, height: 30).accessibilityLabel("Remove button")
                    Spacer()
                    Text("Profile").font(.system(size: 11)).foregroundColor(.sSecondary)
                    Picker("", selection: $profile) {
                        Text("Default").tag("")
                        ForEach(profileChoices, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .accessibilityLabel("Profile")
                }
                .padding(.horizontal, 4).padding(.vertical, 2)
            }
            .tourAnchor("buttons.list")
            Text("In the menu: behind the menu button in the widget and on the Touch Bar, and in the menu bar. In a phrase or a text, {project}, {branch}, {clipboard} and {date} are filled in.")
                .font(.system(size: 11)).foregroundColor(.sSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !profile.isEmpty {
                Text(model.config.profiles[profile] == nil
                     ? "\(profile) uses the default buttons. Change one here to give it its own set."
                     : "Buttons for sessions in \(profile).")
                    .font(.system(size: 11)).foregroundColor(.sSecondary)
            }
        }
        .onChange(of: profile) { _ in editing = false; selected = nil }
    }

    private var editor: some View {
        VStack(spacing: 8) {
        HStack(spacing: 8) {
            TextField("Name", text: $draftName)
                .textFieldStyle(.plain).font(.system(size: 12))
                .padding(.horizontal, 8).frame(width: 110, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.sField))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.sFieldLine, lineWidth: 0.5))
            Picker("", selection: Binding(get: { draftType }, set: { draftType = $0; typePicked = true })) {
                ForEach(ButtonSpec.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().frame(width: 110)
            .accessibilityLabel("Type")
            ShortcutField(combo: $draftHotkey).frame(width: 120, height: 30)
            Picker("", selection: Binding(get: { draftMenu }, set: { menu in
                draftMenu = menu
                // In the menu: words to finish, unless you picked otherwise.
                if !typePicked { draftType = menu ? .text : ButtonSpec.guessType(draftValue) }
            })) {
                Text("In the row").tag(false)
                Text("In the menu").tag(true)
            }
            .labelsHidden().frame(width: 120)
            .accessibilityLabel("Where")
            Spacer(minLength: 0)
        }
        HStack(spacing: 8) {
            TextField(placeholder, text: $draftValue)
                .textFieldStyle(.plain).font(.system(size: 12))
                .padding(.horizontal, 8).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.sField))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.sFieldLine, lineWidth: 0.5))
                .onChange(of: draftValue) { v in
                    guard !typePicked else { return }
                    let guess = ButtonSpec.guessType(v)
                    draftType = draftMenu && guess == .phrase ? .text : guess
                }
            Button(selected == nil ? "Add" : "Save") { commit() }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.white)
                .padding(.horizontal, 12).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.tint(0x0071E3, gray: gray)))
                .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty
                          || (draftValue.isEmpty && draftType != .screenshot))
        }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(Rectangle().fill(Color.sLine).frame(height: 0.5), alignment: .bottom)
        .transition(.opacity.combined(with: .offset(y: 6)))
    }

    private var placeholder: String {
        switch draftType {
        case .phrase: return "Text to send to Claude"
        case .text: return "Text to put in the message, to finish there"
        case .command: return "/command"
        case .key: return "esc, cmd+k, shift+tab…"
        case .link: return "vscode://… or https://…"
        case .screenshot: return "Nothing needed: it picks an area of the screen"
        }
    }

    private var profileChoices: [String] {
        Array(Set(model.knownProjects).union(model.config.profiles.keys)).sorted()
    }

    private func startAdd() {
        selected = nil
        draftName = ""
        draftValue = ""
        draftType = .phrase
        typePicked = false
        draftHotkey = nil
        draftMenu = false
        withAnimation(.easeOut(duration: 0.18)) { editing = true }
    }

    private func startEdit(_ i: Int) {
        selected = i
        draftName = list[i].label
        draftValue = list[i].value
        draftType = list[i].type
        draftHotkey = list[i].hotkey
        draftMenu = list[i].menu
        typePicked = true
        withAnimation(.easeOut(duration: 0.18)) { editing = true }
    }

    private func commit() {
        let spec = ButtonSpec(label: draftName.trimmingCharacters(in: .whitespaces), type: draftType,
                              value: draftValue, hotkey: draftHotkey, menu: draftMenu)
        var buttons = list
        if let i = selected, buttons.indices.contains(i) { buttons[i] = spec } else { buttons.append(spec) }
        save(buttons)
        editing = false
        selected = nil
    }

    private func remove() {
        var buttons = list
        guard !buttons.isEmpty else { return }
        if let i = selected, buttons.indices.contains(i) { buttons.remove(at: i) } else { buttons.removeLast() }
        save(buttons)
        editing = false
        selected = nil
    }

    private func save(_ buttons: [ButtonSpec]) {
        if profile.isEmpty {
            model.setConfig("buttons", buttons.map(\.dictionary))
        } else {
            var profiles = model.config.profiles
            profiles[profile] = buttons
            model.setConfig("profiles", profiles.mapValues { $0.map(\.dictionary) })
        }
    }
}

/// The Touch Bar as it's set up, with this Mac's numbers: the character,
/// then whatever Settings → Touch Bar turns on, in the bar's order. Session
/// and Context share what the rest leaves (3 : 2) and drop their words as
/// room runs out, the same rule as the real bar.
struct TouchBarPreview: View {
    @ObservedObject var model: AppModel
    /// The buttons to show; the Buttons tab passes the list being edited.
    var labels: [String]? = nil
    var highlightLast = false

    private static let pad: CGFloat = 5, gap: CGFloat = 5, character: CGFloat = 36, icon: CGFloat = 30

    var body: some View {
        GeometryReader { geo in bar(width: geo.size.width) }
            .frame(height: 38)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Touch Bar preview: " + Set(model.config.touchBarShows).sorted().joined(separator: ", "))
    }

    private func bar(width: CGFloat) -> some View {
        let shows = Set(model.config.touchBarShows)
        let buttons = shows.contains("buttons")
            ? labels ?? (model.buttons.isEmpty ? model.config.effectiveButtons : model.buttons).map(\.label) : []
        let modelText = shows.contains("model")
            ? ModelChoice.label(model: model.modelName ?? "Opus 5.5 1M", effort: model.modelName == nil ? "xhigh" : model.effort)
            : nil
        let session = shows.contains("session"), context = shows.contains("context")
        let buttonWidths = buttons.map { min(84, Self.text($0, 11) + 16) }
        let modelWidth = modelText.map { min(130, Self.text($0, 10) + 16) } ?? 0
        let agentsText = shows.contains("agents")
            ? (model.agents == 0 ? "No agents" : "\(model.agents) agent\(model.agents == 1 ? "" : "s")") : nil
        let agentsWidth = agentsText.map { Self.text($0, 10) + 16 } ?? 0
        let icons = [shows.contains("shot") ? "camera.viewfinder" : nil, shows.contains("mic") ? "mic" : nil].compactMap { $0 }
        let extras = [("lines", "+120 −8"), ("branch", model.branch ?? "main"), ("cost", "$1.20"), ("chat", "Write"),
                      ("templates", "Menu")].filter { shows.contains($0.0) }.map(\.1)
        let extraWidths = extras.map { Self.text($0, 10) + 16 }
        let items = 1 + buttons.count + (modelText == nil ? 0 : 1) + (agentsText == nil ? 0 : 1) + icons.count
            + (session || context ? 1 : 0) + extras.count
        let used = Self.pad * 2 + Self.character + buttonWidths.reduce(0, +) + modelWidth + agentsWidth
            + extraWidths.reduce(0, +) + CGFloat(icons.count) * Self.icon + Self.gap * CGFloat(items - 1)
        let room = max(0, width - used)
        return HStack(spacing: Self.gap) {
            key { MascotIcon(activity: model.activity, size: 22).frame(width: 22, height: 22) }
                .frame(width: Self.character)
            if session || context {
                meters(room: room, session: session, context: context).frame(width: room)
            }
            if let modelText {
                key { Text(modelText).font(.system(size: 10)).lineLimit(1) }.frame(width: modelWidth)
            }
            if let agentsText {
                key { Text(agentsText).font(.system(size: 10)).lineLimit(1) }.frame(width: agentsWidth)
            }
            ForEach(Array(extras.enumerated()), id: \.offset) { i, text in
                key { Text(text).font(.system(size: 10)).lineLimit(1) }.frame(width: extraWidths[i])
            }
            ForEach(Array(buttons.enumerated()), id: \.offset) { i, label in
                key(fill: highlightLast && i == buttons.count - 1 ? Color(hex: 0x0A3D78) : Color(hex: 0x2C2C2E)) {
                    Text(label).font(.system(size: 11)).lineLimit(1).truncationMode(.tail).padding(.horizontal, 4)
                }
                .frame(width: buttonWidths[i])
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }
            ForEach(icons, id: \.self) { name in
                key { Image(systemName: name).font(.system(size: 11)) }.frame(width: Self.icon)
            }
            if !(session || context) { Spacer(minLength: 0) }
        }
        .padding(.horizontal, Self.pad)
        .frame(width: width, height: 38)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
        .animation(.easeOut(duration: 0.25), value: shows)
        .animation(.easeOut(duration: 0.25), value: buttons)
    }

    /// One key of the bar: a dark rounded button.
    private func key<Label: View>(fill: Color = Color(hex: 0x2C2C2E), @ViewBuilder _ label: () -> Label) -> some View {
        label()
            .foregroundColor(.cbText)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(fill))
    }

    private func meters(room: CGFloat, session: Bool, context: Bool) -> some View {
        let both = session && context
        let inner = max(0, room - 8 - (both ? 10 : 0))
        let sessionRoom = both ? inner * 3 / 5 : inner
        let reset = model.config.touchBarShows.contains("reset") ? (model.resetShort ?? "1:23") : nil
        return HStack(spacing: 10) {
            if session {
                meter(sessionRoom >= 140 ? "Session" : sessionRoom >= 80 ? "5h" : "",
                      value: "\(Int(model.sessionPercent ?? 42))%" + (reset.map { sessionRoom >= 80 ? " · \($0)" : "" } ?? ""),
                      percent: (model.sessionPercent ?? 42) / 100)
                    .frame(width: sessionRoom)
            }
            if context {
                let w = both ? inner * 2 / 5 : inner
                meter(w >= 100 ? "Context" : w >= 60 ? "Ctx" : "", value: "\(Int(model.contextPercent ?? 31))%",
                      percent: (model.contextPercent ?? 31) / 100)
                    .frame(width: w)
            }
        }
        .padding(.horizontal, 4)
    }

    private func meter(_ label: String, value: String, percent: Double) -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(label).foregroundColor(.cbSecondary).lineLimit(1)
                Spacer(minLength: 2)
                Text(value).lineLimit(1)
            }
            .font(.system(size: 10).monospacedDigit())
            .foregroundColor(.cbText)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(hex: 0x2C2C2E))
                    Capsule().fill(Color.meter(percent * 100)).frame(width: geo.size.width * CGFloat(min(1, max(0, percent))))
                }
            }
            .frame(height: 3)
        }
    }

    private static func text(_ s: String, _ size: CGFloat) -> CGFloat {
        ceil((s as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size)]).width)
    }
}

/// Click, then press a shortcut (with ⌃, ⌥, ⇧ or ⌘). Esc cancels,
/// Delete clears it.
struct ShortcutField: NSViewRepresentable {
    @Binding var combo: String?

    func makeNSView(context: Context) -> RecorderView {
        let v = RecorderView()
        v.onChange = { combo = $0 }
        return v
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onChange = { combo = $0 }
        view.combo = combo
    }

    final class RecorderView: NSView {
        var combo: String? { didSet { update() } }
        var onChange: ((String?) -> Void)?
        private let label = NSTextField(labelWithString: "")
        private var recording = false { didSet { update() } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 7
            layer?.borderWidth = 0.5
            label.font = .systemFont(ofSize: 12)
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            ])
            setAccessibilityRole(.button)
            update()
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        private var monitor: Any?

        /// A click starts recording. Keys are caught by a local monitor, so
        /// nothing else in the window (SwiftUI, the Edit menu) gets them first.
        override func mouseDown(with event: NSEvent) {
            recording ? stop() : start()
        }

        private func start() {
            recording = true
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] e in
                guard let self else { return e }
                if e.type == .leftMouseDown {
                    // A click anywhere else ends recording; on us, mouseDown does.
                    if e.window !== self.window || !self.bounds.contains(self.convert(e.locationInWindow, from: nil)) {
                        self.stop()
                    }
                    return e
                }
                self.capture(e)
                return nil
            }
        }

        private func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            recording = false
        }

        private func capture(_ event: NSEvent) {
            switch event.keyCode {
            case 53: // esc: keep what was there
                stop()
            case 51, 117: // delete: no shortcut
                combo = nil
                onChange?(nil)
                stop()
            default:
                guard let c = HotKeys.combo(from: event) else { NSSound.beep(); return } // needs ⌃, ⌥, ⇧ or ⌘
                combo = c
                onChange?(c)
                stop()
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { stop() }
            super.viewWillMove(toWindow: newWindow)
        }

        private func update() {
            label.stringValue = recording ? "Press keys…" : combo.map(HotKeys.display) ?? "Shortcut"
            label.textColor = recording || combo != nil ? .labelColor : .secondaryLabelColor
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                layer?.backgroundColor = (dark ? NSColor.black.withAlphaComponent(0.25) : NSColor.white).cgColor
                layer?.borderColor = (recording ? NSColor(hex: 0x0A84FF)
                                      : dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.14)).cgColor
            }
            setAccessibilityLabel("Shortcut: " + (combo.map(HotKeys.display) ?? "none"))
        }
    }
}

// MARK: - Cowork

struct CoworkTab: View {
    @ObservedObject var model: AppModel
    @Environment(\.grayButtons) private var gray
    var mood: CloudMood? = nil
    @State private var keyOpen = false
    @State private var key = ""

    private let notes = [
        "off": "Cowork chats are not tracked.",
        "thresholds": "On every message, free. If the plugin can't reach the folder, Claude saves it: first reply, 50, 80, 90%.",
        "every": "On every message, free. If the plugin can't reach the folder, Claude saves it after every reply: +5–15% usage.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Cowork status").font(.system(size: 13))
                        Text("The plugin saves context to a connected folder").font(.system(size: 11)).foregroundColor(.sSecondary)
                    }
                    Spacer()
                    SettingsSegments(options: [("off", "Off"), ("thresholds", "Thresholds"), ("every", "Every reply")],
                                     selected: model.config.coworkMode, tint: 0xFF375F) { model.setConfig("coworkMode", $0) }
                }
                Text(notes[model.config.coworkMode] ?? "").font(.system(size: 11)).foregroundColor(.sSecondary)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.sGroup))

            if model.config.coworkMode != "off" {
                SettingsGroup {
                    SettingsRow(title: "Plugin",
                                hint: model.oldCoworkPlugin
                                    ? "Remove the older “clouding-bar-cowork” plugin in Claude Desktop → Customize → Plugins: both would report."
                                    : model.pluginSynced
                                        ? "Clouding Bar's plugin is installed in Claude Desktop"
                                        : "Claude Desktop → Customize → Plugins: add the marketplace nikolanaidenko-eng/clouding-bar, or upload this zip") {
                        Button("Save zip") { model.makeCoworkPlugin() }
                    }
                    SettingsRow(title: "Folders",
                                hint: (model.coworkFolders.isEmpty
                                    ? "Connect a folder to a Cowork task; it's found by itself."
                                    : "Watching " + model.coworkFolders.joined(separator: ", ") + ".")
                                    + " Only tasks with a connected folder can report their context.") {
                        Button("Add…") { model.chooseCoworkFolder() }
                    }
                    SettingsRow(title: "Last status", hint: model.coworkLast ?? "None yet", divider: model.coworkMessage != nil) {
                        EmptyView()
                    }
                    if let message = model.coworkMessage {
                        Text(message).font(.system(size: 11)).foregroundColor(.sSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            }

            SettingsGroup {
                MoreRows("cowork", count: 1) {
                SettingsRow(title: "Live limit via claude.ai",
                            hint: "Desktop and Cowork chats · \(model.liveLimitState)", divider: keyOpen) {
                    if model.hasLiveKey {
                        Button("Remove key") { model.removeLiveKey(); keyOpen = false }
                    } else {
                        Button(keyOpen ? "Hide" : "Set up…") { withAnimation(.easeOut(duration: 0.2)) { keyOpen.toggle() } }
                    }
                }
                if keyOpen && !model.hasLiveKey {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle").foregroundColor(.cbWarning)
                            Text("Your session key gives full access to your Claude account. Unofficial address, can stop working any time. Kept in Keychain, sent only to claude.ai.")
                                .font(.system(size: 11)).foregroundColor(Color.sText).lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        HStack(spacing: 8) {
                            SecureField("sessionKey", text: $key)
                                .textFieldStyle(.plain).font(.system(size: 12))
                                .padding(.horizontal, 8).frame(height: 30)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Color.sField))
                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.sFieldLine, lineWidth: 0.5))
                            Button("I understand, turn on") {
                                model.saveLiveKey(key)
                                key = ""
                                keyOpen = false
                            }
                            .buttonStyle(.plain).font(.system(size: 12)).foregroundColor(.white)
                            .padding(.horizontal, 12).frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.tint(0x0071E3, gray: gray)))
                            .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding(12)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
                }
            }
        }
        // Cloud doesn't peek while the key is being typed.
        .onChange(of: keyOpen && !model.hasLiveKey) { open in mood?.shy = open }
        .onDisappear { mood?.shy = false }
    }
}
