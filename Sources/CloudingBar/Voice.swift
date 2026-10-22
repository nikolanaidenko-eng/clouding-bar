import AppKit
import AVFoundation
import Speech

/// Speech to text with Apple's recognizer. On macOS 26 and later, the
/// system's own dictation model (DictationTranscriber): on this Mac, with
/// commas and full stops, through pauses. Before that, or for a language it
/// lacks, SFSpeechRecognizer: on this Mac's own model when the language has
/// one (no audio leaves the Mac); on Apple's servers only if the settings
/// allow it for a language without one.
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

    var isRunning: Bool { request != nil || dictation != nil || starting }
    /// The macOS 26 dictation (a DictationSession), while it listens.
    private var dictation: AnyObject?
    /// Between start() and the first word: permissions, the model.
    private var starting = false

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
        guard !isRunning else { return }
        starting = true
        authorize { [weak self] ok in
            guard let self else { return }
            guard ok else {
                self.starting = false
                self.onMessage?("Voice: allow Microphone and Speech Recognition for Clouding Bar in System Settings → Privacy")
                self.onFinal?(nil)
                return
            }
            if #available(macOS 26, *) {
                Task { @MainActor in
                    if let locale = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) {
                        self.beginDictation(locale)
                    } else {
                        self.startRecognizer(language: language, allowServer: allowServer)
                    }
                }
            } else {
                self.startRecognizer(language: language, allowServer: allowServer)
            }
        }
    }

    // MARK: macOS 26: the system's dictation

    @available(macOS 26, *)
    private func beginDictation(_ locale: Locale) {
        let session = DictationSession(engine: engine)
        dictation = session
        finishing = false
        session.onText = { [weak self] text in
            guard let self, self.dictation === session else { return }
            self.best = text
            self.onPartial?(text)
            self.armSilence(self.stopAfterPause)
        }
        session.onModel = { [weak self] in self?.onMessage?("Voice: getting the dictation model for \(locale.identifier)…") }
        Task { @MainActor in
            do {
                try await session.start(locale: locale)
                self.starting = false
                self.onLog?("listening, \(locale.identifier), system dictation (punctuation)")
                self.armSilence(self.stopAfterPause.map { _ in 8 })
            } catch {
                self.onLog?("dictation: \(error.localizedDescription)")
                self.starting = false
                self.dictation = nil
                self.onMessage?("Voice: \(error.localizedDescription)")
                self.onFinal?(nil)
            }
        }
    }

    // MARK: Before macOS 26: SFSpeechRecognizer

    private func startRecognizer(language: String, allowServer: Bool) {
        starting = false
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
        begin(recognizer, offline: offline)
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
        if #available(macOS 26, *), let session = dictation as? DictationSession {
            guard !finishing else { return }
            finishing = true
            silence?.cancel()
            // The key often comes up with the last word: a moment more.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                Task { @MainActor in
                    let text = await session.finish()
                    guard self.dictation === session else { return }
                    self.dictation = nil
                    self.finishing = false
                    self.best = ""
                    let heard = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.onFinal?(heard.isEmpty ? nil : heard)
                }
            }
            return
        }
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

/// One dictation with the system's model (macOS 26): the microphone's
/// audio, converted to what the model takes, fed to a SpeechAnalyzer; its
/// results — settled ones and the words still in flux — make the text.
@available(macOS 26, *)
private final class DictationSession {
    var onText: ((String) -> Void)?
    /// The model for the language has to be fetched first (once).
    var onModel: (() -> Void)?

    private let engine: AVAudioEngine
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var results: Task<Void, Never>?
    private var settled = ""
    private var inFlux = ""

    init(engine: AVAudioEngine) { self.engine = engine }

    private var text: String {
        guard !settled.isEmpty, !inFlux.isEmpty else { return settled + inFlux }
        let gap = settled.last!.isWhitespace || inFlux.first!.isWhitespace ? "" : " "
        return settled + gap + inFlux
    }

    @MainActor
    func start(locale: Locale) async throws {
        let transcriber = DictationTranscriber(locale: locale, contentHints: [], transcriptionOptions: [.punctuation],
                                               reportingOptions: [.volatileResults], attributeOptions: [])
        if let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            onModel?()
            try await install.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw NSError(domain: "Voice", code: 1, userInfo: [NSLocalizedDescriptionKey: "no audio format for dictation"])
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.input = input
        results = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let words = String(result.text.characters)
                    if result.isFinal {
                        self.settled = self.join(self.settled, words)
                        self.inFlux = ""
                    } else {
                        self.inFlux = words
                    }
                    self.onText?(self.text)
                }
            } catch {}
        }
        try await analyzer.start(inputSequence: stream)

        let mic = engine.inputNode
        let micFormat = mic.outputFormat(forBus: 0)
        let converter = micFormat == format ? nil : AVAudioConverter(from: micFormat, to: format)
        mic.removeTap(onBus: 0)
        mic.installTap(onBus: 0, bufferSize: 2048, format: micFormat) { buffer, _ in
            guard let converter else {
                input.yield(AnalyzerInput(buffer: buffer))
                return
            }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * format.sampleRate / micFormat.sampleRate) + 512
            guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
            var given = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if given {
                    status.pointee = .noDataNow
                    return nil
                }
                given = true
                status.pointee = .haveData
                return buffer
            }
            if error == nil, out.frameLength > 0 { input.yield(AnalyzerInput(buffer: out)) }
        }
        engine.prepare()
        try engine.start()
    }

    private func join(_ a: String, _ b: String) -> String {
        guard !a.isEmpty, !b.isEmpty else { return a + b }
        return a.last!.isWhitespace || b.first!.isWhitespace ? a + b : a + " " + b
    }

    /// Stops the microphone and waits for the last words. All of it, then.
    @MainActor
    func finish() async -> String {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        _ = await results?.value
        return text
    }
}
