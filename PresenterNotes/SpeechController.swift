//
//  SpeechController.swift
//  PresenterNotes
//
//  Thin wrapper around SFSpeechRecognizer + AVAudioEngine that:
//    1. Streams microphone audio into an on-device speech recognizer.
//    2. Keeps a rolling window of the most recently spoken words.
//    3. Calls `onAdvanceDetected` when the presenter has spoken the
//       trailing-words signature of the current slide.
//
//  The matching strategy is deliberately forgiving: we only require
//  the trailing N words of the current slide to appear *in order*
//  somewhere near the end of the rolling window. This means the
//  presenter can paraphrase earlier in a slide and still advance when
//  they hit the closing words.
//

import Foundation
import AVFoundation
import Speech
import os

private let speechLog = Logger(subsystem: "com.example.PresenterNotes", category: "Speech")

final class SpeechController: NSObject, ObservableObject {

    // MARK: - Public state (read/written on main queue)

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var lastTranscript: String = ""
    @Published var statusMessage: String = "Idle"

    /// When `true`, `checkForAdvance()` uses a fuzzy subsequence match
    /// that tolerates a couple of filler words and one substitution. Useful
    /// for non-native speakers or noisy recogniser output. Persisted via
    /// UserDefaults under `looseMatchingDefaultsKey`.
    @Published var looseMatching: Bool = false

    /// Called when we decide the current slide is finished. Typed
    /// `@MainActor` so the compiler enforces the main-thread contract
    /// with `NotesViewModel` (which is itself `@MainActor`).
    var onAdvanceDetected: (@MainActor () -> Void)?

    /// Provider for the trailing words of the *current* slide. Reads
    /// from the view model, so typed `@MainActor`.
    var currentTrailingWordsProvider: (@MainActor () -> [String])?

    /// Called with every batch of *newly* recognised words (the delta
    /// since the previous callback). Used by the view model to advance
    /// its "how far through the slide has the presenter read" pointer
    /// so the current slide can highlight recognised words in real time.
    var onWordsRecognised: (@MainActor ([String]) -> Void)?

    // MARK: - Private state

    private let audioEngine = AVAudioEngine()
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Keep a rolling window of recognised words so we can do trailing-match
    /// even across recognition "sessions".
    private var rollingWords: [String] = []
    private let rollingWindow = 40

    /// Words preserved across a recogniser session restart. SFSpeechRecognizer
    /// ends sessions frequently (pauses, sentence boundaries, its ~1-minute
    /// cap); each new session's transcript starts empty. Without a carry-over
    /// buffer, a trailing-words match that straddles the boundary —
    /// e.g. the presenter said "where it's" in session 1 and "headed next"
    /// in session 2 — can never be reassembled.
    private var carryOverWords: [String] = []

    /// Word count of the last transcript we processed. Used to compute
    /// the delta of newly-recognised words for `onWordsRecognised`.
    private var lastTranscriptWordCount: Int = 0

    /// Guard against firing advance repeatedly for the same match.
    private var lastAdvanceFireTime: Date = .distantPast
    private let minAdvanceInterval: TimeInterval = 1.0

    override init() {
        super.init()
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        self.looseMatching = UserDefaults.standard.bool(forKey: looseMatchingDefaultsKey)
    }

    // MARK: - Authorization

    /// Trigger the system permission prompts at app launch if they haven't
    /// been granted yet. This way the user sees the dialogs once on first
    /// run — not mid-presentation when they click Listen.
    func requestAuthorizationIfNeeded() {
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard speechStatus == .notDetermined || micStatus == .notDetermined else { return }
        requestAuthorization { _ in }
    }

