import AppKit
import Combine
import SwiftUI

/// The widget called up from the Touch Bar: it slides up out of the bottom
/// edge of the screen, above where the bar's character button sits, and
/// stays tucked a little under that edge — peeking out from behind it (and
/// from behind the Dock, when the Dock is showing). Tap the button again,
/// or move the mouse in and out, and it slides back down.
final class DrawerController: NSObject {
    let model: AppModel
    let state = WidgetState()

    private var panel: WidgetPanel!
    private var host: HoverHostingView<WidgetView>!
    private var shown = false
    private var visited = false
    private var hideWork: DispatchWorkItem?
    private var subscriptions = Set<AnyCancellable>()

    /// How far its bottom stays below the screen's edge.
    private static let tuck: CGFloat = 14

    var isShown: Bool { shown }

    init(model: AppModel) {
        self.model = model
        super.init()
        state.mode = .panel
        state.rest = .panel
        state.collapse = { [weak self] in self?.hide() }
        host = HoverHostingView(rootView: WidgetView(model: model, state: state))
        host.onHover = { [weak self] inside in self?.hover(inside) }
        panel = WidgetPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Below the Dock, so a showing Dock covers its lower edge.
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = host
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.setAccessibilityTitle("Clouding Bar")
        model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.refit() }
        }.store(in: &subscriptions)
    }

    func toggle() { shown ? hide() : show() }

    func show() {
        guard !shown, let screen = NSScreen.screens.first else { return }
        shown = true
        visited = false
        state.mode = .panel
        let size = host.fittingSize
        let x = screen.frame.minX + 16 // above the bar's left end, where the button is
        var start = NSRect(x: x, y: screen.frame.minY - size.height, width: size.width, height: size.height)
        panel.setFrame(start, display: false)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        start.origin.y = screen.frame.minY - Self.tuck
        animate(to: start, duration: Palette.reduceMotion ? 0 : 0.38)
        scheduleHide(after: 8) // nobody came: tuck it away again
    }

    func hide() {
        guard shown, let screen = NSScreen.screens.first else { return }
        shown = false
        hideWork?.cancel()
        panel.allowsKey = false
        var end = panel.frame
        end.origin.y = screen.frame.minY - end.height
        animate(to: end, duration: Palette.reduceMotion ? 0 : 0.26) { [weak self] in
            guard let self, !self.shown else { return }
            self.panel.orderOut(nil)
        }
    }

    private func animate(to frame: NSRect, duration: Double, done: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = duration
            ctx.timingFunction = Palette.curve
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: done)
    }

    /// Keeps the bottom tucked under the edge as its content grows or shrinks.
    private func refit() {
        guard shown, let screen = NSScreen.screens.first else { return }
        panel.allowsKey = model.request != nil || model.config.taskQueue
        let size = host.fittingSize
        let frame = NSRect(x: screen.frame.minX + 16, y: screen.frame.minY - Self.tuck,
                           width: size.width, height: size.height)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    private func hover(_ inside: Bool) {
        if inside {
            visited = true
            hideWork?.cancel()
        } else if visited {
            scheduleHide(after: 0.6)
        }
    }

    private func scheduleHide(after seconds: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.model.listening else { return }
            self.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}
