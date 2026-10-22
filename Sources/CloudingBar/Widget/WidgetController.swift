import AppKit
import Combine
import SwiftUI

/// The floating widget's window: a non-activating panel above other windows
/// that never takes focus unless you click into it.
///
///   pill ── hover 2 s (or a click) ──▶ panel ── 400 ms after the mouse leaves ──▶ pill
///
/// With "Keep the pill visible" off, a 4 pt line stands in for the pill at
/// rest and wakes into it after a 250 ms hover.
///
/// A request (permission, question) opens the card by itself and keeps it
/// open until answered or until you've moused over it and left (not in Do
/// not disturb). The pill can be dragged anywhere; the strip can't.
///
/// Docked in the notch (`widgetAtNotch`) the pill is a black island around
/// the camera, or a drawn notch on Macs without one, and the panel grows
/// out of it. Drag the island away and it's the pill again, wherever you
/// drop it; drag the pill over the notch and it snaps in, docking on release.
final class WidgetController: NSObject {
    let model: AppModel
    let state = WidgetState()

    private var panel: WidgetPanel!
    private var host: HoverHostingView<WidgetWindow>!
    private var wakeWork: DispatchWorkItem?
    private var openWork: DispatchWorkItem?
    /// After a resize the pointer is still on the pill; don't pop the panel.
    private var suppressOpen = false
    private var overControl = false
    private var closeWork: DispatchWorkItem?
    private var hovering = false
    /// Opened by a request: stays open until the mouse has been in and out.
    private var pinned = false
    private var shownRequest: UUID?
    private var dragAnchor: CGPoint?
    private var gesture: PillGesture?
    /// While resizing away from the default spot: the end that stays put.
    private var fixedEdge: FixedEdge?
    private var subscriptions = Set<AnyCancellable>()
    private var layoutQueued = false
    /// After a drop: watches for the pointer leaving the panel.
    private var leaveWatch: Timer?
    /// Being dragged over the notch: it shows docked, and docks on release.
    private var dockPreview = false
    /// Switching between pill, panel and sessions: the window keeps the room
    /// both need for the length of the animation (the clear part doesn't
    /// show), so the views slide and fade instead of being cut off by a
    /// window that jumped to its new size; it fits itself afterwards.
    private var shownPhase = ""
    private var settleUntil = Date.distantPast
    private var settleWork: DispatchWorkItem?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Where the widget is, for Cloud's "another chat is done": its frame on
    /// screen and whether it's in the notch. Nil while hidden.
    var place: (frame: NSRect, notch: Bool)? {
        guard let panel, panel.isVisible else { return nil }
        return (panel.frame, atNotch)
    }

