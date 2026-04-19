//
//  NotesViewModel.swift
//  PresenterNotes
//
//  Owns the loaded document, current slide index, editable source text,
//  validation issues, and dirty/save state. All UI reads from this
//  object; all actions go through it.
//

import Foundation
import SwiftUI
import Combine

/// Top-level mode for the window.
enum AppMode: String, CaseIterable, Identifiable {
    case present
    case edit
    var id: String { rawValue }
    var label: String {
        switch self {
        case .present: return "Present"
        case .edit:    return "Edit"
        }
    }
    var symbol: String {
        switch self {
        case .present: return "play.rectangle"
        case .edit:    return "square.and.pencil"
        }
    }
}

/// Sub-mode within Present: one-slide-at-a-time, focused-paragraph within
/// a pinned slide, or scrolling teleprompter.
enum PresentStyle: String, CaseIterable, Identifiable {
    case slide
    case focusedSlide
    case teleprompter
    var id: String { rawValue }

    /// True for styles whose navigation unit is a paragraph rather than
    /// a whole slide. Drives keyboard nav, speech matching, progress
    /// counter, and auto-scroll enablement.
    var usesParagraphs: Bool {
        self != .slide
    }
}

/// Owns the loaded document, current slide index, and speech state.
/// `@MainActor`-isolated so the compiler enforces the main-thread
/// invariant that used to be a comment. SwiftUI views already run on
/// the main actor; `SpeechController` callbacks that reach in here are
/// typed as `@MainActor` closures so the recogniser-queue hops happen
/// on the speech side, not here.
@MainActor
final class NotesViewModel: ObservableObject {

    // MARK: - Published state

