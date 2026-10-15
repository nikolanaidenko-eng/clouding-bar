import AppKit

/// Presents an NSTouchBar on top of whatever app is frontmost.
///
/// Honesty corner: the NSTouchBar API itself is official AppKit, but Apple
/// never shipped a public way for a *background* app to put content on the
/// Touch Bar. Every Touch Bar customizer (Pock, MTMR, …) uses these same
/// AppKit class methods, stable since macOS 10.14. We look them up at
/// runtime and quietly do nothing if a future macOS removes them.
///
/// The placement variant (placement 1) takes the full width of the Touch
/// Bar, hiding the Control Strip (volume, brightness, Siri) while ClaudeBar
/// is up. If it's missing we fall back to the classic call, which keeps the
/// Control Strip on the right.
enum SystemModalTouchBar {
    private static let presentWithPlacementSelector =
        NSSelectorFromString("presentSystemModalTouchBar:placement:systemTrayItemIdentifier:")
    private static let presentSelector =
        NSSelectorFromString("presentSystemModalTouchBar:systemTrayItemIdentifier:")
    private static let dismissSelector =
        NSSelectorFromString("dismissSystemModalTouchBar:")

    private typealias PresentWithPlacement =
        @convention(c) (AnyObject, Selector, NSTouchBar, Int64, NSString?) -> Void

    static var isSupported: Bool {
        let cls = NSTouchBar.self as AnyObject
        return cls.responds(to: presentWithPlacementSelector) || cls.responds(to: presentSelector)
    }

    static func present(_ bar: NSTouchBar, fullWidth: Bool = true) {
        let cls: AnyObject = NSTouchBar.self
        if fullWidth, let method = class_getClassMethod(NSTouchBar.self, presentWithPlacementSelector) {
            let fn = unsafeBitCast(method_getImplementation(method), to: PresentWithPlacement.self)
            fn(cls, presentWithPlacementSelector, bar, 1, nil)
            return
        }
        guard cls.responds(to: presentSelector) else { return }
        _ = cls.perform(presentSelector, with: bar, with: nil)
    }

    static func dismiss(_ bar: NSTouchBar) {
        guard (NSTouchBar.self as AnyObject).responds(to: dismissSelector) else { return }
        _ = (NSTouchBar.self as AnyObject).perform(dismissSelector, with: bar)
    }
}
