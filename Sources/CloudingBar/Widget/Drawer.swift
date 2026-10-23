import AppKit
import Combine
import SwiftUI

/// The widget called up from the Touch Bar's character button.
///
///   in   Cloud (the character) climbs out of the bottom-left corner of the
///        screen still asleep, wakes up with a stretch, hops twice, and the
///        panel grows under it like a lift. The panel is an island of its
///        own: it floats a little above the screen's edge, never tucked
///        under it. Drag Cloud to put it anywhere.
///   out  Tap the button again: the island flies back to the corner and
///        Cloud jumps on the panel, pressing it down a little with every
///        jump until it's gone — then Cloud dozes off and ducks too.
///
/// On the island Cloud follows Claude; when Claude is idle it dozes off a
/// few seconds after the last touch. Hover over it and it wakes; click it
/// and it jumps.
final class DrawerController: NSObject {
    let model: AppModel
    let state = WidgetState()
    private let anim = DrawerAnimation()

    private var panel: WidgetPanel!
    private var host: HoverHostingView<DrawerView>!
    private var measure: NSHostingView<WidgetView>!
    private(set) var shown = false
    private var busy = false
    private var dozeWork: DispatchWorkItem?
    private var subscriptions = Set<AnyCancellable>()

    static let character: CGFloat = 44
    /// Between the island and the screen's edge (or the Dock).
    static let gap: CGFloat = 10

