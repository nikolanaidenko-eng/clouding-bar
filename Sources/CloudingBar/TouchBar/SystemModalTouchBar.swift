import AppKit

/// Shows one of our Touch Bars over whatever app is in front.
///
/// NSTouchBar is public AppKit; putting one on screen for an app in the
/// background isn't. AppKit has class methods for that — macOS's own
/// system-wide bars use them, and so does every Touch Bar tool — found here
/// by name at run time. Should a future macOS drop them, nothing shows and
/// nothing breaks.
///
/// Placement 1 is the whole width, Apple's Control Strip (brightness,
/// volume, Siri) put away meanwhile. Without it, the bar sits beside the
/// strip.
enum SystemModalTouchBar {
    private typealias ShowPlaced = @convention(c) (AnyObject, Selector, NSTouchBar, Int64, NSString?) -> Void

    private static let showPlaced = NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
    private static let show = NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
    private static let hide = NSSelectorFromString("dismissSystemModalTouchBar:")
    private static var touchBarClass: AnyObject { NSTouchBar.self }

    static var isSupported: Bool {
        touchBarClass.responds(to: showPlaced) || touchBarClass.responds(to: show)
    }

    static func present(_ bar: NSTouchBar, fullWidth: Bool = true) {
        if fullWidth, let method = class_getClassMethod(NSTouchBar.self, showPlaced) {
            let call = unsafeBitCast(method_getImplementation(method), to: ShowPlaced.self)
            call(touchBarClass, showPlaced, bar, 1, nil)
        } else if touchBarClass.responds(to: show) {
            _ = touchBarClass.perform(show, with: bar, with: nil)
        }
    }

    static func dismiss(_ bar: NSTouchBar) {
        if touchBarClass.responds(to: hide) { _ = touchBarClass.perform(hide, with: bar) }
    }
}