    init(model: AppModel) {
        self.model = model
        super.init()
        host = HoverHostingView(rootView: WidgetWindow(model: model, state: state))
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
        state.pillMouseDragged = { [weak self] _ in self?.pillMouseDragged() }
        state.pillMouseUp = { [weak self] _ in self?.pillMouseUp() }
        state.controlHover = { [weak self] inside in self?.controlHover(inside) }
        state.openPanel = { [weak self] in self?.set(.panel) }
        state.startTyping = { [weak self] in self?.beginTyping() }
        state.endTyping = { [weak self] in self?.endTyping() }
        host.acceptsFiles = { [weak model] in model?.hasSession ?? false }
        host.onFileDrag = { [weak self] over in self?.fileDrag(over) }
        host.onFileDrop = { [weak self] urls in self?.dropFiles(urls) ?? false }
        // Re-fit the window whenever what's shown changes.
        model.objectWillChange.sink { [weak self] in self?.queueLayout() }.store(in: &subscriptions)
        state.objectWillChange.sink { [weak self] in self?.queueLayout() }.store(in: &subscriptions)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Clicked away while writing in the pill: put the text box away (the
        // draft stays for next time).
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) {
            [weak self] _ in self?.endTyping()
        }
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
    private var rest: WidgetMode { model.config.pillAlwaysVisible || atNotch ? .pill : .strip }

    /// Called after every model refresh.
    func update() {
        // Dictated words to check: the widget takes the keyboard for them.
        let reviewing = model.dictated != nil
        if reviewing != wasReviewing {
            wasReviewing = reviewing
            if reviewing {
                updateKeyAllowance()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self, self.model.dictated != nil else { return }
                    self.panel.makeKey()
                }
            } else {
                releaseKey()
            }
        }
        let id = model.request?.id
        if id != shownRequest {
            shownRequest = id
            if id != nil {
                // In the notch the island itself grows to show it.
                if !model.config.doNotDisturb && !atNotch {
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
        if model.voiceShown && model.request == nil && state.mode != .pill { set(.pill) }
        if state.mode == .strip && rest == .pill { set(.pill) }
        if rest == .strip && !model.voiceShown && state.mode == .pill && !hovering && !pinned && model.request == nil {
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
        if state.pillHover != inside { withAnimation(.easeOut(duration: 0.15)) { state.pillHover = inside } }
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
            suppressOpen = false
            wakeWork?.cancel()
            openWork?.cancel()
            if pinned && state.mode == .panel { pinned = false } // seen it; normal rules from now on
            closeWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.hovering, !self.pinned, !self.model.voiceShown, !self.state.pillTyping else { return }
                self.set(self.rest)
            }
            closeWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }
    }

    /// Over a button on the wide pill, hovering doesn't open the panel.
    private func controlHover(_ inside: Bool) {
        overControl = inside
        if inside { openWork?.cancel() } else if hovering && state.mode == .pill { scheduleOpen() }
    }

    /// Pill → panel after 2 s with the mouse on it, unless that's off in
    /// Settings (a click opens it at once).
    private func scheduleOpen() {
        openWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hovering, self.state.mode == .pill, !self.model.voiceShown,
                  !self.suppressOpen, !self.overControl, self.state.pillEditSize == nil,
                  !self.state.pillTyping, !self.state.pillRearrange.isDragging else { return }
            self.set(.panel)
        }
        openWork = work
        guard model.config.hoverOpens else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func set(_ mode: WidgetMode) {
        guard state.mode != mode else { return }
        if mode != .pill { state.pillTyping = false }
        if mode != .panel { model.pickingModel = false; model.showingAgents = false }
        withAnimation(.cb(mode == .panel ? 0.28 : 0.22)) { state.mode = mode }
        updateKeyAllowance()
    }

    private var wasReviewing = false

    private func updateKeyAllowance() {
        // The queue's text field needs the keyboard too.
        let wants = state.mode == .panel && (model.request != nil || model.config.taskQueue)
            || state.mode == .pill && (state.pillTyping || model.dictated != nil)
        panel.allowsKey = wants
        if !wants { releaseKey() }
    }

    /// The panel is open.
    var panelOpen: Bool { state.mode == .panel }

    /// Cloud on the Touch Bar: opens the panel, which stays until Cloud is
    /// tapped again (or the pointer has been in and out); or folds it away.
    func togglePanel() {
        closeWork?.cancel()
        openWork?.cancel()
        if state.mode == .panel {
            pinned = false
            set(rest)
        } else {
            pinned = true
            set(.panel)
        }
    }

    /// Opens the panel at its message box (files just attached go with
    /// what you write there).
    func openMessage() {
        closeWork?.cancel()
        pinned = true
        set(.panel)
        guard model.config.taskQueue, model.request == nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.state.mode == .panel else { return }
            self.panel.makeKey()
            self.state.focusMessage += 1
        }
    }

    /// Hands the keyboard back to the app in front, if the widget has it.
    func releaseKey() {
        guard panel.isKeyWindow else { return }
        panel.orderOut(nil)
        panel.orderFrontRegardless()
    }

    // MARK: Chat

    /// The pill's chat was clicked: the window takes the keyboard (without
    /// activating the app, so your editor stays in front) for the text box.
    private func beginTyping() {
        guard state.mode == .pill, !state.pillTyping else { return }
        openWork?.cancel()
        panel.allowsKey = true
        panel.makeKey()
        withAnimation(.cb(0.2)) { state.pillTyping = true }
    }

    /// Sent, esc, or clicked away: back to the pill, the keyboard back to
    /// the editor.
    private func endTyping() {
        guard state.pillTyping else { return }
        withAnimation(.cb(0.2)) { state.pillTyping = false }
        updateKeyAllowance()
        suppressOpen = hovering // don't pop the panel under the pointer right after
    }

    // MARK: Files

    /// Files dragged over the widget: it lights up (the thin line turns
    /// into the pill first, so there's something to drop them on).
    private func fileDrag(_ over: Bool) {
        withAnimation(.easeOut(duration: 0.15)) { state.dropHover = over }
        if over {
            closeWork?.cancel()
            openWork?.cancel()
            if state.mode == .strip { set(.pill) }
        } else if !hovering {
            hover(false) // went away without dropping
        }
    }

    /// Files let go over the widget: they wait for the session it shows,
    /// and the panel opens with them in its message box (the cursor in the
    /// field, when writing is on).
    private func dropFiles(_ urls: [URL]) -> Bool {
        guard model.dropFiles(urls) else { return false }
        closeWork?.cancel()
        hovering = true
        pinned = false
        set(.panel)
        watchLeave()
        if model.config.taskQueue && model.request == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.state.mode == .panel else { return }
                self.panel.makeKey()
                self.state.focusMessage += 1
            }
        }
        return true
    }

    /// A drag sends no hover, so after a drop nothing would notice the
    /// pointer leaving: watch for it instead.
    private func watchLeave() {
        leaveWatch?.invalidate()
        leaveWatch = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            guard let self, self.state.mode == .panel else { timer.invalidate(); return }
            if !self.panel.frame.insetBy(dx: -2, dy: -2).contains(NSEvent.mouseLocation) {
                timer.invalidate()
                self.hover(false)
            }
        }
    }

    // MARK: Drag

    /// A press on the pill: on its outline it resizes, elsewhere it moves
    /// (or, without moving, opens the panel). Driven by the pill's own mouse
    /// events, so the screen keeps drawing while you pull.
    private enum PillGesture {
        case move(start: CGPoint, anchor: CGPoint, moved: Bool)
        case resize(Resize)
    }

    /// Pulling the outline: `h` −1/1 for the left/right end, `v` 1/−1 for
    /// the top/bottom (0: not that way); the opposite side stays put.
    private struct Resize {
        let start: CGPoint
        let size: CGSize
        let h: Int, v: Int
        /// At the default spot: it grows both ways and stays centred.
        let centered: Bool
        let bottom: CGFloat
        let most: CGFloat
        var raw: CGSize
    }

    private func pillMouseDown(_ event: NSEvent) {
        // While dictating, the pill is the stop button.
        if model.listening {
            model.voiceToggle()
            return
        }
        if state.pillTyping || model.dictated != nil { return }
        openWork?.cancel() // holding it: don't open the panel underneath
        let mouse = NSEvent.mouseLocation
        if state.mode == .pill, model.hasSession, model.request == nil, !model.listening,
           var rim = WidgetState.pillRim(event.locationInWindow, in: panel.frame.size) {
            let frame = panel.frame
            // In the notch it hangs from the top: its ends and bottom pull.
            if atNotch { rim.v = -1 }
            let centered = dragAnchor == nil && model.config.widgetPosition == nil
            fixedEdge = centered ? nil
                : rim.h == 1 ? FixedEdge(x: frame.minX, left: true) : FixedEdge(x: frame.maxX, left: false)
            let most = PillLayout(model: model).maxWidth + (atNotch ? state.notchWidth + 2 * NotchView.shoulder : 0)
            gesture = .resize(Resize(start: mouse, size: frame.size, h: rim.h, v: rim.v, centered: centered,
                                     bottom: frame.minY, most: most, raw: frame.size))
            withAnimation(.cb(0.15)) { state.pillEditSize = frame.size }
            layout()
        } else {
            gesture = .move(start: mouse, anchor: anchor, moved: false)
        }
    }

    private func pillMouseDragged() {
        let p = NSEvent.mouseLocation
        switch gesture {
        case let .move(start, startAnchor, moved):
            let dx = p.x - start.x, dy = p.y - start.y
            guard moved || hypot(dx, dy) >= 3 else { return }
            gesture = .move(start: start, anchor: startAnchor, moved: true)
            dragAnchor = CGPoint(x: startAnchor.x + dx, y: startAnchor.y + dy)
            // Over the notch it snaps in, out of it it's the pill again.
            dockPreview = overNotch(p)
            layout()
        case var .resize(r):
            // The pulled side follows the pointer.
            let dx = p.x - r.start.x, dy = p.y - r.start.y
            r.raw = CGSize(width: r.size.width + CGFloat(r.h) * dx * (r.centered ? 2 : 1),
                           height: r.size.height + CGFloat(r.v) * dy)
            gesture = .resize(r)
            // Past either end it gives a little, like a rubber band.
            func rubber(_ x: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
                x > high ? high + (x - high) * 0.2 : x < low ? low - (low - x) * 0.2 : x
            }
            let w = rubber(r.raw.width, PillLayout.minWidth, r.most)
            // Down to the bottom of the screen: once taller than wide, it
            // stands up as a column.
            let h = rubber(r.raw.height, atNotch ? state.notchHeight : PillLayout.height(rows: 1), screenRoom)
            state.pillEditSize = CGSize(width: w, height: h)
            // Pulling the top: the bottom stays, so the top moves.
            if r.v == 1 { dragAnchor = CGPoint(x: anchor.x, y: r.bottom + h) }
            layout()
        case nil:
            break
        }
    }

    private func pillMouseUp() {
        defer { gesture = nil }
        switch gesture {
        case let .move(_, _, moved):
            if moved && dockPreview {
                // Let go over the notch: docked.
                dockPreview = false
                dragAnchor = nil
                model.setConfig("widgetPosition", NSNull())
                model.setConfig("widgetAtNotch", true)
                layout()
            } else if moved, let a = dragAnchor {
                model.setConfig("widgetPosition", [Double(a.x), Double(a.y)])
                model.setConfig("widgetAtNotch", false)
            } else {
                set(.panel) // a click opens it right away
            }
        case let .resize(r) where atNotch:
            // The island: compact again if pulled in that far.
            let compact = r.raw.width <= NotchView.compactWidth(camera: state.notchWidth) + 24
            model.setConfig("notchWidth", compact ? 0 : Double(min(r.most, r.raw.width)))
            model.setConfig("notchHeight", compact ? 0 : Double(min(screenRoom, max(PillLayout.height(rows: 1), r.raw.height))))
            withAnimation(.cb(0.2)) { state.pillEditSize = nil }
            queueLayout()
            suppressOpen = true
        case let .resize(r):
            let height = min(screenRoom, max(PillLayout.height(rows: 1), r.raw.height))
            if PillLayout.isVertical(width: r.raw.width, height: height) {
                // A column keeps no spare width around what it shows.
                let natural = PillLayout(model: model).arrange(width: max(PillLayout.minWidth, r.raw.width), height: height).natural
                model.setConfig("pillWidth", Double(min(max(PillLayout.minWidth, r.raw.width), natural)))
            } else {
                // Pulled all the way: everything, now and whatever's added later.
                model.setConfig("pillWidth", r.raw.width >= r.most ? 10_000 : Double(max(0, r.raw.width)))
            }
            model.setConfig("pillHeight", Double(height))
            // Snap to what it shows, the opposite sides still in place.
            let size = PillLayout(model: model).arrange(width: model.pillBudget, height: model.pillHeightBudget).frame
            if fixedEdge != nil || r.v == 1 {
                var a = anchor
                if let fixed = fixedEdge { a.x = fixed.left ? fixed.x + size.width / 2 : fixed.x - size.width / 2 }
                if r.v == 1 { a.y = r.bottom + size.height }
                dragAnchor = a
                model.setConfig("widgetPosition", [Double(a.x), Double(a.y)])
            }
            fixedEdge = nil
            withAnimation(.cb(0.2)) { state.pillEditSize = nil }
            queueLayout()
            suppressOpen = true // the mouse is still on it; let it be until it leaves
        case nil:
            break
        }
    }

    // MARK: Placement

    /// The most height the pill can take: the screen's, under the menu bar.
    private var screenRoom: CGFloat {
        let target = NSScreen.screens.first { $0.frame.contains(anchor) } ?? screen
        return (docked ? target.frame : target.visibleFrame).height
    }

    private var screen: NSScreen { NSScreen.screens.first ?? NSScreen.main! }

    /// Docked in the notch (a drawn one on Macs without it).
    private var atNotch: Bool {
        model.config.widgetAtNotch && dragAnchor == nil && model.config.widgetPosition == nil
    }

    /// Docked, or dragged over the notch and about to be.
    private var docked: Bool { atNotch || dockPreview }

    static func hasNotch(_ screen: NSScreen?) -> Bool {
        guard #available(macOS 12, *), let screen else { return false }
        return screen.safeAreaInsets.top > 0
    }

    /// The camera's width (0: no notch, one is drawn) and the notch's height.
    static func notch(of screen: NSScreen) -> (width: CGFloat, height: CGFloat) {
        if #available(macOS 12, *), screen.safeAreaInsets.top > 0 {
            if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
                return (max(0, r.minX - l.maxX), screen.safeAreaInsets.top)
            }
            return (200, screen.safeAreaInsets.top)
        }
        return (0, 32)
    }

    /// Near enough to the notch to dock there: around it, at the very top.
    private func overNotch(_ p: CGPoint) -> Bool {
        let f = screen.frame
        let half = max(150, Self.notch(of: screen).width / 2 + 110)
        return abs(p.x - f.midX) < half && p.y > f.maxY - 60
    }

    /// With "Automatically hide the menu bar" the default spot is the top
    /// edge, where the menu bar slides in; stay above it there.
    private var menuBarHides: Bool {
        screen.frame.maxY - screen.visibleFrame.maxY < 1
    }

    private var level: NSWindow.Level {
        let defaultSpot = dragAnchor == nil && model.config.widgetPosition == nil
        return docked || (defaultSpot && menuBarHides) ? .statusBar : .floating
    }

    /// The widget's top center.
    private var anchor: CGPoint {
        if docked {
            // In the notch: the top of the screen, inside the menu bar.
            return CGPoint(x: screen.frame.midX, y: screen.frame.maxY)
        }
        if let a = dragAnchor ?? model.config.widgetPosition { return a }
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

    /// An end of the pill that stays put while the other is pulled.
    private struct FixedEdge { let x: CGFloat; let left: Bool }

    private func layout() {
        guard panel != nil else { return }
        // The island in the notch, or the pill.
        let notch = Self.notch(of: screen)
        if state.notchWidth != notch.width { state.notchWidth = notch.width }
        if state.notchHeight != notch.height { state.notchHeight = notch.height }
        if state.notched != docked {
            withAnimation(.cb(0.26)) { state.notched = docked }
            return // re-laid out once the view has changed (queueLayout)
        }
        // While its edge is pulled the pill is exactly as wide as the
        // pointer says (and measuring SwiftUI on every move is slow).
        var size: NSSize
        if state.mode == .pill, let e = state.pillEditSize {
            size = NSSize(width: max(PillLayout.minWidth, e.width), height: max(PillLayout.height(rows: 1), e.height))
        } else {
            size = host.fittingSize
        }
        guard size.width > 0, size.height > 0 else { return }
        // Pill, panel, sessions — or the notch growing for a question, for
        // writing, for dictation.
        let phase = "\(state.mode)|\(state.notched)|\(model.request?.id.uuidString ?? "")|\(state.pillTyping)|\(model.listening)|\(model.dictated != nil)"
        if phase != shownPhase {
            shownPhase = phase
            settleUntil = Date().addingTimeInterval(0.45)
            settleWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.layout() }
            settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.47, execute: work)
        }
        if Date() < settleUntil, gesture == nil, panel.isVisible {
            size = NSSize(width: max(size.width, panel.frame.width), height: max(size.height, panel.frame.height))
        }
        let a = anchor
        var frame = NSRect(x: a.x - size.width / 2, y: a.y - size.height, width: size.width, height: size.height)
        if let fixed = fixedEdge { frame.origin.x = fixed.left ? fixed.x : fixed.x - size.width }
        // Keep it on a screen.
        let target = NSScreen.screens.first { $0.frame.contains(a) } ?? screen
        let bounds = docked ? target.frame : target.visibleFrame
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

    // MARK: Files dropped on it

    /// A file is being dragged over the window (true) or went away (false).
    var onFileDrag: ((Bool) -> Void)?
    /// Files let go over the window; false refuses them.
    var onFileDrop: (([URL]) -> Bool)? {
        didSet { onFileDrop == nil ? unregisterDraggedTypes() : registerForDraggedTypes(FileDrop.types) }
    }
    /// Asked as a drag comes over: can files be taken right now?
    var acceptsFiles: () -> Bool = { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onFileDrop != nil, acceptsFiles(), FileDrop.canRead(sender.draggingPasteboard) else { return [] }
        onFileDrag?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard onFileDrop != nil, acceptsFiles(), FileDrop.canRead(sender.draggingPasteboard) else { return [] }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onFileDrag?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onFileDrag?(false)
        let urls = FileDrop.read(sender.draggingPasteboard)
        guard !urls.isEmpty, let onFileDrop else { return false }
        return onFileDrop(urls)
    }
}