    init(model: AppModel) {
        self.model = model
        super.init()
        state.mode = .panel
        state.rest = .panel
        state.collapse = { [weak self] in self?.hide() }
        state.hidesHeaderCharacter = true
        measure = NSHostingView(rootView: WidgetView(model: model, state: state))
        host = HoverHostingView(rootView: DrawerView(model: model, state: state, anim: anim,
                                                     drag: { [weak self] e in self?.drag(e) },
                                                     hover: { [weak self] inside in if inside { self?.touch() } }))
        // Files dropped on the island wait for the session it shows; Cloud's pleased.
        host.acceptsFiles = { [weak self] in (self?.shown ?? false) && (self?.model.hasSession ?? false) }
        host.onFileDrag = { [weak self] over in
            withAnimation(.easeOut(duration: 0.15)) { self?.state.dropHover = over }
            if over { self?.touch() }
        }
        host.onFileDrop = { [weak self] urls in
            guard let self, self.model.dropFiles(urls) else { return false }
            self.anim.pokes += 1
            self.dozeLater()
            return true
        }
        panel = WidgetPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // the panel draws its own; the window is mostly empty
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = host
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.setAccessibilityTitle("Clouding Bar")
        model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.refit() }
        }.store(in: &subscriptions)
    }

    func toggle() {
        guard !busy else { return }
        shown ? hide() : show()
    }

    // MARK: In

    func show() {
        guard !shown, !busy, let screen = NSScreen.screens.first else { return }
        shown = true
        busy = true
        dozeWork?.cancel()
        anim.reset()
        state.mode = .panel
        anim.panelHeight = measure.fittingSize.height
        panel.setFrame(homeFrame(screen), display: false)
        panel.orderFrontRegardless()
        let reduce = Palette.reduceMotion

        // Cloud climbs out of the corner, still asleep…
        withAnimation(reduce ? nil : .cb(0.45)) { anim.rise = 0 }
        var t = reduce ? 0 : 0.6
        // …wakes up with a stretch…
        after(t) { self.anim.awake = true }
        t += reduce ? 0 : 0.5
        // …hops twice…
        if !reduce {
            for _ in 0..<2 {
                after(t) { withAnimation(.easeOut(duration: 0.14)) { self.anim.hop = 16 } }
                after(t + 0.14) { withAnimation(.easeIn(duration: 0.14)) { self.anim.hop = 0 } }
                t += 0.3
            }
        }
        // …and the panel grows under it like a lift.
        after(t) {
            withAnimation(reduce ? nil : .cb(0.55)) { self.anim.lift = 1 }
        }
        after(t + (reduce ? 0 : 0.55)) {
            self.busy = false
            self.dozeLater()
        }
    }

    // MARK: Out

    func hide() {
        guard shown, !busy, let screen = NSScreen.screens.first else { return }
        busy = true
        dozeWork?.cancel()
        anim.awake = true
        panel.allowsKey = false
        let home = homeFrame(screen)
        let reduce = Palette.reduceMotion
        var t = 0.0
        // Back to the corner first, if it was moved.
        if panel.frame.origin != home.origin && !reduce {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.35
                ctx.timingFunction = Palette.curve
                panel.animator().setFrame(home, display: true)
            }
            t = 0.4
        } else {
            panel.setFrame(home, display: true)
        }
        // Cloud jumps on it: each landing presses the panel a third of the way down.
        if !reduce {
            for step in 1...3 {
                after(t) { withAnimation(.easeOut(duration: 0.12)) { self.anim.hop = 18 } }
                after(t + 0.12) {
                    withAnimation(.easeIn(duration: 0.16)) {
                        self.anim.hop = 0
                        self.anim.lift = max(0, 1 - CGFloat(step) / 3)
                    }
                }
                t += 0.3
            }
        }
        // Then it dozes off and ducks under the edge.
        after(t) {
            self.anim.awake = false
            withAnimation(reduce ? nil : .cb(0.3)) { self.anim.lift = 0 }
        }
        t += reduce ? 0 : 0.45
        after(t) { withAnimation(reduce ? nil : .cb(0.3)) { self.anim.rise = 1 } }
        after(t + (reduce ? 0 : 0.32)) {
            self.panel.orderOut(nil)
            self.shown = false
            self.busy = false
        }
    }

    // MARK: Touch

    /// The mouse came over Cloud: it wakes up (and dozes off again later).
    private func touch() {
        guard shown, !busy else { return }
        anim.awake = true
        dozeLater()
    }

    /// When Claude is idle, Cloud falls asleep 6 s after the last touch.
    private func dozeLater() {
        dozeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shown, !self.busy else { return }
            self.anim.awake = false
        }
        dozeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    // MARK: Island

    /// Drag Cloud to move the island anywhere; a click without moving pokes it.
    private func drag(_ event: NSEvent) {
        guard shown, !busy else { return }
        let start = NSEvent.mouseLocation
        let origin = panel.frame.origin
        var moved = false
        while let e = panel.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let p = NSEvent.mouseLocation
            if !moved && hypot(p.x - start.x, p.y - start.y) >= 3 { moved = true }
            if moved { panel.setFrameOrigin(NSPoint(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y)) }
            if e.type == .leftMouseUp { break }
        }
        if moved {
            anim.island = panel.frame.origin != (NSScreen.screens.first.map(homeFrame)?.origin ?? .zero)
        } else {
            anim.pokes += 1
        }
        anim.awake = true
        dozeLater()
    }

    // MARK: Size and place

    /// The window: the panel's full size plus room for Cloud, its hops and
    /// the gap under the island.
    private var contentSize: NSSize {
        let p = measure.fittingSize
        return NSSize(width: max(p.width, Self.character + 24),
                      height: p.height + Self.character + 18 + Self.gap)
    }

    /// At home the island stands at the bottom-left, just above the screen's
    /// edge (or the Dock), over the Touch Bar's left end.
    private func homeFrame(_ screen: NSScreen) -> NSRect {
        let size = contentSize
        let area = screen.visibleFrame
        return NSRect(x: area.minX + 16, y: area.minY, width: size.width, height: size.height)
    }

    private func refit() {
        guard shown else { return }
        panel.allowsKey = model.request != nil || model.config.taskQueue
        let size = contentSize
        anim.panelHeight = measure.fittingSize.height
        guard !busy, panel.frame.size != size else { return }
        // Grow or shrink keeping the foot where it is.
        panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: true)
    }

    private func after(_ seconds: Double, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

/// The moving parts, driven by DrawerController.
final class DrawerAnimation: ObservableObject {
    /// 1: Cloud is under the screen's edge; 0: up.
    @Published var rise: CGFloat = 1
    /// Cloud's jump height, in points.
    @Published var hop: CGFloat = 0
    /// How much of the panel is out (0…1).
    @Published var lift: CGFloat = 0
    /// Moved away from the corner.
    @Published var island = false
    /// Idle but awake: woken by the hops or a touch.
    @Published var awake = false
    /// Clicks on Cloud: each one makes it jump and smile.
    @Published var pokes = 0
    @Published var panelHeight: CGFloat = 0

    func reset() {
        rise = 1
        hop = 0
        lift = 0
        island = false
        awake = false
    }
}

/// Cloud on top, the panel under it, the pair floating `gap` above the
/// window's bottom (the screen's edge at home).
struct DrawerView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState
    @ObservedObject var anim: DrawerAnimation
    let drag: (NSEvent) -> Void
    var hover: (Bool) -> Void = { _ in }

    var body: some View {
        let c = DrawerController.character
        VStack(alignment: .leading, spacing: -8) { // Cloud stands on the panel's top edge
            MascotIcon(activity: model.request != nil ? .wait : model.activity, size: c,
                       awake: anim.awake, pokes: anim.pokes + model.cloudPokes)
                .frame(width: c, height: c)
                .overlay(CloudGrip(onMouseDown: drag, onHover: hover))
                .offset(y: -anim.hop + anim.rise * (c + DrawerController.gap + 6))
                .padding(.leading, 18)
                .zIndex(1)
                .accessibilityLabel("Clouding Bar — drag to move")
            // The lift: the panel grows up from its foot, rounded all the way.
            WidgetView(model: model, state: state)
                .frame(height: max(0, anim.panelHeight * anim.lift), alignment: .bottom)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .opacity(Double(min(1, anim.lift * 2.5)))
        }
        .padding(.bottom, DrawerController.gap)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

/// Mouse-downs on Cloud go to the controller (move or poke); so does hover.
struct CloudGrip: NSViewRepresentable {
    let onMouseDown: (NSEvent) -> Void
    var onHover: (Bool) -> Void = { _ in }

    final class GripView: NSView {
        var onMouseDown: ((NSEvent) -> Void)?
        var onHover: ((Bool) -> Void)?
        private var area: NSTrackingArea?
        override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                   owner: self, userInfo: nil)
            addTrackingArea(a)
            area = a
        }
        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
    }

    func makeNSView(context: Context) -> GripView {
        let v = GripView()
        v.onMouseDown = onMouseDown
        v.onHover = onHover
        return v
    }
    func updateNSView(_ view: GripView, context: Context) {
        view.onMouseDown = onMouseDown
        view.onHover = onHover
    }
}
