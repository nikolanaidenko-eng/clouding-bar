import AppKit
import SwiftUI

/// Plays each tour page's scene on the real views, on a loop: the numbers
/// tick, questions arrive, the notch grows, a pointer drags and clicks.
/// Everything happens to a sample model, never to the real one.
final class TourDirector: ObservableObject {
    enum Pointer { case arrow, finger }
    enum Bar: Equatable { case normal, permission, question }

    let model = TourView.sampleModel()
    let state = WidgetState()

    @Published var page = 0
    /// The pointer, in the stage's points (640 × 300), and what it looks like.
    @Published var cursor: CGPoint?
    @Published var pointer = Pointer.arrow
    /// Goes up by one per click: a ripple under the pointer.
    @Published var clicks = 0
    /// Page 1: the big Cloud and what it means.
    @Published var cloud: Activity = .sleep
    @Published var cloudPokes = 0
    @Published var caption = ""
    /// Page 5: the Touch Bar's mode.
    @Published var bar = Bar.normal
    /// Page 6: the chip that was just flipped.
    @Published var flipped: String?
    /// Page 4: a file flying in from the side.
    @Published var file: CGPoint?
    /// Something happened: the guide hops.
    var onEvent: () -> Void = {}

    static let stage = CGSize(width: 640, height: 300)
    private var work: [DispatchWorkItem] = []
    private var ticker: Timer?

    deinit { ticker?.invalidate() }

