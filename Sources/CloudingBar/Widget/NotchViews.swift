import SwiftUI

/// The black shape of a notch: flush with the top of the screen, where it
/// curves out into the edge (the shoulders), rounded at the bottom.
struct NotchShape: Shape {
    var shoulder: CGFloat = NotchView.shoulder
    var radius: CGFloat = 12

    func path(in r: CGRect) -> Path {
        let s = min(shoulder, r.width / 4), rad = min(radius, r.height / 2, (r.width - 2 * s) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + s, y: r.minY + s), control: CGPoint(x: r.minX + s, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - rad))
        p.addQuadCurve(to: CGPoint(x: r.minX + s + rad, y: r.maxY), control: CGPoint(x: r.minX + s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - s - rad, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - s, y: r.maxY - rad), control: CGPoint(x: r.maxX - s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + s))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - s, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// The widget docked in the notch (owner's request, 19.10): a black island
/// around the camera — or a drawn notch on Macs without one. Left of the
/// camera Cloud and the 5-hour limit, right of it the context, each with
/// its little bar. It widens for what's being dictated or what Claude asks,
/// and lights up blue while files are dragged over it. Hover or click
/// opens the panel under it; drag it away to put the widget anywhere, drag
/// it back over the notch to dock it again.
struct NotchView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: WidgetState

    /// The concave curve at each top corner, where it meets the screen edge.
    static let shoulder: CGFloat = 8
    /// Each side of the camera, at least.
    static let ear: CGFloat = 92

    var body: some View {
        HStack(spacing: 0) {
            left.frame(minWidth: Self.ear, alignment: .leading)
            // The camera (or, drawn, a narrow gap between the two sides).
            Color.clear.frame(width: max(state.notchWidth, 14))
            right.frame(minWidth: Self.ear, alignment: .trailing)
        }
        .lineLimit(1)
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
        .foregroundColor(.white)
        .padding(.leading, Self.shoulder + 10)
        .padding(.trailing, Self.shoulder + 12)
        .padding(.horizontal, state.pillHover ? 3 : 0) // a little give under the pointer
        .frame(height: state.notchHeight)
        .background(PillDragHandle(state: state, resizable: false))
        .background(NotchShape().fill(Color.black))
        .overlay(state.dropHover ? NotchShape().stroke(Color.cbAction, lineWidth: 2) : nil)
        .animation(.cb(0.22), value: state.pillHover)
        .animation(.cb(0.28), value: model.listening)
        .animation(.cb(0.28), value: model.request?.id)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Clouding Bar: \(model.statusTitle)")
    }

    private var left: some View {
        HStack(spacing: 8) {
            MascotIcon(activity: model.request != nil ? .wait : model.activity, size: 20)
                .frame(width: 20, height: 20)
                .overlay(FileBadge(text: state.dropHover ? "+" : model.attachments.isEmpty ? nil : "\(model.attachments.count)")
                    .offset(x: 5, y: -3), alignment: .topTrailing)
            if model.listening {
                Icon(kind: .mic, size: 13, lineWidth: 1.8).foregroundColor(.cbAction)
            } else if model.hasSession {
                MeterBar(percent: model.sessionPercent, height: 3, track: .white.opacity(0.2))
                    .frame(width: 26)
                Text(PillLayout.percent(model.sessionPercent))
            }
        }
    }

    @ViewBuilder private var right: some View {
        if model.listening {
            Text(model.heard.isEmpty ? "Listening…" : model.heard)
                .font(.system(size: 12))
                .foregroundColor(model.heard.isEmpty ? .cbSecondary : .white)
                .truncationMode(.head)
                .frame(maxWidth: 260, alignment: .trailing)
        } else if model.request != nil {
            HStack(spacing: 6) {
                Text(model.statusTitle).font(.system(size: 12))
                PulseDot(size: 7, still: model.config.doNotDisturb)
            }
        } else if model.hasSession {
            HStack(spacing: 8) {
                Text(PillLayout.percent(model.contextPercent))
                MeterBar(percent: model.contextPercent, height: 3, track: .white.opacity(0.2), delay: 0.12)
                    .frame(width: 26)
            }
        } else {
            Text(PillLayout.percent(model.sessionPercent)).foregroundColor(.cbSecondary)
        }
    }
}

private struct NotchKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }

extension EnvironmentValues {
    /// The notch's height while the widget is docked there: the panel then
    /// grows out of it, black and flush with the top of the screen.
    var cbNotch: CGFloat? {
        get { self[NotchKey.self] }
        set { self[NotchKey.self] = newValue }
    }
}
