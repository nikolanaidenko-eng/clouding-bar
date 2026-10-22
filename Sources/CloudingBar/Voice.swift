import AppKit
import AVFoundation
import Speech

/// Speech to text with Apple's recognizer. On this Mac's own model when the
/// language has one (no audio leaves the Mac); on Apple's servers only if
/// the settings allow it for a language without one.
final class VoiceInput {
    var onPartial: ((String) -> Void)?
    /// The final text, or nil if nothing was heard or it failed.
    var onFinal: ((String?) -> Void)?
    var onMessage: ((String) -> Void)?
    /// Diagnostics for debug.log.
    var onLog: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var best = ""
    /// What was heard before the recognizer started over (after a pause it
    /// may begin a new transcription, or finish one and need another).
    private var committed = ""
    private var recognizer: SFSpeechRecognizer?
    private var offline = false
    private var finishing = false

    /// Everything heard so far.
    private var heard: String { Self.join(committed, best) }

    private static func join(_ a: String, _ b: String) -> String {
        [a, b].map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The new transcription isn't a revision of the last one: it began again.
    /// Punctuation aside: a comma the recognizer adds on second thought
    /// ("Ну вот" → "Ну, вот") doesn't make it a new one.
    private static func startedOver(_ new: String, after old: String) -> Bool {
        let bare = { (s: String) in Array(s.lowercased().filter { !$0.isPunctuation }) }
        let a = bare(new), b = bare(old)
        guard !a.isEmpty, !b.isEmpty, a.count < b.count else { return false }
        var same = 0
        while same < min(a.count, b.count), a[same] == b[same] { same += 1 }
        return same < min(4, a.count)
    }
    private var silence: DispatchWorkItem?

    /// Stop by itself after a pause (tap-to-talk); nil: only stop() stops it.
    var stopAfterPause: TimeInterval?

    var isRunning: Bool { request != nil }

    /// Can this language be recognized offline on this Mac?
    static func worksOffline(_ language: String) -> Bool {
        SFSpeechRecognizer(locale: Locale(identifier: language))?.supportsOnDeviceRecognition ?? false
    }

    /// Languages offered in Settings: what the recognizer knows, sorted.
    static var languages: [String] {
        SFSpeechRecognizer.supportedLocales().map(\.identifier)
            .map { $0.replacingOccurrences(of: "_", with: "-") }
            .sorted()
    }

    func start(language: String, allowServer: Bool) {
        guard request == nil else { return }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language)) else {
            onMessage?("Voice: \(language) isn't supported")
            onFinal?(nil)
            return
        }
        let offline = recognizer.supportsOnDeviceRecognition
        guard offline || allowServer else {
            onMessage?("Voice: \(language) isn't available offline. Allow Apple servers in Settings to use it.")
            onFinal?(nil)
            return
        }
        authorize { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.onMessage?("Voice: allow Microphone and Speech Recognition for Clouding Bar in System Settings → Privacy")
                self.onFinal?(nil)
                return
            }
            self.begin(recognizer, offline: offline)
        }
    }

    private func authorize(_ done: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                DispatchQueue.main.async { done(false) }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { done(granted) }
            }
        }
    }

    private func begin(_ recognizer: SFSpeechRecognizer, offline: Bool) {
        self.recognizer = recognizer
        self.offline = offline
        let request = newRequest()
        self.request = request
        best = ""
        committed = ""
        finishing = false

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        // Into whichever request is current: a new one after the recognizer
        // finished one mid-speech.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            cleanUp()
            onMessage?("Voice: no microphone (\(error.localizedDescription))")
            onFinal?(nil)
            return
        }
        onLog?("listening, \(recognizer.locale.identifier), " + (offline ? "on this Mac" : "Apple servers"))
        armSilence(stopAfterPause.map { _ in 8 })
        recognize(request)
    }

    private func newRequest() -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = offline
        // Commas, full stops and question marks, as macOS's own dictation
        // puts them (macOS 13 and later; on 12 the words come bare).
        if #available(macOS 13, *) { request.addsPunctuation = true }
        return request
    }

    private func recognize(_ request: SFSpeechAudioBufferRecognitionRequest) {
        guard let recognizer else { return }
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            DispatchQueue.main.async {
                guard let self, self.request === request else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    if Self.startedOver(text, after: self.best) {
                        self.committed = Self.join(self.committed, self.best)
                    }
                    self.best = text
                    self.onPartial?(self.heard)
                    self.armSilence(self.stopAfterPause)
                    if result.isFinal {
                        if self.finishing {
                            self.deliver()
                        } else {
                            // Finished after a pause while you go on: keep it, listen on.
                            self.committed = Self.join(self.committed, self.best)
                            self.best = ""
                            let next = self.newRequest()
                            self.request = next
                            self.recognize(next)
                        }
                    }
                } else if let error {
                    self.onLog?("recognizer: \(error.localizedDescription)")
                    if self.finishing { self.deliver() }
                }
            }
        }
    }

    /// Tap-to-talk ends after a pause in speech; if nothing is said at all,
    /// after a longer one.
    private func armSilence(_ pause: TimeInterval?) {
        silence?.cancel()
        guard let pause, !finishing else { return }
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        silence = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pause, execute: work)
    }

    /// Stops listening; the final text arrives through onFinal. Keeps the
    /// mic open a moment longer: the key often comes up with the last word.
    func stop() {
        guard request != nil, !finishing else { return }
        finishing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, let request = self.request else { return }
            self.engine.stop()
            self.engine.inputNode.removeTap(onBus: 0)
            request.endAudio()
            // The last words can take a moment; don't wait forever.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.deliver() }
        }
    }

    private func deliver() {
        guard request != nil else { return }
        let text = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanUp()
        onFinal?(text.isEmpty ? nil : text)
    }

    private func cleanUp() {
        silence?.cancel()
        silence = nil
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request = nil
        recognizer = nil
        finishing = false
    }
}

/// Hold-to-talk on the right Option key: fires only when it's pressed on
/// its own and held at least 0.3 s, so ⌥-shortcuts and ⌥-letters still work.
final class RightOptionHold {
    var onStart: (() -> Void)?
    var onEnd: (() -> Void)?

    private static let rightOption: UInt16 = 61
    private var monitors: [Any] = []
    private var pending: DispatchWorkItem?
    private var holding = false

    func start() {
        let handler: (NSEvent) -> Void = { [weak self] in self?.handle($0) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: handler) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(m)
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .function, .numericPad])
        if event.type == .flagsChanged && event.keyCode == Self.rightOption {
            if flags == .option {
                // Pressed alone: wait 0.3 s before it counts.
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.pending = nil
                    self.holding = true
                    self.onStart?()
                }
                pending = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
            } else if !flags.contains(.option) {
                release()
            }
            return
        }
        // Anything else before the 0.3 s are up makes it a shortcut.
        if pending != nil {
            pending?.cancel()
            pending = nil
        }
    }

    private func release() {
        pending?.cancel()
        pending = nil
        if holding {
            holding = false
            onEnd?()
        }
    }
}