    /// Starts `page`'s scene from the top; it loops until another starts.
    func play(_ page: Int) {
        stop()
        self.page = page
        reset()
        let (steps, length) = script(page)
        for (t, step) in steps { after(t, step) }
        after(length) { [weak self] in self?.play(page) }
        if [1, 2, 4].contains(page) {
            ticker = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in self?.tick() }
        }
    }

    func stop() {
        work.forEach { $0.cancel() }
        work = []
        ticker?.invalidate()
        ticker = nil
    }

    /// For pictures: the scene as it stands `t` seconds in.
    func jump(_ page: Int, to t: Double) {
        stop()
        self.page = page
        reset()
        for (time, step) in script(page).steps where time <= t { step() }
    }

    private func after(_ t: Double, _ step: @escaping () -> Void) {
        let item = DispatchWorkItem(block: step)
        work.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: item)
    }

    /// The numbers creep up while Claude works.
    private func tick() {
        let s = (model.sessionPercent ?? 42) + 0.6, c = (model.contextPercent ?? 31) + 1.4
        model.sessionPercent = s > 88 ? 41 : s
        model.contextPercent = c > 86 ? 30 : c
    }

    private func reset() {
        let fresh = TourView.sampleModel()
        model.request = nil
        model.activity = .work
        model.sessionPercent = fresh.sessionPercent
        model.contextPercent = fresh.contextPercent
        model.modelName = fresh.modelName
        model.modelId = fresh.modelId
        model.effort = fresh.effort
        model.attachments = []
        model.queue = []
        model.pickingModel = false
        model.config = fresh.config
        state.mode = .pill
        state.notched = false
        state.notchWidth = 0
        state.notchHeight = 32
        state.pillEditSize = nil
        state.dropHover = false
        cursor = nil
        pointer = .arrow
        bar = .normal
        flipped = nil
        file = nil
        switch page {
        case 1: model.config.pillWidth = Double(Self.pillCompact)
        case 2: state.notched = true
        case 3: model.config.pillWidth = 330
        case 5: model.config.pillWidth = 600
        default: break
        }
    }

    // MARK: Helpers for the scripts

    private func move(_ x: CGFloat, _ y: CGFloat, _ seconds: Double = 0.7) {
        if cursor == nil {
            cursor = CGPoint(x: x + 120, y: y + 90) // comes in from the lower right
        }
        withAnimation(.easeInOut(duration: seconds)) { cursor = CGPoint(x: x, y: y) }
    }

    private func click() { clicks += 1 }

    private func away() { withAnimation(.easeIn(duration: 0.5)) { cursor = nil } }

    // MARK: Page 2 · the pill

    static let pillCompact: CGFloat = 230
    static let pillWide: CGFloat = 600
    static let pillTop: CGFloat = 96

    /// The pill's right end for a width budget, in the stage.
    private func pillRight(_ budget: CGFloat) -> CGFloat {
        let w = PillLayout(model: model).arrange(width: budget, height: model.pillHeightBudget).frame.width
        return Self.stage.width / 2 + w / 2
    }

    /// Pulls the pill's end from one budget to another, the outline blue, the
    /// pointer on the end.
    private func drag(from a: CGFloat, to b: CGFloat, at t0: Double) -> [(Double, () -> Void)] {
        var steps: [(Double, () -> Void)] = []
        let n = 14
        for i in 0...n {
            let w = a + (b - a) * CGFloat(i) / CGFloat(n)
            steps.append((t0 + Double(i) * 0.08, { [weak self] in
                guard let self else { return }
                let frame = PillLayout(model: self.model).arrange(width: w, height: self.model.pillHeightBudget).frame
                self.state.pillEditSize = CGSize(width: max(frame.width, w), height: 44)
                self.cursor = CGPoint(x: Self.stage.width / 2 + max(frame.width, w) / 2 - 4, y: Self.pillTop + 22)
            }))
        }
        steps.append((t0 + Double(n) * 0.08 + 0.1, { [weak self] in
            self?.model.config.pillWidth = Double(b)
            withAnimation(.cb(0.2)) { self?.state.pillEditSize = nil }
        }))
        return steps
    }

    // MARK: Scripts

    private func script(_ page: Int) -> (steps: [(Double, () -> Void)], length: Double) {
        switch page {
        case 0: // Meet Cloud: its moods, one after another.
            let moods: [(Activity, String)] = [(.sleep, "Idle — waiting for your next message"),
                                               (.work, "Working — Claude is writing code"),
                                               (.wait, "Needs you — a question or a permission"),
                                               (.work, "Answered — back to work")]
            var steps: [(Double, () -> Void)] = []
            for (i, mood) in moods.enumerated() {
                steps.append((Double(i) * 2.2, { [weak self] in
                    withAnimation(.easeOut(duration: 0.25)) {
                        self?.cloud = mood.0
                        self?.caption = mood.1
                    }
                    if i == 3 { self?.cloudPokes += 1 }
                }))
            }
            return (steps, 8.8)

        case 1: // The pill: pulled wider, more shows; pushed back.
            var steps: [(Double, () -> Void)] = [
                (0.9, { [weak self] in guard let self else { return }; self.move(self.pillRight(Self.pillCompact) - 4, Self.pillTop + 22) }),
            ]
            steps += drag(from: Self.pillCompact, to: Self.pillWide, at: 1.8)
            steps += drag(from: Self.pillWide, to: Self.pillCompact, at: 4.6)
            steps.append((6.6, { [weak self] in self?.away() }))
            return (steps, 7.6)

        case 2: // The notch: a question arrives and is answered; then an OK.
            var question = AppModel.RequestCard(id: UUID(), kind: .question, project: "DiaRoute")
            question.question = "Which storage should offline routes use?"
            question.options = ["SQLite", "MMKV", "AsyncStorage"]
            let permission = AppModel.RequestCard(id: UUID(), kind: .permission, project: "DiaRoute",
                                                  verb: "Run", detail: "npm test -- --watch=false")
            return ([
                (1.6, { [weak self] in self?.arrive(question) }),
                (2.4, { [weak self] in self?.move(146, 84, 0.8) }),
                (3.5, { [weak self] in self?.click() }),
                (3.7, { [weak self] in self?.answered() }),
                (4.4, { [weak self] in self?.away() }),
                (5.4, { [weak self] in self?.arrive(permission) }),
                (6.2, { [weak self] in self?.move(140, 81, 0.8) }),
                (7.3, { [weak self] in self?.click() }),
                (7.5, { [weak self] in self?.answered() }),
                (8.2, { [weak self] in self?.away() }),
            ], 9.6)

        case 3: // The panel: hover opens it; switch the model; a file; a message.
            return ([
                (0.6, { [weak self] in self?.move(320, 38, 0.8) }),
                (1.8, { [weak self] in withAnimation(.cb(0.28)) { self?.state.mode = .panel } }),
                (2.6, { [weak self] in self?.move(176, 128, 0.7) }),
                (3.4, { [weak self] in
                    self?.click()
                    withAnimation(.cb(0.24)) { self?.model.pickingModel = true }
                }),
                (4.3, { [weak self] in self?.move(372, 172, 0.6) }),
                (5.0, { [weak self] in
                    guard let self else { return }
                    self.click()
                    self.model.modelId = "claude-sonnet-5-5"
                    self.model.modelName = "Sonnet 5.5"
                }),
                (5.8, { [weak self] in withAnimation(.cb(0.24)) { self?.model.pickingModel = false } }),
                (6.1, { [weak self] in
                    self?.away()
                    self?.file = CGPoint(x: 700, y: 60)
                    withAnimation(.easeInOut(duration: 0.8)) { self?.file = CGPoint(x: 330, y: 150) }
                }),
                (6.5, { [weak self] in withAnimation(.easeOut(duration: 0.15)) { self?.state.dropHover = true } }),
                (7.1, { [weak self] in
                    guard let self else { return }
                    withAnimation(.easeOut(duration: 0.15)) { self.state.dropHover = false }
                    self.file = nil
                    withAnimation(.cb(0.22)) { self.model.attachments = ["/Users/you/Desktop/crash.png"] }
                    self.onEvent()
                }),
                (8.4, { [weak self] in
                    guard let self else { return }
                    withAnimation(.cb(0.22)) {
                        self.model.attachments = []
                        self.model.queue = [.init(text: "Why does it crash here? /Users/you/Desktop/crash.png",
                                                  sessionId: nil, project: "DiaRoute")]
                    }
                }),
            ], 10.6)

        case 4: // The Touch Bar: an OK, then a question, answered with a tap.
            return ([
                (1.8, { [weak self] in self?.showBar(.permission) }),
                (2.6, { [weak self] in self?.pointer = .finger; self?.move(TourBar.allowX, TourBar.y + 8, 0.7) }),
                (3.5, { [weak self] in self?.click() }),
                (3.7, { [weak self] in self?.showBar(.normal); self?.away() }),
                (5.0, { [weak self] in self?.showBar(.question) }),
                (5.8, { [weak self] in self?.pointer = .finger; self?.move(TourBar.optionX, TourBar.y + 8, 0.7) }),
                (6.7, { [weak self] in self?.click() }),
                (6.9, { [weak self] in self?.showBar(.normal); self?.away() }),
            ], 8.4)

        case 5: // Make it yours: chips flip, the pill follows.
            let flips = ["metric:model", "mic", "reset", "metric:model", "mic", "reset"]
            var steps: [(Double, () -> Void)] = []
            for (i, id) in flips.enumerated() {
                let t = 0.9 + Double(i) * 1.25
                steps.append((t, { [weak self] in
                    guard let self, let p = TourChips.center(of: id) else { return }
                    self.move(p.x, p.y, 0.6)
                }))
                steps.append((t + 0.75, { [weak self] in self?.flip(id) }))
            }
            steps.append((0.9 + Double(flips.count) * 1.25, { [weak self] in self?.away() }))
            return (steps, 0.9 + Double(flips.count) * 1.25 + 1.0)

        default:
            return ([], 10)
        }
    }

    private func arrive(_ card: AppModel.RequestCard) {
        model.request = card
        model.activity = .wait
        onEvent()
    }

    private func answered() {
        model.request = nil
        model.activity = .work
    }

    private func showBar(_ b: Bar) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) { bar = b }
        if b != .normal { onEvent() }
    }

    /// Turns one of page 6's chips over, the way Settings does.
    private func flip(_ id: String) {
        click()
        var c = model.config
        switch id {
        case "metric:model":
            c.metrics = c.metrics.contains("model") ? c.metrics.filter { $0 != "model" } : c.metrics + ["model"]
        case "mic":
            c.widgetHides = c.widgetHides.contains("mic") ? c.widgetHides.filter { $0 != "mic" } : c.widgetHides + ["mic"]
        default:
            c.pillShows = c.pillShows.contains(id) ? c.pillShows.filter { $0 != id } : c.pillShows + [id]
        }
        withAnimation(.cb(0.25)) {
            model.config = c
            flipped = id
        }
    }
}

