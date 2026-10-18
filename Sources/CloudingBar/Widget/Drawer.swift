import AppKit
import Combine
import SwiftUI

/// The widget called up from the Touch Bar's character button.
///
///   in   Cloud (the character) climbs out of the bottom-left corner of the
///        screen, hops twice, and the panel rises under it like a lift.
///        From then on it's an island: drag Cloud to put it anywhere.
///   out  Tap the button again: the island flies back to the corner and
///        Cloud jumps on the panel, pushing it down a little with every
///        jump, until it's back under the edge — then Cloud ducks too.
final class DrawerController: NSObject {
    let model: AppModel
    let state = WidgetState()
    private let anim = DrawerAnimation()

    private var panel: WidgetPanel!
    private var host: HoverHostingView<DrawerView>!
    private var measure: NSHostingView<WidgetView>!
    private(set) var shown = false
    private var busy = false
    private var subscriptions = Set<AnyCancellable>()

    /// How far the panel's foot stays below the screen's edge at home.
    private static let tuck: CGFloat = 14
    static let character: CGFloat = 44

    init(model: AppModel) {
        self.model = model
        super.init()
        state.mode = .panel
        state.rest = .panel
        state.collapse = { [weak self] in self?.hide() }
        state.hidesHeaderCharacter = true
        measure = NSHostingView(rootView: WidgetView(model: model, state: state))
        host = HoverHostingView(rootView: DrawerView(model: model, state: state, anim: anim,
                                                     drag: { [weak self] e in self?.drag(e) }))
        panel = WidgetPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // the panel draws its own; the window is mostly empty
        panel.level = .floating // under the Dock, so a showing Dock covers the foot
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
        anim.reset()
        state.mode = .panel
        anim.panelHeight = measure.fittingSize.height
        panel.setFrame(homeFrame(screen), display: false)
        panel.orderFrontRegardless()
        let reduce = Palette.reduceMotion

        // Cloud climbs out of the corner…
        withAnimation(reduce ? nil : .cb(0.35)) { anim.rise = 0 }
        var t = reduce ? 0 : 0.35
        // …hops twice…
        if !reduce {
            for _ in 0..<2 {
                after(t) { withAnimation(.easeOut(duration: 0.14)) { self.anim.hop = 16 } }
                after(t + 0.14) { withAnimation(.easeIn(duration: 0.14)) { self.anim.hop = 0 } }
                t += 0.3
            }
        }
        // …and the panel comes up under it like a lift.
        after(t) {
            withAnimation(reduce ? nil : .cb(0.5)) { self.anim.lift = 1 }
        }
        after(t + (reduce ? 0 : 0.5)) { self.busy = false }
    }

    // MARK: Out

    func hide() {
        guard shown, !busy, let screen = NSScreen.screens.first else { return }
        busy = true
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
        // Cloud jumps on it: each landing pushes the lift a third of the way down.
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
        // Then Cloud ducks under the edge too.
        after(t) { withAnimation(reduce ? nil : .cb(0.25)) { self.anim.lift = 0; self.anim.rise = 1 } }
        after(t + (reduce ? 0 : 0.28)) {
            self.panel.orderOut(nil)
            self.shown = false
            self.busy = false
        }
    }

    // MARK: Island

    /// Drag Cloud to move the island anywhere.
    private func drag(_ event: NSEvent) {
        guard shown, !busy else { return }
        let start = NSEvent.mouseLocation
        let origin = panel.frame.origin
        while let e = panel.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let p = NSEvent.mouseLocation
            panel.setFrameOrigin(NSPoint(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y))
            if e.type == .leftMouseUp { break }
        }
        anim.island = panel.frame.origin.y > (NSScreen.screens.first?.frame.minY ?? 0)
    }

    // MARK: Size and place

    /// The window: the panel's full size plus room for Cloud and its hops.
    private var contentSize: NSSize {
        let p = measure.fittingSize
        return NSSize(width: max(p.width, Self.character + 24), height: p.height + Self.character + 18)
    }

    /// At home the panel sits above the bar's left end, its foot tucked under
    /// the screen's bottom edge.
    private func homeFrame(_ screen: NSScreen) -> NSRect {
        let size = contentSize
        return NSRect(x: screen.frame.minX + 16, y: screen.frame.minY - Self.tuck, width: size.width, height: size.height)
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
    /// 1: Cloud is under the screen's edge; 0: sitting up.
    @Published var rise: CGFloat = 1
    /// Cloud's jump height, in points.
    @Published var hop: CGFloat = 0
    /// How much of the panel is out (0…1).
    @Published var lift: CGFloat = 0
    /// Moved away from the corner: a free-standing island.
    @Published var island = false
    @Published var panelHeight: CGFloat = 0

    func reset() {
        rise = 1
        hop = 0
        lift = 0
        island = false
    }
}

/// Cloud on top, the panel under it, both rising from the bottom edge.
struct DrawerView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState
    @ObservedObject var anim: DrawerAnimation
    let drag: (NSEvent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: -8) { // Cloud stands on the panel's top edge
            MascotIcon(activity: model.request != nil ? .wait : model.activity, size: DrawerController.character)
                .frame(width: DrawerController.character, height: DrawerController.character)
                .overlay(CloudGrip(onMouseDown: drag))
                .offset(y: -anim.hop + anim.rise * (DrawerController.character + 20))
                .padding(.leading, 18) // over the corner it came out of
                .zIndex(1)
                .accessibilityLabel("Clouding Bar — drag to move")
            WidgetView(model: model, state: state)
                .frame(height: max(0, anim.panelHeight * anim.lift), alignment: .top)
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }
}

/// Mouse-downs on Cloud go to the controller (it moves the island).
struct CloudGrip: NSViewRepresentable {
    let onMouseDown: (NSEvent) -> Void

    final class GripView: NSView {
        var onMouseDown: ((NSEvent) -> Void)?
        override func mouseDown(with event: NSEvent) { onMouseDown?(event) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    }

    func makeNSView(context: Context) -> GripView {
        let v = GripView()
        v.onMouseDown = onMouseDown
        return v
    }
    func updateNSView(_ view: GripView, context: Context) { view.onMouseDown = onMouseDown }
}