    /// Ask the user for speech + microphone permission. Calls completion
    /// on the main actor with `true` if everything is granted.
    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { speechStatus in
            let speechOK = (speechStatus == .authorized)
            AVCaptureDevice.requestAccess(for: .audio) { micOK in
                DispatchQueue.main.async {
                    completion(speechOK && micOK)
                }
            }
        }
    }

    // MARK: - Start / stop

    func start() {
        guard !isRunning else { return }
        guard let recognizer = recognizer, recognizer.isAvailable else {
            statusMessage = "Speech recognizer unavailable"
            return
        }

        requestAuthorization { [weak self] granted in
            guard let self = self else { return }
            guard granted else {
                self.statusMessage = "Microphone or speech permission denied"
                return
            }
            do {
                try self.startSession(recognizer: recognizer)
                self.isRunning = true
                self.statusMessage = "Listening…"
            } catch {
                self.statusMessage = "Couldn't start: \(error.localizedDescription)"
                self.stop()
            }
        }
    }

    func stop() {
        if audioPipelineInstalled {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
            audioPipelineInstalled = false
        }
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        isRunning = false
        statusMessage = "Stopped"
        lastTranscriptWordCount = 0
    }

    // MARK: - Session wiring

    /// True once we've installed a mic tap on the input node. We keep the
    /// tap and the audio engine running across recognizer session
    /// restarts — only the `SFSpeechAudioBufferRecognitionRequest` and
    /// its task get swapped — so we don't stop/start CoreAudio more than
    /// necessary.
    private var audioPipelineInstalled = false

    /// Call when the underlying `SFSpeechRecognizer` task ends and a new
    /// one is about to start. Snapshots the current `rollingWords` into
    /// `carryOverWords` so any trailing-words match spanning the session
    /// boundary can still be detected by `checkForAdvance()`. Internal
    /// (not `private`) so unit tests can simulate a session restart
    /// without touching the audio engine.
    func handleSessionRestart() {
        carryOverWords = rollingWords
        lastTranscriptWordCount = 0
    }

    private func startSession(recognizer: SFSpeechRecognizer) throws {
        // Tear down any previous recognition task, but leave the audio
        // engine + tap alone if they're already running.
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil

        // Each new recognition session resets the transcript the recognizer
        // reports, and we need to carry over the pre-restart rolling words
        // so trailing-words matches aren't lost at the boundary.
        handleSessionRestart()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Let the system pick on-device vs. server. Some installs report
        // `supportsOnDeviceRecognition == true` even when the locale's
        // model isn't actually downloaded, and forcing on-device in that
        // state fails immediately with kLSRErrorDomain 201. We keep
        // `network.client` in the entitlements so server fallback works.
        request.requiresOnDeviceRecognition = false
        self.request = request

        if !audioPipelineInstalled {
            let inputNode = audioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            // `removeTap` is safe even if no tap is installed.
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.request?.append(buffer)
            }
            audioEngine.prepare()
            try audioEngine.start()
            audioPipelineInstalled = true
        }

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let error = error {
                // Errors are terminal: stop and surface them instead of
                // restarting. The previous restart-on-error behaviour
                // turned a single setup failure (e.g. kLSRErrorDomain 201)
                // into an infinite loop burning CPU and log volume.
                DispatchQueue.main.async {
                    guard self.isRunning else { return }
                    self.statusMessage = "Recognition error: \(error.localizedDescription)"
                    self.stop()
                }
                return
            }
            guard let result = result else { return }
            let transcript = result.bestTranscription.formattedString
            DispatchQueue.main.async {
                self.lastTranscript = transcript
                // Inside DispatchQueue.main.async we're on main at
                // runtime; tell the compiler so it'll let us call the
                // `@MainActor`-isolated matcher without a Task hop.
                MainActor.assumeIsolated {
                    self.updateRolling(with: transcript)
                }
            }
            if result.isFinal {
                // Natural end of a recognition session (SFSpeechRecognizer
                // has a ~1-minute max). Restart so we keep listening for
                // the rest of the talk.
                DispatchQueue.main.async {
                    guard self.isRunning else { return }
                    do {
                        try self.startSession(recognizer: recognizer)
                    } catch {
                        self.statusMessage = "Restart failed: \(error.localizedDescription)"
                        self.stop()
                    }
                }
            }
        }
    }

    // MARK: - Matching

    /// Called for every updated transcript from the recognizer. Updates
    /// the rolling window *and* fires `onWordsRecognised` with the delta
    /// (new words since the previous callback). Exposed as `internal` so
    /// unit tests can drive it without the audio engine.
    ///
    /// Main-actor-isolated so the `@MainActor` callbacks can be invoked
    /// directly. Tests run in `@MainActor` classes so they call this
    /// without ceremony; the recognizer-queue caller hops to main via
    /// `DispatchQueue.main.async` + `MainActor.assumeIsolated`.
    @MainActor
    func updateRolling(with transcript: String) {
        // Single tokeniser shared with `NotesDocument.trailingWords` and
        // `NotesDocument.bodyMatchTokens` so the needle, the haystack, and
        // the body-side highlight tokens all agree on word boundaries.
        // "don't" → "dont" here; if we split on non-alphanumerics instead
        // the body's "dont" token would never match the "don"+"t" pair
        // emitted by the recogniser.
        let words = NotesDocument.bodyMatchTokens(in: transcript)
            .filter { !$0.isEmpty }

        // Compute the delta since the last callback. If the new count is
        // lower than the old one, we assume the recognition session
        // restarted and treat the whole thing as new.
        let newWords: [String]
        if words.count >= lastTranscriptWordCount {
            newWords = Array(words.suffix(words.count - lastTranscriptWordCount))
        } else {
            newWords = words
        }
        lastTranscriptWordCount = words.count

        // Rolling window = words the previous session left us (so we can
        // complete a trailing-words match that straddles the boundary) +
        // the current session's transcript, capped to the last N.
        rollingWords = Array((carryOverWords + words).suffix(rollingWindow))

        if !newWords.isEmpty {
            speechLog.notice("[Speech] heard: \(newWords.joined(separator: " "))")
            onWordsRecognised?(newWords)
        }

        checkForAdvance()
    }

    @MainActor
    private func checkForAdvance() {
        guard let needle = currentTrailingWordsProvider?(), !needle.isEmpty else { return }

        // When loose matching is on, widen the tail window slightly so
        // the fuzzy scan has room for inserted filler words.
        let tailSlack = looseMatching ? 5 : 3
        let tailCount = min(rollingWords.count, needle.count + tailSlack)
        guard tailCount > 0 else { return }
        let tail = Array(rollingWords.suffix(tailCount))

        // Loose matching allows up to 2 filler words between consecutive
        // needle words and 1 substituted needle word. With both budgets at
        // 0 this reduces to the old exact-contiguous behaviour.
        let maxSkip      = looseMatching ? 2 : 0
        let maxMismatch  = looseMatching ? 1 : 0

        if containsFuzzy(tail, needle, maxSkip: maxSkip, maxMismatch: maxMismatch) {
            let now = Date()
            guard now.timeIntervalSince(lastAdvanceFireTime) >= minAdvanceInterval else { return }
            lastAdvanceFireTime = now

            // Clear rolling + carry-over so we don't match the same phrase
            // twice and so the next slide starts from a clean slate.
            rollingWords.removeAll()
            carryOverWords.removeAll()
            onAdvanceDetected?()
        }
    }

    /// Return true if `needle` can be found in `haystack` as an (almost)
    /// contiguous subsequence with up to `maxSkip` haystack words skipped
    /// (to absorb filler words like "uh") and up to `maxMismatch` needle
    /// words substituted by any haystack word (to absorb recogniser
    /// misreads like "heading" instead of "headed"). With both budgets at
    /// 0 this is exact contiguous match.
    ///
    /// The search is a DFS over positions; depths are tiny (needle ~6,
    /// haystack ~10) so memoization isn't needed.
    private func containsFuzzy(
        _ haystack: [String],
        _ needle: [String],
        maxSkip: Int,
        maxMismatch: Int
    ) -> Bool {
        guard !needle.isEmpty else { return false }
        // Even a perfect run (allowing mismatches) must fit in the haystack.
        guard needle.count <= haystack.count + maxMismatch else { return false }

        func walk(_ i: Int, _ j: Int, _ skipsLeft: Int, _ mismatchesLeft: Int) -> Bool {
            if j == needle.count { return true }
            if i == haystack.count { return false }

            if haystack[i] == needle[j],
               walk(i + 1, j + 1, skipsLeft, mismatchesLeft) { return true }
            // Skip a haystack word (consumes skip budget).
            if skipsLeft > 0,
               walk(i + 1, j, skipsLeft - 1, mismatchesLeft) { return true }
            // Substitute current needle word (consumes mismatch budget).
            if mismatchesLeft > 0,
               walk(i + 1, j + 1, skipsLeft, mismatchesLeft - 1) { return true }

            return false
        }

        for start in 0..<haystack.count {
            if walk(start, 0, maxSkip, maxMismatch) { return true }
        }
        return false
    }
}

/// Shared UserDefaults key for the loose-matching setting. Referenced by
/// both `SpeechController.init` (to restore the value) and the ModeBar
/// toggle in `ContentView.swift`, so neither side drifts from the other.
let looseMatchingDefaultsKey = "PresenterNotes.looseMatching"