// MARK: - Touch Bar scene

/// The Touch Bar, as the tour shows it: the settings' live preview in
/// normal mode, the bar's own layout for an OK and a question.
struct TourBar: View {
    @ObservedObject var director: TourDirector

    static let width: CGFloat = 580
    static let y: CGFloat = 100
    /// Where the pointer taps, in the stage (the bar is centred in it).
    static let allowX: CGFloat = (640 - width) / 2 + 5 + 36 + 5 + 250 + 5 + 40
    static let optionX: CGFloat = (640 - width) / 2 + 5 + 36 + 5 + 250 + 5 + 40

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                switch director.bar {
                case .normal:
                    TouchBarPreview(model: director.model).transition(.opacity)
                case .permission:
                    row(message: "Run", detail: "npm test", keys: [("Allow", .cbAction, .white), ("Always", nil, .white),
                                                                     ("Deny", nil, .cbDeny)])
                        .transition(.opacity.combined(with: .offset(x: 20)))
                case .question:
                    row(message: nil, detail: "Storage for offline routes?",
                        keys: [("SQLite", nil, .white), ("MMKV", nil, .white), ("Other…", nil, .white)])
                        .transition(.opacity.combined(with: .offset(x: 20)))
                }
            }
            .frame(width: Self.width, height: 38)
            Text(director.bar == .normal ? "Meters, model, buttons — while your terminal or VS Code is in front"
                 : "When Claude asks, the bar is the answer")
                .font(.system(size: 11)).foregroundColor(.cbSecondary)
                .animation(nil, value: director.bar)
        }
        .padding(.top, Self.y)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The bar for a request: the character, the message with its orange
    /// dot, then the keys.
    private func row(message: String?, detail: String, keys: [(String, Color?, Color)]) -> some View {
        HStack(spacing: 5) {
            MascotIcon(activity: .wait, size: 22).frame(width: 22, height: 22)
                .frame(width: 36, height: 28)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: 0x2C2C2E)))
            HStack(spacing: 6) {
                Circle().fill(Color.cbWarning).frame(width: 6, height: 6)
                if let message { Text(message).foregroundColor(.cbSecondary) }
                Text(detail).font(.system(size: 11, design: message == nil ? .default : .monospaced)).foregroundColor(.white)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(width: 250, height: 28, alignment: .leading)
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key.0).font(.system(size: 11, weight: key.1 != nil ? .semibold : .regular)).foregroundColor(key.2)
                    .frame(width: 80, height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(key.1 ?? Color(hex: 0x2C2C2E)))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 5)
        .frame(width: Self.width, height: 38)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
    }
}

