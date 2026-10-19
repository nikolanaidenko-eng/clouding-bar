import AppKit
import SwiftUI

/// The tour: a short walk through Clouding Bar, one thing per page, each
/// with a live copy of the real thing on a little desktop. It opens by
/// itself the first time, and from the menu or Settings → General after.
final class TourWindow {
    private var window: NSWindow?
    private let openSettings: () -> Void

    init(openSettings: @escaping () -> Void) { self.openSettings = openSettings }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: TourView.size.width, height: TourView.size.height),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Clouding Bar Tour"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = NSColor(hex: 0x232325)
            w.standardWindowButton(.miniaturizeButton)?.isHidden = true
            w.standardWindowButton(.zoomButton)?.isHidden = true
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        // A fresh tour every time, from the first page.
        window?.contentView = NSHostingView(rootView: TourView(
            close: { [weak self] in self?.window?.close() },
            openSettings: { [weak self] in
                self?.window?.close()
                self?.openSettings()
            }))
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct TourView: View {
    static let size = CGSize(width: 640, height: 560)

    let close: () -> Void
    let openSettings: () -> Void
    @State private var page: Int

    init(close: @escaping () -> Void, openSettings: @escaping () -> Void, page: Int = 0) {
        self.close = close
        self.openSettings = openSettings
        _page = State(initialValue: page)
    }
    @State private var forward = true
    @StateObject private var mood = CloudMood()
    /// Sample numbers for the live copies, the same on every Mac.
    @StateObject private var sample = TourView.sampleModel()

    private struct Page {
        let title: String
        let text: String
    }

    private let pages = [
        Page(title: "Meet Cloud",
             text: "Clouding Bar shows what Claude Code is up to — on the Touch Bar, in a floating pill or in the notch. Cloud dozes while Claude is idle, hops while it works, and waves when it needs you."),
        Page(title: "The pill",
             text: "Your limits at a glance: the 5-hour limit, the context, when it resets. Pull its outline to resize it — wider shows more, taller stands it up. Drag items onto each other to swap them, drag the pill anywhere."),
        Page(title: "The notch",
             text: "Drag the pill to the top of the screen and it docks in the notch (Macs without one get a drawn one). When Claude asks something, it grows so you can answer right there. Drag it out to put it anywhere again."),
        Page(title: "The panel",
             text: "Hover the pill for 2 seconds, or click it, for everything: model and effort, subagents at work, your buttons, and a chat line — messages wait until Claude is free. Drop files on the widget to send them along."),
        Page(title: "The Touch Bar",
             text: "While your terminal or VS Code is in front, the Touch Bar is Claude's: meters, buttons, model, mic. Permission requests and questions show up there too — Allow, Deny, or tap an answer. Hold the right ⌥ key to dictate."),
        Page(title: "Make it yours",
             text: "Everything is optional. Settings → Widget and Touch Bar have a chip for each thing; Buttons is for your own commands and templates. Turn off what you don't need."),
        Page(title: "Private by design",
             text: "Clouding Bar talks only to Claude Code on this Mac, through its hooks. No account, no analytics. The claude.ai limit is the one thing that goes online, and only if you turn it on."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            stage
                .frame(height: 280)
                .frame(maxWidth: .infinity)
                .background(LinearGradient(colors: [Color(hex: 0x1B1B1D), Color(hex: 0x2A2A2E)],
                                           startPoint: .top, endPoint: .bottom))
                .clipped()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
            text
            Spacer(minLength: 0)
            footer
        }
        .foregroundColor(.cbText)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(hex: 0x232325))
        .environment(\.colorScheme, .dark)
        .onChange(of: page) { _ in mood.pokes += 1 }
        .background(TourKeys(next: next, back: back, close: close))
    }

    // MARK: Stage

    @ViewBuilder private var stage: some View {
        ZStack {
            Group {
                switch page {
                case 0: faces
                case 1: pill
                case 2: notch
                case 3: panel
                case 4: touchBar
                case 5: chips
                default: privacy
                }
            }
            .id(page)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: forward ? 40 : -40)),
                                    removal: .opacity.combined(with: .offset(x: forward ? -40 : 40))))
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: page)
    }

    private var faces: some View {
        HStack(spacing: 46) {
            face(.sleep, "Idle")
            face(.work, "Working")
            face(.wait, "Needs you")
        }
    }

    private func face(_ activity: Activity, _ label: String) -> some View {
        VStack(spacing: 12) {
            MascotIcon(activity: activity, size: 84).frame(width: 84, height: 84)
            Text(label).font(.system(size: 12)).foregroundColor(.cbSecondary)
        }
    }

    private var pill: some View {
        let state = WidgetState()
        state.mode = .pill
        let model = Self.sampleModel()
        model.config.pillWidth = 560 // as much as fits on the page
        return VStack(spacing: 22) {
            WidgetView(model: model, state: state)
            Text("Pull the outline · drag items onto each other")
                .font(.system(size: 11)).foregroundColor(.cbSecondary)
        }
    }

    private var notch: some View {
        let compact = WidgetState(), grown = WidgetState()
        for s in [compact, grown] { s.mode = .pill; s.notched = true; s.notchHeight = 32 }
        let asking = Self.sampleModel()
        var card = AppModel.RequestCard(id: UUID(), kind: .question, project: "DiaRoute")
        card.question = "Which storage should offline routes use?"
        card.options = ["SQLite", "MMKV", "AsyncStorage"]
        asking.request = card
        return VStack(spacing: 0) {
            WidgetView(model: sample, state: compact)
            Spacer().frame(height: 46)
            WidgetView(model: asking, state: grown)
            Spacer(minLength: 0)
        }
        .scaleEffect(0.92, anchor: .top)
    }

    private var panel: some View {
        let state = WidgetState()
        state.mode = .panel
        return WidgetView(model: sample, state: state)
            .scaleEffect(0.82)
    }

    private var touchBar: some View {
        VStack(spacing: 18) {
            TouchBarPreview(model: sample)
                .frame(width: 580)
            HStack(spacing: 8) {
                key("Allow", fill: .cbAction)
                key("Always")
                key("Deny", text: .cbDeny)
            }
            Text("…and when Claude asks, the bar is the answer")
                .font(.system(size: 11)).foregroundColor(.cbSecondary)
        }
    }

    private func key(_ label: String, fill: Color = Color(hex: 0x2C2C2E), text: Color = .white) -> some View {
        Text(label).font(.system(size: 13, weight: .medium)).foregroundColor(text)
            .frame(width: 96, height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(fill))
    }

    private var chips: some View {
        VStack(alignment: .leading, spacing: 12) {
            chipRow(["Session", "Context", "Reset time", "Cost"], on: [0, 1, 2])
            chipRow(["Model", "Lines", "Branch", "Subagents"], on: [0, 3])
            chipRow(["Buttons", "Chat", "Templates", "Screenshot", "Mic"], on: [0, 1, 4])
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
    }

    private func chipRow(_ labels: [String], on: Set<Int>) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, label in
                Chip(label: label, on: on.contains(i)) {}
            }
        }
    }

    private var privacy: some View {
        HStack(spacing: 28) {
            MascotIcon(activity: .sleep, size: 84, awake: true, pokes: 1).frame(width: 84, height: 84)
            Image(systemName: "lock.shield").font(.system(size: 54, weight: .light)).foregroundColor(.cbSecondary)
        }
    }

    // MARK: Text and buttons

    private var text: some View {
        HStack(alignment: .top, spacing: 16) {
            LiveMascot(size: 40, mood: mood).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 8) {
                Text(pages[page].title).font(.system(size: 20, weight: .semibold))
                Text(pages[page].text)
                    .font(.system(size: 13)).foregroundColor(Color(hex: 0xD1D1D6)).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .id(page)
            .transition(.opacity)
            Spacer(minLength: 0)
        }
        .animation(.easeOut(duration: 0.2), value: page)
        .padding(.horizontal, 28)
        .padding(.top, 22)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(page == pages.count - 1 ? "Open Settings" : "Skip") {
                page == pages.count - 1 ? openSettings() : close()
            }
            .buttonStyle(.plain).font(.system(size: 13)).foregroundColor(.cbSecondary)
            Spacer()
            HStack(spacing: 7) {
                ForEach(pages.indices, id: \.self) { i in
                    Capsule().fill(i == page ? Color.cbText : Color.white.opacity(0.25))
                        .frame(width: i == page ? 18 : 7, height: 7)
                        .onTapGesture { go(to: i) }
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: page)
            .accessibilityElement()
            .accessibilityLabel("Page \(page + 1) of \(pages.count)")
            Spacer()
            if page > 0 {
                Button("Back", action: back)
                    .buttonStyle(WidgetButtonStyle(height: 32, radius: 9)).frame(width: 80)
            }
            Button(page == pages.count - 1 ? "Done" : "Next", action: next)
                .buttonStyle(WidgetButtonStyle(background: .cbAction, foreground: .white, weight: .semibold, height: 32, radius: 9))
                .frame(width: 96)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 22)
    }

    private func go(to i: Int) {
        guard i != page, pages.indices.contains(i) else { return }
        forward = i > page
        withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) { page = i }
    }

    private func next() { page == pages.count - 1 ? close() : go(to: page + 1) }
    private func back() { go(to: page - 1) }

    // MARK: Sample

    static func sampleModel() -> AppModel {
        let m = AppModel()
        m.hasSession = true
        m.activity = .work
        m.project = "DiaRoute"
        m.sessionPercent = 42
        m.resetShort = "1:23"
        m.resetLong = "1 h 23 min"
        m.contextPercent = 31
        m.tokensIn = 41_200
        m.tokensOut = 2_300
        m.modelName = "Opus 5.5 1M"
        m.modelId = "claude-opus-5-5[1m]"
        m.effort = "xhigh"
        m.agents = 2
        m.buttons = Config().effectiveButtons.filter { $0.type != .link }
        m.config.metrics = ["model", "agents"]
        m.config.taskQueue = true
        m.config.pillWidth = 10_000
        m.config.touchBarShows = ["session", "reset", "context", "model", "buttons", "mic"]
        return m
    }
}

/// ← → and Return to page through, Esc to close.
private struct TourKeys: NSViewRepresentable {
    let next: () -> Void
    let back: () -> Void
    let close: () -> Void

    final class KeyView: NSView {
        var next: (() -> Void)?, back: (() -> Void)?, close: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 124, 36, 76: next?()   // →, Return, Enter
            case 123: back?()           // ←
            case 53: close?()           // Esc
            default: super.keyDown(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> KeyView {
        let v = KeyView()
        updateNSView(v, context: context)
        return v
    }

    func updateNSView(_ v: KeyView, context: Context) {
        v.next = next
        v.back = back
        v.close = close
    }
}
