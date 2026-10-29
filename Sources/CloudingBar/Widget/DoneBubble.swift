import AppKit
import SwiftUI

/// Another chat is done: the widget shows one chat, and a different one has
/// just finished its work. Cloud peeks out from behind the pill (drops down
/// from the notch, or climbs out of the screen's bottom-left corner while
/// the widget is hidden), hops, and says which chat it was. Click it to go
/// there. With the chat's answer known, the bubble says how it begins (its
/// first lines, or ✦ and Apple's short form of it). A few seconds later —
/// longer while the pointer is on it — Cloud ducks back.
final class DoneBubbleController {
    struct Alert: Equatable {
        let id: String
        let name: String
        /// "24H · Desktop": where the chat is.
        let detail: String
        let color: UInt32
        /// The chat's Cloud (its colorIndex), for a done chat; nil: the classic one.
        var variant: Int?
        /// The start of its answer (AnswerPreview); nil: not known (yet).
        var answer: String?
    }

    /// Cloud's bubble was clicked: go to that chat.
    var onOpen: ((String) -> Void)?
    /// Cloud out of the widget (1 up, -1 down) and back home (0): the
    /// widget's own Cloud leaves meanwhile, there aren't two (owner, 27.10).
    var onAway: ((Int) -> Void)?
    private(set) var shown: Alert?
    private(set) var hovering = false

    private let anim = DoneBubbleAnimation()
    private var panel: WidgetPanel!
    private var steps: [DispatchWorkItem] = []

    static let size = NSSize(width: 360, height: 66)
    /// Wider and taller for two lines of the answer.
    static func size(for alert: Alert?) -> NSSize {
        alert?.answer == nil ? size : NSSize(width: 400, height: 100)
    }

    init() {
        let view = DoneBubbleView(anim: anim,
                                  open: { [weak self] in self?.open() },
                                  hover: { [weak self] inside in self?.hovering = inside })
        panel = WidgetPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: view)
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.setAccessibilityTitle("Clouding Bar: a chat is done")
    }

    /// `anchor`: the widget's frame on screen and whether it's in the notch;
    /// nil when it's hidden (then the screen's corner). Out for `stay` seconds.
    func show(_ alert: Alert, anchor: (frame: NSRect, notch: Bool)?, stay: TimeInterval = 4.5) {
        cancelSteps()
        shown = alert
        hovering = false
        let screen = NSScreen.screens.first(where: { s in anchor.map { s.frame.intersects($0.frame) } ?? false })?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame ?? .zero
        let size = Self.size(for: alert)
        var origin: NSPoint
        var fromAbove: Bool
        if let anchor, !anchor.notch, anchor.frame.maxY + size.height <= screen.maxY {
            // Out from behind the pill's top edge.
            origin = NSPoint(x: anchor.frame.minX + 6, y: anchor.frame.maxY - 2)
            fromAbove = false
        } else if let anchor {
            // Down from the notch (or from a pill with no room above it).
            origin = NSPoint(x: anchor.notch ? anchor.frame.midX - 30 : anchor.frame.minX + 6,
                             y: anchor.frame.minY - size.height + 2)
            fromAbove = true
        } else {
            origin = NSPoint(x: screen.minX + 16, y: screen.minY)
            fromAbove = false
        }
        origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)

        anim.alert = alert
        anim.fromAbove = fromAbove
        anim.out = 0
        anim.bubble = 0
        panel.orderFrontRegardless()
        // Out of the widget itself: its Cloud goes the way this one comes.
        onAway?(anchor == nil ? 0 : fromAbove ? -1 : 1)
        let reduce = Palette.reduceMotion
        withAnimation(reduce ? nil : .cb(0.4)) { anim.out = 1 }
        // A hop, the bubble, a second hop.
        step(reduce ? 0 : 0.42) {
            self.anim.pokes += 1
            withAnimation(reduce ? nil : .cb(0.3)) { self.anim.bubble = 1 }
        }
        if !reduce { step(0.9) { self.anim.pokes += 1 } }
        scheduleHide(after: stay)
    }

    /// The answer's start came, or changed (Apple's short form), while Cloud
    /// is out: in place, the bubble grown for it.
    func setAnswer(_ answer: String?) {
        guard var alert = shown, alert.answer != answer else { return }
        alert.answer = answer
        shown = alert
        let size = Self.size(for: alert)
        if size != panel.frame.size {
            var frame = panel.frame
            // Down from the notch its top stays where it is; else its bottom does.
            if anim.fromAbove { frame.origin.y = frame.maxY - size.height }
            frame.size = size
            if let screen = panel.screen?.visibleFrame {
                frame.origin.x = min(max(frame.origin.x, screen.minX + 4), screen.maxX - size.width - 4)
            }
            panel.setFrame(frame, display: true)
        }
        anim.alert = alert
    }

    /// Cloud ducks back (now, or once the pointer has left it).
    func hide() {
        cancelSteps()
        guard shown != nil else { return }
        let reduce = Palette.reduceMotion
        withAnimation(reduce ? nil : .cb(0.2)) { anim.bubble = 0 }
        step(reduce ? 0 : 0.18) { withAnimation(reduce ? nil : .cb(0.35)) { self.anim.out = 0 } }
        // Home again as this one ducks back.
        step(reduce ? 0 : 0.36) { self.onAway?(0) }
        step(reduce ? 0 : 0.58) {
            self.panel.orderOut(nil)
            self.shown = nil
        }
    }

    private func scheduleHide(after seconds: Double) {
        step(seconds) {
            if self.hovering { self.scheduleHide(after: 1.5) } else { self.hide() }
        }
    }

    private func open() {
        guard let id = shown?.id else { return }
        onOpen?(id)
        hide()
    }

    private func step(_ seconds: Double, _ work: @escaping () -> Void) {
        let item = DispatchWorkItem(block: work)
        steps.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func cancelSteps() {
        steps.forEach { $0.cancel() }
        steps = []
    }
}

