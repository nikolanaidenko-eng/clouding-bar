import AppKit

/// Puts BarView on the Touch Bar, system-modally (see SystemModalTouchBar),
/// and keeps it there: later updates change the view in place, so the bar
/// doesn't flicker. The physical Esc key disappears while a system-modal
/// bar is up, which is why BarView always draws its own.
final class TouchBarController: NSObject, NSTouchBarDelegate {
    let barView = BarView()
    private var presentedBar: NSTouchBar?
    private var presentedFullWidth = true
    private var presentedAt = Date.distantPast

    var isShowing: Bool { presentedBar != nil }

    /// `fullWidth`: over the Control Strip too; else next to it (put up
    /// again when that changes).
    func show(_ model: BarModel, fullWidth: Bool) {
        // Another width: the bar up now taken down first. Changed in it, the
        // new content showed squeezed there a moment, then again in the new
        // one — the chats list blinked and took taps only after (owner, 27.10).
        if presentedBar != nil && presentedFullWidth != fullWidth { hide() }
        barView.narrow = !fullWidth
        barView.update(model)
        // Taken off the Touch Bar meanwhile (a window of ours came to the
        // keyboard): put it back.
        if presentedBar != nil && barView.window == nil && Date().timeIntervalSince(presentedAt) > 5 { hide() }
        guard presentedBar == nil else { return }
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [.root]
        SystemModalTouchBar.present(bar, fullWidth: fullWidth)
        presentedBar = bar
        presentedFullWidth = fullWidth
        presentedAt = Date()
    }

    func hide() {
        guard let bar = presentedBar else { return }
        SystemModalTouchBar.dismiss(bar)
        presentedBar = nil
    }

    func touchBar(_ touchBar: NSTouchBar,
                  makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        guard identifier == .root else { return nil }
        let item = NSCustomTouchBarItem(identifier: identifier)
        item.view = barView
        return item
    }
}

private extension NSTouchBarItem.Identifier {
    static let root = Self("dev.cloudingbar.bar")
}
