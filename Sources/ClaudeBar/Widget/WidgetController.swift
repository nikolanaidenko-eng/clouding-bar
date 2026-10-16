import AppKit
import Combine
import SwiftUI

/// The floating widget's window: a non-activating panel above other windows
/// that never takes focus unless you click into it.
///
///   pill ── hover 3 s (or a click) ──▶ panel ── 400 ms after the mouse leaves ──▶ pill
///
/// With "Keep the pill visible" off, a 4 pt line stands in for the pill at
/// rest and wakes into it after a 250 ms hover.
///
/// A request (permission, question) opens the card by itself and keeps it
/// open until answered or until you've moused over it and left (not in Do
/// not disturb). The pill can be dragged anywhere; the strip can't.
final class WidgetController: NSObject {
    let model: AppModel
    let state = WidgetState()

    private var panel: WidgetPanel!
    private var host: HoverHostingView<WidgetView>!
    private var wakeWork: DispatchWorkItem?
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?
    private var hovering = false
    /// Opened by a request: stays open until the mouse has been in and out.
    private var pinned = false
    private var shownRequest: UUID?
    private var dragAnchor: CGPoint?
    private var subscriptions = Set<AnyCancellable>()
    private var layoutQueued = false

    var isVisible: Bool { panel?.isVisible ?? false }

    init(model: AppModel) {
        self.model = model
        super.init()
        host = HoverHostingView(rootView: WidgetView(model: model, state: state))
        host.onHover = { [weak self] inside in self?.hover(inside) }
        panel = WidgetPanel(contentRect: NSRect(x: 0, y: 0, width: 88, height: 10),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = host
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.setAccessibilityTitle("Clouding Bar")

        state.pillMouseDown = { [weak self] event in self?.pillMouseDown(event) }
        // Re-fit the window whenever what's shown changes.
        model.objectWillChange.sink { [weak self] in self?.queueLayout() }.store(in: &subscriptions)
        state.objectWillChange.sink { [weak self] in self?.queueLayout() }.store(in: &subscriptions)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func show() {
        guard !panel.isVisible else { return }
        panel.level = level
        layout()
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
        state.mode = rest
    }

    /// At rest: the pill (default), or a thin line if you'd rather.
    private var rest: WidgetMode { model.config.pillAlwaysVisible ? .pill : .strip }

    /// Called after every model refresh.
    func update() {
        let id = model.request?.id
        if id != shownRequest {
            shownRequest = id
            if id != nil {
                if !model.config.doNotDisturb {
                    pinned = true
                    set(.pill)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                        guard let self, self.model.request?.id == id else { return }
                        self.set(.panel)
                    }
                }
            } else if pinned {
                pinned = false
                if !hovering { set(rest) }
            } else if state.mode == .panel && !hovering {
                set(rest)
            }
        }
        state.rest = rest
        updateKeyAllowance()
        // While you dictate, the pill shows the words as they come, so an
        // open panel folds away.
        if model.listening && model.request == nil && state.mode != .pill { set(.pill) }
        if state.mode == .strip && rest == .pill { set(.pill) }
        if rest == .strip && !model.listening && state.mode == .pill && !hovering && !pinned && model.request == nil {
            set(.strip)
        }
    }

    func resetPosition() {
        dragAnchor = nil
        layout()
    }

    // MARK: Hover

    private func hover(_ inside: Bool) {
        hovering = inside
        if inside {
            closeWork?.cancel()
            if state.mode == .strip {
                // Only a deliberate hover wakes it: the mouse crosses the top
                // of the screen on its way to the menu bar or a title bar.
                wakeWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.hovering, self.state.mode == .strip,
                          NSEvent.pressedMouseButtons == 0 else { return }
                    self.set(.pill)
                    self.scheduleOpen()
                }
                wakeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
            } else if state.mode == .pill {
                scheduleOpen()
            }
        } else {
            wakeWork?.cancel()
            openWork?.cancel()
            if pinned && state.mode == .panel { pinned = false } // seen it; normal rules from now on
            closeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.hovering, !self.pinned, !self.model.listening else { return }
                self.set(self.rest)
            }
            closeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    /// Pill → panel after 3 s with the mouse on it (a click opens it at once).
    private func scheduleOpen() {
        openWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hovering, self.state.mode == .pill, !self.model.listening else { return }
            self.set(.panel)
        }
        openWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func set(_ mode: WidgetMode) {
        guard state.mode != mode else { return }
        withAnimation(.cb(mode == .panel ? 0.28 : 0.22)) { state.mode = mode }
        updateKeyAllowance()
    }

    private func updateKeyAllowance() {
        // The queue's text field needs the keyboard too.
        let wants = state.mode == .panel && (model.request != nil || model.config.taskQueue)
        panel.allowsKey = wants
        if !wants { releaseKey() }
    }

    /// Hands the keyboard back to the app in front, if the widget has it.
    func releaseKey() {
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    // MARK: Drag

    private func pillMouseDown(_ event: NSEvent) {
        // While dictating, the pill is the stop button.
        if model.listening {
            model.voiceToggle()
            return
        }
        let start = NSEvent.mouseLocation
        let startAnchor = anchor
        var moved = false
        while let next = panel.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let p = NSEvent.mouseLocation
            let dx = p.x - start.x, dy = p.y - start.y
            if !moved && hypot(dx, dy) >= 3 { moved = true }
            if moved {
                dragAnchor = CGPoint(x: startAnchor.x + dx, y: startAnchor.y + dy)
                layout()
            }
            if next.type == .leftMouseUp { break }
        }
        if moved, let a = dragAnchor {
            model.setConfig("widgetPosition", [Double(a.x), Double(a.y)])
            model.setConfig("widgetAtNotch", false)
        } else {
            set(.panel) // a click opens it right away
        }
    }

    // MARK: Placement

    private var screen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }

    /// On Macs with a notch, and only when asked to.
    private var atNotch: Bool {
        model.config.widgetAtNotch && dragAnchor == nil && model.config.widgetPosition == nil && hasNotch(screen)
    }

    static func hasNotch(_ screen: NSScreen?) -> Bool {
        guard #available(macOS 12, *), let screen else { return false }
        return screen.safeAreaInsets.top > 0
    }
    private func hasNotch(_ screen: NSScreen) -> Bool { Self.hasNotch(screen) }

    /// With "Automatically hide the menu bar" the default spot is the top
    /// edge, where the menu bar slides in; stay above it there.
    private var menuBarHides: Bool {
        screen.frame.maxY - screen.visibleFrame.maxY < 1
    }

    private var level: NSWindow.Level {
        let defaultSpot = dragAnchor == nil && model.config.widgetPosition == nil
        return atNotch || (defaultSpot && menuBarHides) ? .statusBar : .floating
    }

    /// The widget's top center.
    private var anchor: CGPoint {
        if let a = dragAnchor ?? model.config.widgetPosition { return a }
        if atNotch {
            // Hang from the notch: the top of the screen, inside the menu bar.
            return CGPoint(x: screen.frame.midX, y: screen.frame.maxY)
        }
        // Top center, right under the menu bar.
        return CGPoint(x: screen.frame.midX, y: screen.visibleFrame.maxY)
    }

    private func queueLayout() {
        guard !layoutQueued else { return }
        layoutQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.layoutQueued = false
            self?.layout()
        }
    }

    private func layout() {
        guard panel != nil else { return }
        let size = host.fittingSize
        guard size.width > 0, size.height > 0 else { return }
        let a = anchor
        var frame = NSRect(x: a.x - size.width / 2, y: a.y - size.height, width: size.width, height: size.height)
        // Keep it on a screen.
        let target = NSScreen.screens.first { $0.frame.contains(a) } ?? screen
        let bounds = atNotch ? target.frame : target.visibleFrame
        frame.origin.x = min(max(frame.minX, bounds.minX), bounds.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, bounds.minY), bounds.maxY - frame.height)
        panel.level = level
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    @objc private func screensChanged() { layout() }
}

/// Takes the keyboard only while a request card is open (the "Other"
/// field, ⏎ / esc), and without activating the app. Otherwise a click on
/// the widget would leave your typing — and the buttons' keystrokes —
/// going to the widget instead of your editor.
final class WidgetPanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
}

/// Reports the mouse entering and leaving the whole widget.
final class HoverHostingView<Content: View>: NSHostingView<Content> {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