    @Published var mode: AppMode = .present {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeDefaultsKey)
            if mode == .present, isDirty, sourceURL != nil {
                try? save()
            }
            if mode != .present { autoScroll = false }
        }
    }

    @Published var presentStyle: PresentStyle = .slide {
        didSet {
            UserDefaults.standard.set(presentStyle.rawValue, forKey: Self.presentStyleDefaultsKey)
            if !presentStyle.usesParagraphs { autoScroll = false }
        }
    }

    @Published var autoScroll: Bool = false {
        didSet {
            if autoScroll { startAutoScrollTimer() } else { stopAutoScrollTimer() }
        }
    }
    @Published private(set) var autoScrollProgress: CGFloat = 0

    /// Editable markdown source. Setting this re-parses and re-validates.
    @Published var sourceText: String = "" {
        didSet {
            guard sourceText != oldValue else { return }
            if !isApplyingUndoRedo {
                recordEditForUndo(previous: oldValue)
            }
            reparse()
        }
    }

    // MARK: - Undo / redo state

    @Published private var undoStack: [String] = []
    @Published private var redoStack: [String] = []
    private var isApplyingUndoRedo = false
    private var lastUndoPushTime: Date = .distantPast
    private let undoCoalesceInterval: TimeInterval = 0.6
    private let maxUndoDepth = 200

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    @Published private(set) var slides: [NoteSlide] = []
    @Published private(set) var paragraphs: [TeleprompterParagraph] = []
    @Published private(set) var issues: [ValidationIssue] = []
    @Published private(set) var currentIndex: Int = 0 {
        didSet { UserDefaults.standard.set(currentIndex, forKey: Self.slideIndexDefaultsKey) }
    }
    @Published private(set) var currentParagraphIndex: Int = 0
    @Published private(set) var sourceURL: URL? = nil
    @Published private(set) var isDirty: Bool = false
    @Published var errorMessage: String? = nil

    /// How many whitespace-separated words of the current slide's body
    /// the speech recognizer has already matched, in order. Drives the
    /// live highlight of recognised words in Present mode.
    @Published private(set) var spokenWordCount: Int = 0

    /// Whether the speech-driven auto-advance is active.
    @Published var isListening: Bool = false

    /// Most recent recognised trailing phrase (for the debug HUD).
    @Published var lastHeardPhrase: String = ""

    // MARK: - Init

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.modeDefaultsKey),
           let m = AppMode(rawValue: raw) {
            self.mode = m
        }
        if let raw = UserDefaults.standard.string(forKey: Self.presentStyleDefaultsKey),
           let style = PresentStyle(rawValue: raw) {
            self.presentStyle = style
        }
    }

    // MARK: - Private state

    private var lastSavedText: String = ""

    /// Cached match-token list for the current slide's body so we don't
    /// re-tokenise on every recognised word. Invalidated whenever the
    /// current slide changes (navigation or edit).
    private var currentMatchTokensCache: [String] = []

    // MARK: - Derived

    var currentSlide: NoteSlide? {
        guard slides.indices.contains(currentIndex) else { return nil }
        return slides[currentIndex]
    }

    var hasDocument: Bool { !slides.isEmpty }

    var errorCount: Int { issues.filter { $0.severity == .error }.count }
    var warningCount: Int { issues.filter { $0.severity == .warning }.count }

    // MARK: - Loading

    func loadMarkdown(_ text: String, from url: URL? = nil) {
        // Set sidecar state before sourceText so didSet sees consistent flags.
        lastSavedText = text
        sourceURL = url
        errorMessage = nil
        currentIndex = 0
        // Reset paragraph index too: reparse()'s clamp only fires if the
        // old index is past the new doc's paragraph count, so if the new
        // doc is long enough the stale index would silently point at an
        // unrelated paragraph of the new content (and resetSpokenProgress
        // would build the match cache from it).
        currentParagraphIndex = 0
        // Suppress the undo push that `sourceText.didSet` would otherwise
        // record: loading a document is a fresh start, not an edit, and
        // any history from the previous document will be cleared below.
        isApplyingUndoRedo = true
        sourceText = text  // triggers reparse()
        isApplyingUndoRedo = false
        // reparse() recomputes isDirty, but after we just set lastSavedText
        // the values are equal, so isDirty should already be false.
        isDirty = false
        undoStack.removeAll()
        redoStack.removeAll()
        lastUndoPushTime = .distantPast
    }

    // MARK: - Undo / redo

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(sourceText)
        isApplyingUndoRedo = true
        sourceText = previous
        isApplyingUndoRedo = false
        // Force the next edit to start a fresh coalescing window.
        lastUndoPushTime = .distantPast
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(sourceText)
        isApplyingUndoRedo = true
        sourceText = next
        isApplyingUndoRedo = false
        lastUndoPushTime = .distantPast
    }

    /// Called from `sourceText.didSet` for every non-undo edit. Coalesces
    /// rapid typing into a single undo step so users don't have to tap
    /// Cmd+Z once per keystroke.
    private func recordEditForUndo(previous: String) {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastUndoPushTime)

        if elapsed > undoCoalesceInterval || undoStack.isEmpty {
            undoStack.append(previous)
            if undoStack.count > maxUndoDepth {
                undoStack.removeFirst()
            }
            lastUndoPushTime = now
        }
        // Any fresh edit invalidates the redo path.
        redoStack.removeAll()
    }

    func loadFromDisk(_ url: URL) {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            loadMarkdown(text, from: url)
            Self.storeBookmark(for: url)
        } catch {
            errorMessage = "Couldn't read file: \(error.localizedDescription)"
        }
    }

    /// Built-in sample so the app is useful on first launch.
    func loadSample() {
        Self.clearBookmark()
        loadMarkdown(Self.sampleMarkdown, from: nil)
    }

    /// Reset to an empty document (with a helpful skeleton).
    func newDocument() {
        Self.clearBookmark()
        loadMarkdown("## Untitled\n\nYour first slide.\n", from: nil)
    }

    // MARK: - Last-opened file restoration

    static let modeDefaultsKey         = "PresenterNotes.mode"
    static let presentStyleDefaultsKey = "PresenterNotes.presentStyle"
    static let bookmarkDefaultsKey     = "PresenterNotes.lastOpenedBookmark"
    static let slideIndexDefaultsKey   = "PresenterNotes.lastSlideIndex"

    /// Try to reload the file the user was on last time the app was open.
    /// Returns `true` if a document was restored, `false` if there was no
    /// bookmark or it couldn't be resolved (in which case callers should
    /// fall back to the sample).
    @discardableResult
    func restoreLastOpenedDocument() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkDefaultsKey) else {
            return false
        }
        let savedSlideIndex = UserDefaults.standard.integer(forKey: Self.slideIndexDefaultsKey)
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }

            let text = try String(contentsOf: url, encoding: .utf8)
            loadMarkdown(text, from: url)

            if slides.indices.contains(savedSlideIndex) {
                currentIndex = savedSlideIndex
                syncParagraphIndexFromSlide()
            }

            if isStale {
                // The file moved/renamed but we were able to follow it —
                // refresh the stored bookmark so the next restore is cheap.
                Self.storeBookmark(for: url)
            }
            return true
        } catch {
            // Bookmark unresolvable (file deleted, permission revoked, …).
            // Drop it so we don't keep retrying on every launch.
            Self.clearBookmark()
            return false
        }
    }

    private static func storeBookmark(for url: URL) {
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkDefaultsKey)
        } catch {
            // Best-effort. If we can't make a bookmark, the next launch
            // will fall back to the sample.
        }
    }

    private static func clearBookmark() {
        UserDefaults.standard.removeObject(forKey: bookmarkDefaultsKey)
    }

    // MARK: - Parsing / validation

    private func reparse() {
        let parsed = NotesDocument.parse(sourceText)
        slides = parsed
        paragraphs = NotesDocument.paragraphs(from: parsed)
        issues = NotesValidator.validate(sourceText)

        // Clamp indices so we don't point past the end after an edit.
        if slides.isEmpty {
            currentIndex = 0
        } else if currentIndex >= slides.count {
            currentIndex = slides.count - 1
        }
        if paragraphs.isEmpty {
            currentParagraphIndex = 0
        } else if currentParagraphIndex >= paragraphs.count {
            currentParagraphIndex = paragraphs.count - 1
        }

        isDirty = (sourceText != lastSavedText)

        if parsed.isEmpty && !sourceText.isEmpty {
            errorMessage = "No slides found — add at least one `## Heading`."
        } else {
            errorMessage = nil
        }

        // Edits rebuild the slides, so any existing progress pointer
        // would be meaningless against the new text.
        resetSpokenProgress()
    }

    // MARK: - Navigation

    func next() {
        guard currentIndex + 1 < slides.count else { return }
        currentIndex += 1
        syncParagraphIndexFromSlide()
        resetSpokenProgress()
    }

    func previous() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        syncParagraphIndexFromSlide()
        resetSpokenProgress()
    }

    func jump(to index: Int) {
        guard slides.indices.contains(index) else { return }
        currentIndex = index
        syncParagraphIndexFromSlide()
        resetSpokenProgress()
    }

    // MARK: - Paragraph navigation (teleprompter)

    func jumpToParagraph(_ index: Int) {
        guard paragraphs.indices.contains(index) else { return }
        currentParagraphIndex = index
        syncSlideIndexFromParagraph()
        resetSpokenProgress()
        if autoScroll { startAutoScrollTimer() }
    }

    func nextParagraph() {
        guard currentParagraphIndex + 1 < paragraphs.count else {
            autoScroll = false
            return
        }
        currentParagraphIndex += 1
        syncSlideIndexFromParagraph()
        resetSpokenProgress()
        if autoScroll { startAutoScrollTimer() }
    }

    func previousParagraph() {
        guard currentParagraphIndex > 0 else { return }
        currentParagraphIndex -= 1
        syncSlideIndexFromParagraph()
        resetSpokenProgress()
        if autoScroll { startAutoScrollTimer() }
    }

    private func syncSlideIndexFromParagraph() {
        guard paragraphs.indices.contains(currentParagraphIndex) else { return }
        let slideIdx = paragraphs[currentParagraphIndex].slideIndex
        if slideIdx != currentIndex { currentIndex = slideIdx }
    }

    private func syncParagraphIndexFromSlide() {
        if let first = paragraphs.firstIndex(where: { $0.slideIndex == currentIndex }) {
            currentParagraphIndex = first
        }
    }

    // MARK: - Auto-scroll timer (teleprompter)

    private var autoScrollTimer: Timer?
    private var autoScrollStartTime: Date?
    private var autoScrollDuration: TimeInterval = 0
    private let charsPerSecond: Double = 15

    func startAutoScrollTimer() {
        autoScrollTimer?.invalidate()
        guard paragraphs.indices.contains(currentParagraphIndex) else { return }

        let chars = max(Double(paragraphs[currentParagraphIndex].text.count), 1)
        autoScrollDuration = max(chars / charsPerSecond, 2.0)
        autoScrollStartTime = Date()
        autoScrollProgress = 0

        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            // The timer fires on the main RunLoop today, but hopping
            // via `Task { @MainActor in … }` makes that a compile-time
            // guarantee rather than a precondition that would crash on
            // a future refactor that changed scheduling. 20 Hz Task
            // allocations are cheap.
            Task { @MainActor in
                guard let self = self else { return }
                let elapsed = Date().timeIntervalSince(self.autoScrollStartTime ?? Date())
                let fraction = min(elapsed / self.autoScrollDuration, 1.0)
                self.autoScrollProgress = CGFloat(fraction)
                if fraction >= 1.0 {
                    self.nextParagraph()
                }
            }
        }
    }

    private func stopAutoScrollTimer() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollProgress = 0
    }

    // MARK: - Speech progress

    /// Reset the "how far through the slide has the presenter spoken"
    /// pointer. Called on any navigation or source edit so highlighting
    /// restarts for the new current slide/paragraph.
    func resetSpokenProgress() {
        spokenWordCount = 0
        if presentStyle.usesParagraphs {
            if paragraphs.indices.contains(currentParagraphIndex) {
                currentMatchTokensCache = NotesDocument.bodyMatchTokens(in: paragraphs[currentParagraphIndex].text)
            } else {
                currentMatchTokensCache = []
            }
        } else if let slide = currentSlide {
            currentMatchTokensCache = NotesDocument.bodyMatchTokens(in: slide.body)
        } else {
            currentMatchTokensCache = []
        }
    }

    /// Observe a batch of freshly recognised words and advance the
    /// progress pointer through the current slide's body.
    ///
    /// The match is forgiving: each recognised word can skip up to
    /// `maxSkip` still-unspoken words in the slide, which lets the
    /// presenter paraphrase a couple of words and still stay on track.
    /// Empty normalised forms (punctuation-only recogniser output) are
    /// ignored.
    func observeRecognisedWords(_ words: [String], maxSkip: Int = 3) {
        guard !currentMatchTokensCache.isEmpty else { return }
        for word in words {
            if spokenWordCount >= currentMatchTokensCache.count { return }
            let needle = NotesDocument.normaliseMatchWord(word)
            if needle.isEmpty { continue }
            let upper = min(spokenWordCount + maxSkip + 1, currentMatchTokensCache.count)
            for i in spokenWordCount..<upper where currentMatchTokensCache[i] == needle {
                spokenWordCount = i + 1
                break
            }
        }
    }

    // MARK: - Fixes

    func apply(_ issue: ValidationIssue) {
        guard let fix = issue.fix else { return }
        sourceText = fix(sourceText)
    }

    func applyAllFixes() {
        sourceText = NotesValidator.applyAllFixes(sourceText)
    }

    // MARK: - Save / dirty tracking

    enum SaveError: LocalizedError {
        case noURL
        case writeFailed(String)
        var errorDescription: String? {
            switch self {
            case .noURL: return "No destination file — use Save As."
            case .writeFailed(let reason): return "Couldn't save: \(reason)"
            }
        }
    }

    /// Write the current source back to `sourceURL`. Caller is responsible
    /// for catching errors and, if needed, falling back to Save As.
    func save() throws {
        guard let url = sourceURL else { throw SaveError.noURL }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            try sourceText.write(to: url, atomically: true, encoding: .utf8)
            lastSavedText = sourceText
            isDirty = false
        } catch {
            throw SaveError.writeFailed(error.localizedDescription)
        }
    }

    /// Called by the `fileExporter` completion handler when Save As succeeds.
    func didSaveAs(to url: URL) {
        sourceURL = url
        lastSavedText = sourceText
        isDirty = false
        Self.storeBookmark(for: url)
    }

    // MARK: - Sample content

    /// Immutable, `Sendable` — no reason to gate it behind the main actor
    /// just because the enclosing class happens to be `@MainActor`. Tests
    /// and previews need to read it without ceremony.
    nonisolated static let sampleMarkdown: String = """
    ## Welcome

    Thanks for joining today. I'm excited to walk you through what we've been
    building over the last few months and where it's headed next.

    ## The Problem

    Presenters today juggle two different things on stage: their slides, and
    their notes. Slides belong to the audience, notes belong to the speaker,
    and there is no good place to put the notes so they stay useful.

    ## Our Approach

    We built a dedicated notes surface. It lives on your laptop, it listens
    for a presentation remote, and when you feel adventurous it can even
    follow your voice and advance the notes as you speak.

    ## How It Works

    Notes are written in plain Markdown. Each H2 heading becomes a slide.
    Move between slides with the arrow keys or a presentation remote, or
    hit the listen button and let the app track where you are in the script.

    ## Thank You

    That's the whole pitch. I'd love to take questions now, and you can
    find me afterwards if you want to try a hands-on demo.
    """
}
