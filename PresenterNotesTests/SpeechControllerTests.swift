//
//  SpeechControllerTests.swift
//  PresenterNotesTests
//
//  Speech recognition can't be unit tested without a real microphone,
//  but we *can* test the pure-logic bits: how the trailing-word
//  provider hook interacts with the view model, and how
//  `NotesDocument.trailingWords` feeds into it.
//

import XCTest
@testable import PresenterNotes

final class SpeechControllerTests: XCTestCase {

    func test_init_defaultStateIsIdle() {
        let c = SpeechController()
        XCTAssertFalse(c.isRunning)
        XCTAssertEqual(c.lastTranscript, "")
    }

    func test_onAdvanceDetected_firesCallback() {
        let c = SpeechController()
        var fired = 0
        c.onAdvanceDetected = { fired += 1 }
        // We can't invoke the private matcher directly, but we can sanity
        // check that the hook is settable and invocable from the outside.
        c.onAdvanceDetected?()
        XCTAssertEqual(fired, 1)
    }

    func test_trailingWordsProvider_readsFromViewModel() {
        let vm = NotesViewModel()
        vm.loadMarkdown("## Title\n\nfirst second third fourth fifth sixth\n")
        let c = SpeechController()
        c.currentTrailingWordsProvider = { vm.currentSlide?.trailingWords ?? [] }

        let provided = c.currentTrailingWordsProvider?() ?? []
        XCTAssertEqual(provided, ["first", "second", "third", "fourth", "fifth", "sixth"])

        vm.sourceText = "## Title\n\nalpha beta gamma delta epsilon zeta\n"
        let provided2 = c.currentTrailingWordsProvider?() ?? []
        XCTAssertEqual(provided2, ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"])
    }

    func test_advanceCallback_wiredToViewModelNext() {
        let vm = NotesViewModel()
        vm.loadSample()
        let c = SpeechController()
        c.onAdvanceDetected = { vm.next() }

        let start = vm.currentIndex
        c.onAdvanceDetected?()
        XCTAssertEqual(vm.currentIndex, start + 1)
    }

    func test_stop_isIdempotent() {
        let c = SpeechController()
        c.stop()
        c.stop()
        XCTAssertFalse(c.isRunning)
    }

    // MARK: - Transcript delta → onWordsRecognised

    func test_updateRolling_firesOnlyDeltaOfNewWords() {
        let c = SpeechController()
        var batches: [[String]] = []
        c.onWordsRecognised = { batches.append($0) }

        c.updateRolling(with: "hello world")
        c.updateRolling(with: "hello world this is a test")
        c.updateRolling(with: "hello world this is a test")

        XCTAssertEqual(batches, [
            ["hello", "world"],
            ["this", "is", "a", "test"]
        ])
    }

    func test_updateRolling_handlesSessionRestartAsFreshTranscript() {
        let c = SpeechController()
        var batches: [[String]] = []
        c.onWordsRecognised = { batches.append($0) }

        c.updateRolling(with: "alpha beta gamma")
        // Simulate a recogniser session restart: the new transcript is
        // shorter than the last one. The controller should treat every
        // word as new rather than doing nothing.
        c.updateRolling(with: "delta")

        XCTAssertEqual(batches, [
            ["alpha", "beta", "gamma"],
            ["delta"]
        ])
    }

    // MARK: - Session-boundary trailing-words matching

    func test_updateRolling_advancesWhenTrailingWordsSpokenInSingleSession() {
        let c = SpeechController()
        c.currentTrailingWordsProvider = { ["where", "its", "headed", "next"] }
        var advanceCount = 0
        c.onAdvanceDetected = { advanceCount += 1 }

        c.updateRolling(with: "thanks for joining today where it's headed next")
        XCTAssertEqual(advanceCount, 1, "Trailing words present → should advance")
    }

    /// Regression test: SFSpeechRecognizer ends sessions frequently
    /// (pauses, sentence boundaries, ~1-minute cap). If a session ends
    /// mid-utterance, the next session's transcript starts empty. The
    /// controller must carry the pre-restart rolling window across the
    /// boundary so trailing-words matches spanning it still fire.
    func test_updateRolling_advancesWhenTrailingWordsStraddleSessionBoundary() {
        let c = SpeechController()
        c.currentTrailingWordsProvider = { ["where", "its", "headed", "next"] }
        var advanceCount = 0
        c.onAdvanceDetected = { advanceCount += 1 }

        // Session 1: presenter is mid-slide, approaching the trailing words.
        c.updateRolling(with: "thanks for joining today where it's")
        XCTAssertEqual(advanceCount, 0, "Mid-slide should not advance")

        // The underlying recogniser ends its session. A new one is about to
        // start with an empty transcript.
        c.handleSessionRestart()

        // Session 2: presenter finishes the slide.
        c.updateRolling(with: "headed next")
        XCTAssertEqual(advanceCount, 1,
                       "Trailing-words match should survive a session restart")
    }

    // MARK: - Loose (fuzzy) matching

    private func makeMatcher(loose: Bool,
                             needle: [String] = ["where", "it", "s", "headed", "next"]
    ) -> (SpeechController, () -> Int) {
        let c = SpeechController()
        c.looseMatching = loose
        c.currentTrailingWordsProvider = { needle }
        var count = 0
        c.onAdvanceDetected = { count += 1 }
        return (c, { count })
    }

    func test_looseMatching_off_rejectsInsertedFiller() {
        let (c, advances) = makeMatcher(loose: false)
        c.updateRolling(with: "where it s uh headed next")
        XCTAssertEqual(advances(), 0, "Strict mode must reject filler words")
    }

    func test_looseMatching_on_acceptsInsertedFiller() {
        let (c, advances) = makeMatcher(loose: true)
        c.updateRolling(with: "where it s uh headed next")
        XCTAssertEqual(advances(), 1, "Loose mode should absorb one filler word")
    }

    func test_looseMatching_on_acceptsTwoInsertedFillers() {
        let (c, advances) = makeMatcher(loose: true)
        // Two fillers, one between "it" and "s" and one between "s" and "headed".
        c.updateRolling(with: "where it um s uh headed next")
        XCTAssertEqual(advances(), 1, "Loose mode should tolerate up to two fillers")
    }

    func test_looseMatching_on_acceptsSingleSubstitution() {
        let (c, advances) = makeMatcher(loose: true)
        // "headed" misrecognised as "heading".
        c.updateRolling(with: "where it s heading next")
        XCTAssertEqual(advances(), 1, "Loose mode should accept one substituted word")
    }

    func test_looseMatching_on_acceptsLeadingSubstitution() {
        let (c, advances) = makeMatcher(loose: true)
        // Homophone: "were" for "where".
        c.updateRolling(with: "were it s headed next")
        XCTAssertEqual(advances(), 1, "Loose mode should accept a mis-heard first word")
    }

    func test_looseMatching_on_rejectsTooManyMismatches() {
        let (c, advances) = makeMatcher(loose: true)
        // Three of five needle words wrong — over budget.
        c.updateRolling(with: "alpha beta s gamma delta")
        XCTAssertEqual(advances(), 0, "Loose mode must still reject heavily wrong input")
    }

    func test_looseMatching_off_preservesExactMatch() {
        let (c, advances) = makeMatcher(loose: false)
        c.updateRolling(with: "thanks for joining today where it s headed next")
        XCTAssertEqual(advances(), 1, "Strict mode must still accept exact matches")
    }

    func test_updateRolling_plusViewModel_highlightsSlideInOrder() {
        let vm = NotesViewModel()
        vm.loadMarkdown("## Title\n\nalpha beta gamma delta epsilon\n")
        let c = SpeechController()
        c.onWordsRecognised = { words in vm.observeRecognisedWords(words) }

        c.updateRolling(with: "alpha beta")
        XCTAssertEqual(vm.spokenWordCount, 2)
        c.updateRolling(with: "alpha beta gamma delta")
        XCTAssertEqual(vm.spokenWordCount, 4)
        c.updateRolling(with: "alpha beta gamma delta epsilon")
        XCTAssertEqual(vm.spokenWordCount, 5)
    }
}
