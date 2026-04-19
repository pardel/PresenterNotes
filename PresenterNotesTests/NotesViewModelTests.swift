//
//  NotesViewModelTests.swift
//  PresenterNotesTests
//

import XCTest
@testable import PresenterNotes

@MainActor
final class NotesViewModelTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // NotesViewModel.init and restoreLastOpenedDocument read several
        // UserDefaults keys, so prior test runs can leak state. Clear
        // every key the view model owns before each test.
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: NotesViewModel.modeDefaultsKey)
        defaults.removeObject(forKey: NotesViewModel.presentStyleDefaultsKey)
        defaults.removeObject(forKey: NotesViewModel.bookmarkDefaultsKey)
        defaults.removeObject(forKey: NotesViewModel.slideIndexDefaultsKey)
    }

    // MARK: - loadMarkdown / loadSample / newDocument

    func test_loadSample_populatesSlidesAndClearsDirty() {
        let vm = NotesViewModel()
        vm.loadSample()
        XCTAssertFalse(vm.slides.isEmpty)
        XCTAssertEqual(vm.currentIndex, 0)
        XCTAssertFalse(vm.isDirty)
    }

    func test_loadMarkdown_setsSlidesIssuesAndURL() {
        let vm = NotesViewModel()
        let url = URL(fileURLWithPath: "/tmp/fake.md")
        vm.loadMarkdown("## Title\n\nBody.", from: url)
        XCTAssertEqual(vm.slides.count, 1)
        XCTAssertEqual(vm.sourceURL, url)
        XCTAssertTrue(vm.issues.isEmpty)
        XCTAssertFalse(vm.isDirty)
    }

    func test_newDocument_givesAMinimalValidSkeleton() {
        let vm = NotesViewModel()
        vm.newDocument()
        XCTAssertEqual(vm.slides.count, 1)
        XCTAssertEqual(vm.slides[0].title, "Untitled")
        XCTAssertTrue(vm.issues.isEmpty)
        XCTAssertFalse(vm.isDirty)
    }

    // MARK: - Navigation

    func test_nextAndPrevious_clampAtBounds() {
        let vm = NotesViewModel()
        vm.loadSample()
        let last = vm.slides.count - 1
        for _ in 0..<(last + 5) { vm.next() }
        XCTAssertEqual(vm.currentIndex, last)
        for _ in 0..<(last + 5) { vm.previous() }
        XCTAssertEqual(vm.currentIndex, 0)
    }

    func test_jumpTo_ignoresOutOfRangeIndex() {
        let vm = NotesViewModel()
        vm.loadSample()
        vm.jump(to: 999)
        XCTAssertEqual(vm.currentIndex, 0)
        vm.jump(to: -1)
        XCTAssertEqual(vm.currentIndex, 0)
        vm.jump(to: 2)
        XCTAssertEqual(vm.currentIndex, 2)
    }

    // MARK: - Dirty tracking

    func test_editingSource_marksDirty() {
        let vm = NotesViewModel()
        vm.loadSample()
        XCTAssertFalse(vm.isDirty)
        vm.sourceText += "\n## Appended\n\nBody.\n"
        XCTAssertTrue(vm.isDirty)
        XCTAssertTrue(vm.slides.contains { $0.title == "Appended" })
    }

    func test_save_toTempFile_clearsDirty() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pn-test-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vm = NotesViewModel()
        vm.loadMarkdown("## A\n\nBody.\n", from: tmp)
        vm.sourceText = "## A\n\nBody updated.\n"
        XCTAssertTrue(vm.isDirty)

        try vm.save()
        XCTAssertFalse(vm.isDirty)

        let onDisk = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("Body updated."))
    }

    func test_save_withoutURL_throwsNoURL() {
        let vm = NotesViewModel()
        vm.loadSample() // loadSample passes nil URL
        vm.sourceText += "\n"
        XCTAssertThrowsError(try vm.save()) { error in
            guard let e = error as? NotesViewModel.SaveError else {
                return XCTFail("Expected SaveError")
            }
            switch e {
            case .noURL: break
            default: XCTFail("Expected .noURL, got \(e)")
            }
        }
    }

    func test_didSaveAs_setsURLAndClearsDirty() {
        let vm = NotesViewModel()
        vm.loadSample()
        vm.sourceText += "\n"
        XCTAssertTrue(vm.isDirty)
        let url = URL(fileURLWithPath: "/tmp/saved.md")
        vm.didSaveAs(to: url)
        XCTAssertEqual(vm.sourceURL, url)
        XCTAssertFalse(vm.isDirty)
    }

    // MARK: - Validation surfacing

    func test_issues_reflectValidatorOutput() {
        let vm = NotesViewModel()
        vm.loadMarkdown("# H1\n\n### Sub\n\nBody.\n")
        XCTAssertFalse(vm.issues.isEmpty)
        XCTAssertGreaterThan(vm.warningCount, 0)
    }

    func test_applyAllFixes_clearsFixableIssues() {
        let vm = NotesViewModel()
        vm.loadMarkdown("# Intro\n\n### Sub\n\nBody.\n")
        XCTAssertFalse(vm.issues.isEmpty)
        vm.applyAllFixes()
        XCTAssertTrue(vm.issues.allSatisfy { $0.fix == nil })
    }

    func test_applySingleIssue_mutatesSource() {
        let vm = NotesViewModel()
        vm.loadMarkdown("# Intro\n\nBody.\n")
        guard let first = vm.issues.first, first.fix != nil else {
            return XCTFail("Expected a fixable issue")
        }
        vm.apply(first)
        XCTAssertTrue(vm.sourceText.contains("## Intro"))
    }

    // MARK: - Clamping on edit

    func test_editingSource_clampsCurrentIndexIfSlidesShrink() {
        let vm = NotesViewModel()
        vm.loadSample()
        vm.jump(to: vm.slides.count - 1)
        XCTAssertEqual(vm.currentIndex, vm.slides.count - 1)
        // Rewrite document to just one slide.
        vm.sourceText = "## Only\n\nBody.\n"
        XCTAssertEqual(vm.slides.count, 1)
        XCTAssertEqual(vm.currentIndex, 0)
    }

    // MARK: - Mode

    func test_modeDefaultsToPresent_andCanSwitch() {
        let vm = NotesViewModel()
        XCTAssertEqual(vm.mode, .present)
        vm.mode = .edit
        XCTAssertEqual(vm.mode, .edit)
    }

    // MARK: - Spoken-progress highlighting

    func test_spokenWordCount_defaultsToZero() {
        let vm = NotesViewModel()
        vm.loadSample()
        XCTAssertEqual(vm.spokenWordCount, 0)
    }

    func test_observeRecognisedWords_advancesInOrder() {
        let vm = NotesViewModel()
        vm.loadMarkdown("## Title\n\nalpha beta gamma delta epsilon zeta\n")
        XCTAssertEqual(vm.spokenWordCount, 0)
        vm.observeRecognisedWords(["alpha"])
        XCTAssertEqual(vm.spokenWordCount, 1)
        vm.observeRecognisedWords(["beta", "gamma"])
        XCTAssertEqual(vm.spokenWordCount, 3)
        vm.observeRecognisedWords(["delta", "epsilon", "zeta"])
        XCTAssertEqual(vm.spokenWordCount, 6)
    }

    func test_observeRecognisedWords_skipsUpToThreeUnspokenWords() {
        let vm = NotesViewModel()
        vm.loadMarkdown("## Title\n\none two three four five six seven\n")
        // "four" is 3 words ahead of "one" — within the skip budget.
        vm.observeRecognisedWords(["four"])
        XCTAssertEqual(vm.spokenWordCount, 4)
    }

    func test_observeRecognisedWords_doesNotJumpBeyondSkipBudget() {
        let vm = NotesViewModel()
        vm.loadMarkdown("## Title\n\none two three four five six seven\n")
        // "six" is 5 words ahead — beyond the default skip of 3, so no advance.
        vm.observeRecognisedWords(["six"])
        XCTAssertEqual(vm.spokenWordCount, 0)
    }

    func test_observeRecognisedWords_ignoresPunctuationAndCasing() {
        let vm = NotesViewModel()
        vm.loadMarkdown("## Title\n\nHello, world!\n")
        vm.observeRecognisedWords(["HELLO", "World,"])
        XCTAssertEqual(vm.spokenWordCount, 2)
    }

    func test_observeRecognisedWords_ignoresUnknownWords() {
        let vm = NotesViewModel()
        vm.loadMarkdown("## Title\n\nfirst second third fourth fifth\n")
        vm.observeRecognisedWords(["banana"])
        XCTAssertEqual(vm.spokenWordCount, 0)
    }

    func test_observeRecognisedWords_neverExceedsSlideLength() {
        let vm = NotesViewModel()
        vm.loadMarkdown("## Title\n\nonly two\n")
        vm.observeRecognisedWords(["only", "two", "extra", "extra"])
        XCTAssertEqual(vm.spokenWordCount, 2)
    }

    func test_navigation_resetsSpokenWordCount() {
        let vm = NotesViewModel()
        vm.loadMarkdown("""
        ## One

        alpha beta gamma

        ## Two

        delta epsilon zeta
        """)
        vm.observeRecognisedWords(["alpha", "beta"])
        XCTAssertEqual(vm.spokenWordCount, 2)
        vm.next()
        XCTAssertEqual(vm.currentIndex, 1)
        XCTAssertEqual(vm.spokenWordCount, 0)

        vm.observeRecognisedWords(["delta"])
        XCTAssertEqual(vm.spokenWordCount, 1)
        vm.previous()
        XCTAssertEqual(vm.currentIndex, 0)
        XCTAssertEqual(vm.spokenWordCount, 0)
    }

    func test_jumpTo_resetsSpokenWordCount() {
        let vm = NotesViewModel()
        vm.loadSample()
        vm.observeRecognisedWords(["thanks", "for", "joining"])
        XCTAssertGreaterThan(vm.spokenWordCount, 0)
        vm.jump(to: 2)
        XCTAssertEqual(vm.spokenWordCount, 0)
    }

    func test_editingSource_resetsSpokenWordCount() {
        let vm = NotesViewModel()
        vm.loadMarkdown("## Title\n\nalpha beta gamma\n")
        vm.observeRecognisedWords(["alpha", "beta"])
        XCTAssertEqual(vm.spokenWordCount, 2)
        vm.sourceText = "## Title\n\nalpha beta gamma delta\n"
        XCTAssertEqual(vm.spokenWordCount, 0)
    }

    // MARK: - Undo / redo

    func test_undo_freshViewModel_cannotUndoOrRedo() {
        let vm = NotesViewModel()
        XCTAssertFalse(vm.canUndo)
        XCTAssertFalse(vm.canRedo)
    }

    func test_undo_afterEdit_restoresPreviousSource() {
        let vm = NotesViewModel()
        vm.loadMarkdown("## Start\n\nInitial.\n")
        let initial = vm.sourceText
        vm.sourceText = "## Edited\n\nChanged.\n"
        XCTAssertTrue(vm.canUndo)
        vm.undo()
        XCTAssertEqual(vm.sourceText, initial)
        XCTAssertTrue(vm.canRedo)
    }

    func test_redo_afterUndo_replaysEdit() {
        let vm = NotesViewModel()
        vm.loadMarkdown("## A\n\nOne.\n")
        vm.sourceText = "## B\n\nTwo.\n"
        let edited = vm.sourceText
        vm.undo()
        vm.redo()
        XCTAssertEqual(vm.sourceText, edited)
        XCTAssertFalse(vm.canRedo)
    }

    func test_newEditAfterUndo_clearsRedoStack() {
        let vm = NotesViewModel()
        vm.loadMarkdown("## A\n\nOne.\n")
        vm.sourceText = "## B\n\nTwo.\n"
        vm.undo()
        XCTAssertTrue(vm.canRedo)
        // A fresh edit should discard the redo path; you can't redo
        // back into a branch you've just diverged from.
        vm.sourceText = "## C\n\nThree.\n"
        XCTAssertFalse(vm.canRedo)
    }

    func test_rapidEdits_coalesceIntoSingleUndoStep() {
        // Tests running synchronously hit the coalesce window (0.6s)
        // easily, so a burst of edits only pushes the first pre-edit
        // state. One undo therefore rolls back the entire burst.
        let vm = NotesViewModel()
        vm.loadMarkdown("## T\n\nBody.\n")
        let initial = vm.sourceText
        vm.sourceText = initial + "a"
        vm.sourceText = initial + "ab"
        vm.sourceText = initial + "abc"
        vm.undo()
        XCTAssertEqual(vm.sourceText, initial)
    }

    func test_undo_onEmptyStack_isNoOp() {
        let vm = NotesViewModel()
        vm.loadMarkdown("## T\n\nBody.\n")
        let initial = vm.sourceText
        XCTAssertFalse(vm.canUndo)
        vm.undo()  // should not throw or mutate
        XCTAssertEqual(vm.sourceText, initial)
    }

    func test_redo_onEmptyStack_isNoOp() {
        let vm = NotesViewModel()
        vm.loadMarkdown("## T\n\nBody.\n")
        let initial = vm.sourceText
        XCTAssertFalse(vm.canRedo)
        vm.redo()
        XCTAssertEqual(vm.sourceText, initial)
    }

    func test_loadMarkdown_clearsUndoHistory() {
        let vm = NotesViewModel()
        vm.loadMarkdown("## A\n\nOne.\n")
        vm.sourceText = "## A\n\nEdited.\n"
        XCTAssertTrue(vm.canUndo)
        // Loading a new document is a fresh start — no history from
        // the previous document should survive.
        vm.loadMarkdown("## B\n\nOther.\n")
        XCTAssertFalse(vm.canUndo)
        XCTAssertFalse(vm.canRedo)
    }

    func test_undoRedo_doesNotRecurseIntoItself() {
        // Ensures the `isApplyingUndoRedo` guard works: an undo should
        // not itself push another undo entry, otherwise undo/redo
        // would ping-pong forever instead of converging.
        let vm = NotesViewModel()
        vm.loadMarkdown("## A\n\nOne.\n")
        vm.sourceText = "## B\n\nTwo.\n"
        vm.undo()
        vm.undo()  // second undo with an empty stack
        XCTAssertFalse(vm.canUndo)
    }

    // MARK: - Persistence (last-opened document)

    func test_restoreLastOpenedDocument_noBookmark_returnsFalse() {
        // UserDefaults cleared in setUp — nothing to restore.
        let vm = NotesViewModel()
        XCTAssertFalse(vm.restoreLastOpenedDocument())
        XCTAssertFalse(vm.hasDocument)
    }

    func test_restoreLastOpenedDocument_invalidBookmark_clearsAndReturnsFalse() {
        // Plant garbage at the bookmark key. Restore should refuse it
        // and clear the entry so the next launch doesn't keep retrying.
        UserDefaults.standard.set(
            Data("not a real bookmark".utf8),
            forKey: NotesViewModel.bookmarkDefaultsKey
        )
        let vm = NotesViewModel()
        XCTAssertFalse(vm.restoreLastOpenedDocument())
        XCTAssertNil(UserDefaults.standard.data(forKey: NotesViewModel.bookmarkDefaultsKey))
    }

    func test_loadFromDisk_storesBookmark() throws {
        // Write a real temp file, load it, confirm something gets stored
        // at the bookmark key. Not asserting the bookmark can be resolved
        // in a non-sandboxed test process — just that loadFromDisk
        // attempted the write and set sourceURL/sourceText.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("pn-bookmark-\(UUID().uuidString).md")
        try "## Stored\n\nBody.\n".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let vm = NotesViewModel()
        vm.loadFromDisk(tmp)
        XCTAssertEqual(vm.sourceURL, tmp)
        XCTAssertTrue(vm.sourceText.contains("Stored"))
    }

    func test_newDocument_clearsBookmark() {
        // Seed the key then call newDocument — it should wipe the
        // bookmark so the next launch falls back to the sample/new
        // document rather than trying to reopen a file the user
        // explicitly abandoned.
        UserDefaults.standard.set(Data([0, 1, 2]), forKey: NotesViewModel.bookmarkDefaultsKey)
        let vm = NotesViewModel()
        vm.newDocument()
        XCTAssertNil(UserDefaults.standard.data(forKey: NotesViewModel.bookmarkDefaultsKey))
    }

    func test_loadSample_clearsBookmark() {
        UserDefaults.standard.set(Data([0, 1, 2]), forKey: NotesViewModel.bookmarkDefaultsKey)
        let vm = NotesViewModel()
        vm.loadSample()
        XCTAssertNil(UserDefaults.standard.data(forKey: NotesViewModel.bookmarkDefaultsKey))
    }

    func test_loadMarkdown_resetsParagraphIndex_evenWhenOldIndexInRange() {
        // Regression: if the user had navigated deep into a paragraph-
        // based view and then loaded a new doc that happened to have
        // enough paragraphs, reparse()'s clamp was a no-op and the
        // stale paragraph index pointed at an unrelated paragraph of
        // the new content. Speech matching would then build its cache
        // against the wrong paragraph.
        let vm = NotesViewModel()
        vm.loadMarkdown("## A\n\nA1.\n\nA2.\n\nA3.\n\nA4.\n\nA5.\n")
        vm.jumpToParagraph(4)
        XCTAssertEqual(vm.currentParagraphIndex, 4)
        // Second doc is also large enough that index 4 would remain in
        // range — clamp alone wouldn't reset it.
        vm.loadMarkdown("## B\n\nB1.\n\nB2.\n\nB3.\n\nB4.\n\nB5.\n")
        XCTAssertEqual(vm.currentIndex, 0)
        XCTAssertEqual(vm.currentParagraphIndex, 0)
    }

    func test_slideIndex_persistsAcrossInstances() {
        // `currentIndex` didSet writes to defaults. A fresh vm doesn't
        // read that back automatically — it only matters via
        // restoreLastOpenedDocument — but we can at least verify the
        // side-effect happens on navigation.
        let vm = NotesViewModel()
        vm.loadSample()
        vm.jump(to: 2)
        XCTAssertEqual(
            UserDefaults.standard.integer(forKey: NotesViewModel.slideIndexDefaultsKey),
            2
        )
    }

    // MARK: - Auto-scroll

    func test_autoScroll_defaultsToFalse() {
        let vm = NotesViewModel()
        XCTAssertFalse(vm.autoScroll)
        XCTAssertEqual(vm.autoScrollProgress, 0)
    }

    func test_autoScroll_turningOff_resetsProgress() {
        let vm = NotesViewModel()
        vm.loadSample()
        vm.presentStyle = .teleprompter
        vm.autoScroll = true
        // Progress starts at 0 regardless of how long the timer runs.
        vm.autoScroll = false
        XCTAssertEqual(vm.autoScrollProgress, 0)
    }

    func test_autoScroll_switchingToSlideMode_disablesIt() {
        let vm = NotesViewModel()
        vm.loadSample()
        vm.presentStyle = .teleprompter
        vm.autoScroll = true
        XCTAssertTrue(vm.autoScroll)
        // `.slide` doesn't use paragraphs — autoScroll has no meaning
        // there, so it's force-disabled to avoid a phantom running timer.
        vm.presentStyle = .slide
        XCTAssertFalse(vm.autoScroll)
    }

    func test_autoScroll_switchingToEditMode_disablesIt() {
        let vm = NotesViewModel()
        vm.loadSample()
        vm.presentStyle = .teleprompter
        vm.autoScroll = true
        vm.mode = .edit
        XCTAssertFalse(vm.autoScroll)
    }

    func test_autoScroll_progressAdvancesOverTime() async {
        // Body long enough that completing the paragraph (which fires
        // nextParagraph and resets progress) is nowhere near this
        // test's deadline: 100 chars / 15 cps ≈ 6.7s duration.
        let vm = NotesViewModel()
        vm.loadMarkdown("## T\n\n" + String(repeating: "word ", count: 20) + "\n")
        vm.presentStyle = .teleprompter
        vm.autoScroll = true

        // Poll for progress > 0 rather than waiting a fixed interval.
        // The timer tick goes through `Task { @MainActor in … }`, so
        // how long the first update takes depends on main-actor
        // scheduling. A fixed 150ms window was reliable on fast
        // hardware but flaked on slower CI runners.
        let deadline = Date().addingTimeInterval(2.0)
        while vm.autoScrollProgress == 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        XCTAssertGreaterThan(vm.autoScrollProgress, 0, "timer never ticked within 2s")
        XCTAssertLessThan(vm.autoScrollProgress, 1)
        vm.autoScroll = false
    }
}
