import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Puts long words shorter with Apple's own model, on this Mac (macOS 26
/// with Apple Intelligence; nothing leaves the Mac): a question for the Touch
/// Bar, a finished chat's answer for Cloud's bubble and the bar. Until it
/// answers — and anywhere it can't — the words show as they are. Used on
/// the main thread; the model is awaited off it, its answer comes back to it.
final class ModelShortener {
    /// What is put shorter, and how the model's answer is judged.
    struct Rules {
        let instructions: String
        /// Long enough to be worth putting shorter.
        let worth: (String) -> Bool
        /// What the model is given for the words.
        let input: (String) -> String
        /// The model's answer, tidied, if it may stand in for the words.
        let accept: (_ answer: String, _ words: String) -> String?
        /// What debug.log says, never the words: put shorter, kept as they are.
        let shortened: String
        let kept: String
    }

    private let rules: Rules
    init(_ rules: Rules) { self.rules = rules }

    /// The words → their short form; "" when there's none to show.
    private var done: [String: String] = [:]
    private var asking: Set<String> = []
    /// Not ready (still downloading, say): asked again after this.
    private var retryAt = Date.distantPast
    /// A short form came: the bar is drawn again.
    var changed: () -> Void = {}

    /// The short form if there is one by now; else it's asked for, once.
    func short(for text: String) -> String? {
        guard rules.worth(text) else { return nil }
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
            let instructions = rules.instructions
            let input = rules.input(text)
            Task {
                // Steady, and no longer than a short form needs.
                let options = GenerationOptions(temperature: 0, maximumResponseTokens: 120)
                let answer = try? await LanguageModelSession(instructions: instructions).respond(to: input, options: options).content
                await MainActor.run { me.shortener?.finish(text, answer) }
            }
            return
        }
        #endif
        done[text] = ""
    }

    private func finish(_ text: String, _ answer: String?) {
        asking.remove(text)
        let short = answer.flatMap { rules.accept($0, text) }
        done[text] = short ?? ""
        DebugLog.note(short == nil ? rules.kept : rules.shortened)
        if short != nil { changed() }
    }

    /// Itself, held weakly, to hand to the model's task.
    private final class Weak: @unchecked Sendable {
        weak var shortener: ModelShortener?
        init(_ shortener: ModelShortener) { self.shortener = shortener }
    }
}

extension ModelShortener.Rules {
    /// A question for the Touch Bar: only one in words, never a permission's
    /// command or an answer's label (ShortQuestion).
    static let question = Self(
        instructions: """
            A coding agent asked its user a question. Rewrite it as one short question of at most 12 words, \
            in the same language as the question, asking exactly what it asks. Keep names, numbers, file names, \
            code and quoted words as they are. End with a question mark. Plain text only: no markdown, no preamble, no quotes.
            """,
        worth: ShortQuestion.worth, input: { $0 }, accept: ShortQuestion.accept,
        shortened: "question put shorter for the bar", kept: "question kept as it is (no short form that keeps it)")

    /// A finished chat's answer, retold in a sentence (AnswerPreview).
    static let answer = Self(
        instructions: """
            A coding agent finished its turn with the reply below. Retell what it tells its user in one short sentence \
            of at most 20 words, in the same language as the reply: what was done or found, or what it asks of the user. \
            Keep names, numbers and file names exactly as written, and add nothing that isn't in the reply. \
            Plain text only: no markdown, no preamble, no quotes.
            """,
        worth: AnswerPreview.worth, input: AnswerPreview.input, accept: AnswerPreview.accept,
        shortened: "answer put shorter", kept: "answer shown by its first lines (no short form that holds to it)")
}
