import AppKit

/// Presents an NSTouchBar on top of whatever app is frontmost.
///
/// Honesty corner: the NSTouchBar API itself is official AppKit, but Apple
/// never shipped a public way for a *background* app to put content on the
/// Touch Bar. Every Touch Bar customizer (Pock, MTMR, …) uses these same
/// two AppKit class methods, which have been stable since macOS 10.14.
/// We look them up at runtime and quietly do nothing if a future macOS
/// removes them — ClaudeBar degrades, it never crashes.
enum SystemModalTouchBar {
    private static let presentSelector =
        NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
    private static let dismissSelector =
        NSSelectorFromString("dismissSystemModalTouchBar:")

    static var isSupported: Bool {
        (NSTouchBar.self as AnyObject).responds(to: presentSelector)
    }

    static func present(_ bar: NSTouchBar) {
        guard isSupported else { return }
        _ = (NSTouchBar.self as AnyObject).perform(presentSelector, with: bar, with: nil)
    }

    static func dismiss(_ bar: NSTouchBar) {
        guard (NSTouchBar.self as AnyObject).responds(to: dismissSelector) else { return }
        _ = (NSTouchBar.self as AnyObject).perform(dismissSelector, with: bar)
    }
}
