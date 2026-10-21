import AppKit
import SwiftUI

/// Dictation in the widget (owner's request, 21.10): the words as they come,
/// the box growing with them (up to 8 lines, then the newest stay in view);
/// once you stop, the text to look over — edit it, send it to the chat, or
/// throw it away.
struct DictationCard: View {
    @ObservedObject var model: AppModel
    var width: CGFloat = 340
    /// Its own line saying what's going on (the notch has a title of its own).
    var header = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if header {
                HStack(spacing: 8) {
                    Icon(kind: .mic, size: 13, lineWidth: 1.8)
                        .foregroundColor(model.listening ? .cbAction : .cbSecondary)
                    Text(model.listening ? "Listening · pauses are fine · click to stop" : "Check it, then send")
                        .font(.system(size: 11)).foregroundColor(.cbSecondary)
                    Spacer(minLength: 0)
                    if !model.listening, let chat = model.chatName, model.sessions.count > 1 {
                        ChatTag(name: chat, color: model.chatColor, maxWidth: 130)
                    }
                }
            }
            if model.listening {
                Text(model.heard.isEmpty ? "Speak…" : model.heard)
                    .font(.system(size: 13))
                    .foregroundColor(model.heard.isEmpty ? .cbSecondary : .cbText)
                    .lineLimit(8)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: width, alignment: .leading)
            } else {
                let text = model.dictated ?? ""
                ReviewTextView(text: Binding(get: { model.dictated ?? "" }, set: { model.dictated = $0 }),
                               onSubmit: { model.sendDictated() })
                    .frame(width: width, height: Self.height(text, width: width))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.07)))
                HStack(spacing: 8) {
                    Button { model.discardDictated() } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("Throw it away")
                    Button { model.voiceToggle() } label: {
                        Icon(kind: .mic, size: 12, lineWidth: 1.6).frame(width: 26, height: 26)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("Say more")
                    Spacer(minLength: 0)
                    Text(model.config.taskQueue ? "Sent when Claude is free" : "Typed into the chat")
                        .font(.system(size: 10)).foregroundColor(.cbSecondary)
                    let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    Button { model.sendDictated() } label: {
                        Text("Send").font(.system(size: 12, weight: .semibold)).foregroundColor(.white)
                            .padding(.horizontal, 14).frame(height: 26)
                            .background(Capsule().fill(Color.cbAction))
                    }
                    .buttonStyle(.plain)
                    .disabled(empty)
                    .opacity(empty ? 0.4 : 1)
                }
            }
        }
        .foregroundColor(.cbText)
    }

    /// The editor grows with the text: two lines to eight.
    static func height(_ text: String, width: CGFloat) -> CGFloat {
        let bounds = (text as NSString).boundingRect(with: NSSize(width: width - 10, height: 10_000),
                                                     options: [.usesLineFragmentOrigin],
                                                     attributes: [.font: NSFont.systemFont(ofSize: 13)])
        return min(8 * 17, max(2 * 17, ceil(bounds.height) + 4))
    }
}

/// A plain, see-through text view: Enter sends, ⌥Enter starts a new line.
struct ReviewTextView: NSViewRepresentable {
    @Binding var text: String
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        let view = scroll.documentView as! NSTextView
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.font = .systemFont(ofSize: 13)
        view.textColor = .white
        view.insertionPointColor = .white
        view.textContainerInset = NSSize(width: 0, height: 1)
        view.textContainer?.lineFragmentPadding = 2
        view.string = text
        view.delegate = context.coordinator
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ReviewTextView
        init(_ parent: ReviewTextView) { self.parent = parent }

        func textDidChange(_ note: Notification) {
            guard let view = note.object as? NSTextView else { return }
            parent.text = view.string
        }

        func textView(_ view: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.option) {
                    view.insertNewlineIgnoringFieldEditor(nil)
                } else {
                    parent.onSubmit()
                }
                return true
            }
            return false
        }
    }
}
