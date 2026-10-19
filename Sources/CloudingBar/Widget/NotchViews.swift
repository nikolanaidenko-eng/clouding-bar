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
    /// Each side of the camera, at least (in a real notch).
    static let ear: CGFloat = 92

    /// The compact island's width: two ears around the camera, or, drawn,
    /// the two sides with a hairline between.
    static func compactWidth(camera: CGFloat) -> CGFloat {
        camera > 0 ? 2 * shoulder + 22 + 2 * ear + camera : 2 * shoulder + 22 + 210
    }

    /// Pulled wider than the compact island: the pill's items, around the camera.
    private var wideBudget: CGSize? {
        let size = state.pillEditSize
            ?? (model.config.notchWidth > 0 ? CGSize(width: model.config.notchWidth, height: model.config.notchHeight) : nil)
        guard let size, size.width > Self.compactWidth(camera: state.notchWidth) + 24 else { return nil }
        return size
    }

    /// What it's showing; a change springs it to its new size.
    private var phase: String {
        "\(model.request?.id.uuidString ?? "")|\(state.pillTyping)|\(model.listening)"
    }

    var body: some View {
        Group {
            if let r = model.request {
                request(r)
            } else if state.pillTyping {
                typing
            } else if model.listening {
                listening
            } else if let b = wideBudget, model.hasSession {
                wide(b)
            } else {
                compact
            }
        }
        .lineLimit(1)
        .overlay(state.dropHover ? NotchShape(radius: 16).stroke(Color.cbAction, lineWidth: 2) : nil)
        // Growing for a question or for writing: a springy Dynamic Island.
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: phase)
        .transition(.opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Clouding Bar: \(model.statusTitle)")
    }

    // MARK: Compact

    /// Cloud and the 5-hour limit, then the context: either side of the
    /// camera, or, with no camera, side by side.
    private var compact: some View {
        let camera = state.notchWidth
        return HStack(spacing: 0) {
            left.frame(minWidth: camera > 0 ? Self.ear : 0, alignment: .leading)
            if camera > 0 {
                Color.clear.frame(width: camera) // the camera
            } else {
                Rectangle().fill(Color.white.opacity(0.16)).frame(width: 1, height: 14).padding(.horizontal, 12)
            }
            right.frame(minWidth: camera > 0 ? Self.ear : 0, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .semibold).monospacedDigit())
        .foregroundColor(.white)
        .padding(.leading, Self.shoulder + 10)
        .padding(.trailing, Self.shoulder + 12)
        .padding(.horizontal, state.pillHover && state.pillEditSize == nil ? 3 : 0) // a little give under the pointer
        .frame(minWidth: state.pillEditSize?.width)
        .frame(height: state.pillEditSize.map { max(state.notchHeight, $0.height) } ?? state.notchHeight)
        .background(PillDragHandle(state: state, fromTop: false))
        .background(NotchShape().fill(Color.black))
        .animation(.cb(0.22), value: state.pillHover)
    }

    private var left: some View {
        HStack(spacing: 8) {
            MascotIcon(activity: model.request != nil ? .wait : model.activity, size: 20)
                .frame(width: 20, height: 20)
                .overlay(FileBadge(text: state.dropHover ? "+" : model.attachments.isEmpty ? nil : "\(model.attachments.count)")
                    .offset(x: 5, y: -3), alignment: .topTrailing)
            if model.listening {
                Icon(kind: .mic, size: 13, lineWidth: 1.8).foregroundColor(.cbAction)
            } else if model.hasSession && !model.config.widgetHides.contains("session") {
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
        } else if model.hasSession && model.config.pillShows.contains("context") {
            HStack(spacing: 8) {
                Text(PillLayout.percent(model.contextPercent))
                MeterBar(percent: model.contextPercent, height: 3, track: .white.opacity(0.2), delay: 0.12)
                    .frame(width: 26)
            }
        } else if !model.hasSession {
            Text(PillLayout.percent(model.sessionPercent)).foregroundColor(.cbSecondary)
        }
    }

    // MARK: Wide

    /// Pulled wider (or lower): the pill's own items, in its order, the
    /// camera kept clear in the middle; they can be swapped as on the pill.
    private func wide(_ b: CGSize) -> some View {
        let camera = state.notchWidth
        let width = max(PillLayout.minWidth, b.width - camera - 2 * Self.shoulder)
        // Rows only: never stood up as a column under the notch.
        let height = min(max(PillLayout.height(rows: 1), b.height), width)
        return PillBoard(model: model, state: state, rearrange: state.pillRearrange,
                         budget: CGSize(width: width, height: height), camera: camera, notched: true)
            .font(.system(size: 13).monospacedDigit())
            .foregroundColor(.cbText)
            .padding(.horizontal, Self.shoulder)
            .background(PillDragHandle(state: state, fromTop: false))
            .background(NotchShape(radius: 16).fill(Color.black))
    }

    // MARK: Grown

    /// Grown wider and taller for what needs you or what you're writing.
    static func grownWidth(camera: CGFloat) -> CGFloat { max(460, camera + 2 * ear + 80) }
    private var inner: CGFloat { Self.grownWidth(camera: state.notchWidth) - 2 * (Self.shoulder + 16) }

    /// The grown island: a header line (under the camera, in a real notch),
    /// then what it's about. A click on it opens the panel.
    private func grown<Content: View>(_ title: String, _ subtitle: String?, waiting: Bool,
                                      @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                MascotIcon(activity: waiting ? .wait : model.activity, size: 22).frame(width: 22, height: 22)
                Text(title).font(.system(size: 13, weight: .semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12)).foregroundColor(.cbSecondary)
                }
                Spacer(minLength: 10)
                if waiting { PulseDot(size: 7, still: model.config.doNotDisturb) }
            }
            content()
        }
        .lineLimit(1)
        .foregroundColor(.white)
        .padding(.top, state.notchWidth > 0 ? state.notchHeight + 4 : 10)
        .padding(.bottom, 12)
        .padding(.horizontal, Self.shoulder + 16)
        .frame(width: Self.grownWidth(camera: state.notchWidth), alignment: .leading)
        .background(PillDragHandle(state: state, fromTop: false))
        .background(NotchShape(radius: 22).fill(Color.black))
        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .top)))
    }

    /// Claude asks or needs an OK: the question (or the command) and the
    /// answers, right in the notch.
    @ViewBuilder private func request(_ r: AppModel.RequestCard) -> some View {
        if r.kind == .permission {
            grown("Needs your OK", [r.project, r.verb == "Run" ? "run in terminal" : r.verb.lowercased()]
                    .compactMap { $0 }.joined(separator: " · "), waiting: true) {
                Text(r.detail)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    answer("Allow", style: .primary) { model.perform(.allow) }
                    answer("Always allow") { model.perform(.always) }
                    answer("Deny", style: .deny) { model.perform(.deny) }
                }
            }
        } else {
            grown("Claude asks", [r.project, r.count > 1 ? "\(r.index + 1) of \(r.count)" : nil]
                    .compactMap { $0 }.joined(separator: " · "), waiting: true) {
                Text(r.question)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                options(r)
            }
        }
    }

    /// The options as chips that wrap; "Other…" opens the panel to type.
    private func options(_ r: AppModel.RequestCard) -> some View {
        let send = r.multiSelect && !r.picked.isEmpty ? "Send \(r.picked.count)" : nil
        var items = r.options.enumerated().map { (id: "o\($0.offset)", width: Self.chip($0.element)) }
        if let send { items.append((id: "send", width: Self.chip(send))) }
        items.append((id: "other", width: Self.chip("Other…")))
        let board = flowSlots(items, width: inner, rowHeight: 26, gap: 6, rowGap: 6)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(r.options.enumerated()), id: \.offset) { i, label in
                let slot = board.slots["o\(i)"] ?? .zero
                answer(label, style: r.picked.contains(i) ? .picked : .normal, fill: true) { model.perform(.option(i)) }
                    .frame(width: slot.width)
                    .offset(x: slot.minX, y: slot.minY)
            }
            if let send, let slot = board.slots["send"] {
                answer(send, style: .primary, fill: true) { model.perform(.sendPicked) }
                    .frame(width: slot.width).offset(x: slot.minX, y: slot.minY)
            }
            if let slot = board.slots["other"] {
                answer("Other…", style: .outline, fill: true) { state.openPanel?() }
                    .frame(width: slot.width).offset(x: slot.minX, y: slot.minY)
            }
        }
        .frame(width: inner, height: board.size.height, alignment: .topLeading)
    }

    private enum AnswerStyle { case normal, primary, deny, picked, outline }

    /// `fill`: as wide as the slot it's given (the options); else as its words.
    private func answer(_ label: String, style: AnswerStyle = .normal, fill: Bool = false,
                        _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 12, weight: style == .primary ? .semibold : .regular)).lineLimit(1)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 26)
                .background(Capsule().fill(style == .primary ? Color.cbAction
                                           : style == .picked ? Color.cbAction.opacity(0.45)
                                           : style == .outline ? Color.clear : Color.white.opacity(0.12)))
                .overlay(style == .outline ? Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 1) : nil)
                .foregroundColor(style == .deny ? .cbDeny : .white)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: !fill, vertical: false)
    }

    private static func chip(_ label: String) -> CGFloat {
        min(400, MainPanel.textWidth(label, 12) + 22)
    }

    /// Writing in the notch: it grows into a text line.
    private var typing: some View {
        grown("Write to Claude", model.project, waiting: false) {
            PillTyping(model: model, state: state, width: inner, inline: true)
        }
    }

    /// Dictating: the words as they come.
    private var listening: some View {
        grown("Listening…", nil, waiting: false) {
            HStack(alignment: .top, spacing: 8) {
                Icon(kind: .mic, size: 13, lineWidth: 1.8).foregroundColor(.cbAction)
                Text(model.heard.isEmpty ? "Speak — it stops by itself after a pause" : model.heard)
                    .font(.system(size: 13))
                    .foregroundColor(model.heard.isEmpty ? .cbSecondary : .white)
                    .lineLimit(3)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
