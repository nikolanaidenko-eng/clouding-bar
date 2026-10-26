import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Puts a long question shorter for the Touch Bar with Apple's own model, on
/// this Mac (macOS 26 with Apple Intelligence; nothing leaves the Mac). Until
/// it answers — and anywhere it can't — the bar shows the question as it is.
/// Used on the main thread; the model is awaited off it, its answer comes back to it.
final class QuestionShortener {
    /// A question → its short form; "" when there's none to show.
    private var done: [String: String] = [:]
    private var asking: Set<String> = []
    /// Not ready (still downloading, say): asked again after this.
    private var retryAt = Date.distantPast
    /// A short form came: the bar is drawn again.
    var changed: () -> Void = {}

    /// The short form if there is one by now; else it's asked for, once.
    func short(for text: String) -> String? {
        guard ShortQuestion.worth(text) else { return nil }
        if let s = done[text] { return s.isEmpty ? nil : s }
        ask(text)
        return nil
    }

    private func ask(_ text: String) {
        guard !asking.contains(text), Date() >= retryAt else { return }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            // Not ready yet (still downloading, say): asked again in a while.
            guard case .available = SystemLanguageModel.default.availability else {
                retryAt = Date().addingTimeInterval(30)
                return
            }
            if done.count > 200 { done.removeAll() }
            asking.insert(text)
            let me = Weak(self)
            let instructions = Self.instructions
            Task {
                let answer = try? await LanguageModelSession(instructions: instructions).respond(to: text).content
                await MainActor.run { me.shortener?.finish(text, answer) }
            }
            return
        }
        #endif
        done[text] = ""
    }

    private func finish(_ text: String, _ answer: String?) {
        asking.remove(text)
        let short = answer.flatMap { ShortQuestion.accept($0, for: text) }
        done[text] = short ?? ""
        DebugLog.note(short == nil ? "question kept as it is (no short form that keeps it)" : "question put shorter for the bar")
        if short != nil { changed() }
    }

    /// Itself, held weakly, to hand to the model's task.
    private final class Weak: @unchecked Sendable {
        weak var shortener: QuestionShortener?
        init(_ shortener: QuestionShortener) { self.shortener = shortener }
    }

    static let instructions = """
        A coding agent asked its user a question. Rewrite it as one short question of at most 12 words, \
        in the same language as the question, asking exactly what it asks. Keep names, numbers, file names, \
        code and quoted words as they are. End with a question mark. Plain text only: no markdown, no preamble, no quotes.
        """
}
