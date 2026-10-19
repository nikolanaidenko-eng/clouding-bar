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
    static let size = CGSize(width: 640, height: 580)

    let close: () -> Void
    let openSettings: () -> Void
    @State private var page: Int

    init(close: @escaping () -> Void, openSettings: @escaping () -> Void, page: Int = 0, freezeAt: Double? = nil) {
        self.close = close
        self.openSettings = openSettings
        self.freezeAt = freezeAt
        _page = State(initialValue: page)
    }
    @State private var forward = true
    @StateObject private var mood = CloudMood()
    /// Plays each page's scene on live copies of the real views.
    @StateObject private var director = TourDirector()
    /// For pictures: the scene held at this many seconds in.
    var freezeAt: Double?

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
                .frame(height: TourDirector.stage.height)
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
        .onChange(of: page) { p in
            mood.pokes += 1
            director.play(p)
        }
        .onAppear {
            director.onEvent = { [weak mood] in mood?.hops += 1 }
            if let t = freezeAt { director.jump(page, to: t) } else { director.play(page) }
        }
        .onDisappear { director.stop() }
        .background(TourKeys(next: next, back: back, close: close))
    }

    // MARK: Stage

    @ViewBuilder private var stage: some View {
        ZStack(alignment: .topLeading) {
            Group {
                switch page {
                case 0: cloudScene
                case 1: pillScene
                case 2: notchScene
                case 3: panelScene
                case 4: TourBar(director: director)
                case 5: chipsScene
                default: TourPrivacy().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: TourDirector.stage.width, height: TourDirector.stage.height, alignment: .top)
            .id(page)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: forward ? 40 : -40)),
                                    removal: .opacity.combined(with: .offset(x: forward ? -40 : 40))))
            TourPointer(director: director)
        }
        .frame(width: TourDirector.stage.width, height: TourDirector.stage.height)
        .animation(.spring(response: 0.45, dampingFraction: 0.86), value: page)
    }

    /// Page 1: Cloud's moods, one after another, with what each means.
    private var cloudScene: some View {
        VStack(spacing: 18) {
            MascotIcon(activity: director.cloud, size: 110, pokes: director.cloudPokes)
                .frame(width: 110, height: 110)
            Text(director.caption).font(.system(size: 13)).foregroundColor(.cbSecondary)
                .id(director.caption)
                .transition(.opacity)
            HStack(spacing: 8) {
                ForEach([Activity.sleep, .work, .wait], id: \.self) { a in
                    Capsule().fill(director.cloud == a ? Color.cbText : Color.white.opacity(0.2))
                        .frame(width: director.cloud == a ? 16 : 6, height: 6)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: director.cloud)
        }
        .padding(.top, 52)
    }

    /// Page 2: the pill, pulled wider and back by the pointer.
    private var pillScene: some View {
        VStack(spacing: 18) {
            WidgetView(model: director.model, state: director.state)
                .frame(height: 44)
            Text(director.state.pillEditSize == nil ? "Your limits at a glance — they tick as Claude works"
                 : "Pulling the outline: wider shows more")
                .font(.system(size: 11)).foregroundColor(.cbSecondary)
        }
        .padding(.top, TourDirector.pillTop)
    }

    /// Page 3: the notch, growing for a question and an OK.
    private var notchScene: some View {
        WidgetView(model: director.model, state: director.state)
    }

    /// Page 4: the pill opens into the panel; the model, a file, a message.
    private var panelScene: some View {
        WidgetView(model: director.model, state: director.state)
            .padding(.top, 16)
    }

    /// Page 6: chips flip, the pill follows.
    private var chipsScene: some View {
        ZStack(alignment: .top) {
            WidgetView(model: director.model, state: director.state)
                .padding(.top, 40)
            TourChips(director: director)
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