// MARK: - Chips scene

/// Page 6's chips, laid out by hand so the pointer knows where they are.
struct TourChips: View {
    @ObservedObject var director: TourDirector

    static let rows: [[(id: String, label: String)]] = [
        [("session", "Session"), ("context", "Context"), ("reset", "Reset time")],
        [("metric:model", "Model"), ("metric:agents", "Subagents"), ("metric:lines", "Lines")],
        [("buttons", "Buttons"), ("chat", "Chat"), ("mic", "Mic")],
    ]
    static let top: CGFloat = 132
    static let rowGap: CGFloat = 36
    static let gap: CGFloat = 6

    static func width(_ label: String) -> CGFloat { MainPanel.textWidth(label, 12) + 20 }

    static func rowWidth(_ row: [(id: String, label: String)]) -> CGFloat {
        row.map { width($0.label) }.reduce(0, +) + gap * CGFloat(row.count - 1)
    }

    /// A chip's centre, in the stage.
    static func center(of id: String) -> CGPoint? {
        for (r, row) in rows.enumerated() {
            var x = (640 - rowWidth(row)) / 2
            for chip in row {
                let w = width(chip.label)
                if chip.id == id { return CGPoint(x: x + w / 2, y: top + CGFloat(r) * rowGap + 13) }
                x += w + gap
            }
        }
        return nil
    }