final class DoneBubbleAnimation: ObservableObject {
    @Published var alert: DoneBubbleController.Alert?
    /// From the notch: Cloud comes down instead of up.
    @Published var fromAbove = false
    /// 0: hidden behind the edge; 1: out.
    @Published var out: CGFloat = 0
    /// The speech bubble beside Cloud (0…1).
    @Published var bubble: CGFloat = 0
    /// Each one: a jump and a smile.
    @Published var pokes = 0
}

/// Cloud and its bubble: "✓ Mail drafts", how its answer begins, "Done · your turn".
struct DoneBubbleView: View {
    @ObservedObject var anim: DoneBubbleAnimation
    let open: () -> Void
    let hover: (Bool) -> Void

    /// The second line: where the chat is.
    private var detail: String {
        guard let alert = anim.alert else { return "" }
        return "Done · your turn" + (alert.detail.isEmpty ? "" : " · " + alert.detail)
    }

    var body: some View {
        let size = DoneBubbleController.size(for: anim.alert)
        let color = Color(NSColor(hex: anim.alert?.color ?? 0x0A84FF))
        HStack(spacing: 8) {
            MascotIcon(activity: .sleep, size: 40, awake: true, pokes: anim.pokes, variant: anim.alert?.variant)
                .frame(width: 40, height: 40)
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(anim.alert?.name ?? "")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let answer = anim.alert?.answer {
                        Text(answer)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.88))
                            .lineLimit(2)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(Color(NSColor(hex: 0xA1A1A6)))
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(NSColor(hex: 0x1C1C1E)).opacity(0.96))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(color.opacity(0.7), lineWidth: 1))
            )
            .scaleEffect(0.85 + 0.15 * anim.bubble, anchor: .leading)
            .opacity(Double(anim.bubble))
            .onTapGesture(perform: open)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Opens that chat")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(width: size.width, height: size.height, alignment: .leading)
        // Out from behind the edge: below it (or above, from the notch) it's hidden.
        .offset(y: (1 - anim.out) * (anim.fromAbove ? -size.height : size.height))
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .onHover(perform: hover)
    }
}