    private func isOn(_ id: String) -> Bool {
        let c = director.model.config
        switch id {
        case "session", "mic", "buttons": return !c.widgetHides.contains(id)
        case "chat": return c.taskQueue
        case let m where m.hasPrefix("metric:"): return c.metrics.contains(String(m.dropFirst(7)))
        default: return c.pillShows.contains(id)
        }
    }

    var body: some View {
        VStack(spacing: Self.rowGap - 26) {
            ForEach(Self.rows.indices, id: \.self) { r in
                HStack(spacing: Self.gap) {
                    ForEach(Self.rows[r], id: \.id) { chip in
                        Chip(label: chip.label, on: isOn(chip.id)) {}
                            .scaleEffect(director.flipped == chip.id ? 1.08 : 1)
                            .animation(.spring(response: 0.3, dampingFraction: 0.5), value: director.flipped)
                    }
                }
            }
        }
        .padding(.top, Self.top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Privacy scene

/// Page 7: everything stays inside "this Mac" — dots run from Claude Code
/// to Clouding Bar and back; the cloud outside is crossed out.
struct TourPrivacy: View {
    @State private var flow = false

    var body: some View {
        HStack(spacing: 34) {
            VStack(spacing: 10) {
                HStack(spacing: 0) {
                    box("terminal", "Claude Code")
                    ZStack {
                        Capsule().fill(Color.white.opacity(0.08)).frame(height: 2)
                        HStack(spacing: 14) {
                            ForEach(0..<4) { _ in Circle().fill(Color.cbAction).frame(width: 6, height: 6) }
                        }
                        .offset(x: flow ? 22 : -22)
                        .opacity(flow ? 0.25 : 1)
                    }
                    .frame(width: 110)
                    .clipped()
                    box("cloud", "Clouding Bar", mascot: true)
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.18),
                                                                            style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                Text("This Mac").font(.system(size: 11)).foregroundColor(.cbSecondary)
            }
            VStack(spacing: 8) {
                Image(systemName: "network.slash").font(.system(size: 34, weight: .light)).foregroundColor(.cbSecondary)
                Text("No servers").font(.system(size: 11)).foregroundColor(.cbSecondary)
            }
        }
        .onAppear {
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { flow = true }
        }
    }

    private func box(_ icon: String, _ title: String, mascot: Bool = false) -> some View {
        VStack(spacing: 8) {
            if mascot {
                MascotIcon(activity: .work, size: 40).frame(width: 40, height: 40)
            } else {
                Image(systemName: icon).font(.system(size: 26)).frame(width: 40, height: 40)
            }
            Text(title).font(.system(size: 12, weight: .medium))
        }
        .frame(width: 110, height: 90)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
    }
}

// MARK: - The pointer

/// The pointer over the stage, with a ripple at each click.
struct TourPointer: View {
    @ObservedObject var director: TourDirector
    @State private var ripple = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let p = director.cursor {
                Circle().strokeBorder(Color.white.opacity(0.7), lineWidth: 2)
                    .frame(width: 34, height: 34)
                    .scaleEffect(ripple ? 1.3 : 0.4)
                    .opacity(ripple ? 0 : 0.9)
                    .position(p)
                Image(systemName: director.pointer == .finger ? "hand.point.up.left.fill" : "cursorarrow")
                    .font(.system(size: director.pointer == .finger ? 24 : 20, weight: .semibold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                    .position(x: p.x + (director.pointer == .finger ? 4 : 6), y: p.y + (director.pointer == .finger ? 12 : 9))
                    .transition(.opacity)
            }
            if let f = director.file {
                VStack(spacing: 3) {
                    Image(systemName: "photo").font(.system(size: 26)).foregroundColor(.white)
                    Text("crash.png").font(.system(size: 10)).foregroundColor(.white)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)))
                .position(f)
                .transition(.opacity)
            }
        }
        .frame(width: TourDirector.stage.width, height: TourDirector.stage.height, alignment: .topLeading)
        .onChange(of: director.clicks) { _ in
            ripple = false
            withAnimation(.easeOut(duration: 0.45)) { ripple = true }
        }
    }
}
