//
//  NotesValidatorTests.swift
//  PresenterNotesTests
//

import XCTest
@testable import PresenterNotes

final class NotesValidatorTests: XCTestCase {

    // MARK: - clean documents

    func test_validate_cleanSample_noIssues() {
        let source = NotesViewModel.sampleMarkdown
        let issues = NotesValidator.validate(source)
        XCTAssertTrue(issues.isEmpty, "Sample markdown should pass validation: \(issues.map { $0.message })")
    }

    // MARK: - H1

    func test_h1_flaggedAsWarning_withFix() {
        let source = "# Heading\n\nBody."
        let issues = NotesValidator.validate(source)
        XCTAssertEqual(issues.count, 1)
        XCTAssertEqual(issues[0].severity, .warning)
        XCTAssertNotNil(issues[0].fix)
        XCTAssertTrue(issues[0].message.contains("H1"))
    }

    func test_h1_fix_convertsToH2() {
        let source = "# Heading\n\nBody."
        let fixed = NotesValidator.applyAllFixes(source)
        XCTAssertTrue(fixed.hasPrefix("## Heading"))
        XCTAssertTrue(NotesValidator.validate(fixed).isEmpty)
    }

    // MARK: - H3+

    func test_h3_flaggedAsWarning_withFix() {
        let source = """
        ## Slide

        ### Sub

        Body.
        """
        let issues = NotesValidator.validate(source)
        let h3Issues = issues.filter { $0.message.contains("H3") }
        XCTAssertEqual(h3Issues.count, 1)
        XCTAssertNotNil(h3Issues[0].fix)
    }

    func test_h3_fix_convertsToBoldText() {
        let source = """
        ## Slide

        ### Sub

        Body.
        """
        let fixed = NotesValidator.applyAllFixes(source)
        XCTAssertTrue(fixed.contains("**Sub**"))
        XCTAssertFalse(fixed.contains("### Sub"))
    }

    func test_h4_flaggedWithDepthInMessage() {
        let source = "## Slide\n\n#### Deeper\n"
        let issues = NotesValidator.validate(source)
        let deepIssues = issues.filter { $0.message.contains("H4") }
        XCTAssertEqual(deepIssues.count, 1)
    }

    // MARK: - Empty H2 title

    func test_emptyH2Title_flaggedAsError_withFix() {
        let source = "##\n\nBody without title."
        let issues = NotesValidator.validate(source)
        XCTAssertTrue(issues.contains { $0.severity == .error && $0.message.contains("Empty slide title") })
    }

    func test_emptyH2Title_fix_insertsUntitled() {
        let source = "##\n\nBody."
        let fixed = NotesValidator.applyAllFixes(source)
        XCTAssertTrue(fixed.contains("## Untitled"))
    }

    func test_h2WithOnlyTrailingHashes_flaggedAsEmpty() {
        let source = "##  ##\n\nBody."
        let issues = NotesValidator.validate(source)
        XCTAssertTrue(issues.contains { $0.severity == .error })
    }

    // MARK: - Empty body

    func test_slideWithNoBody_flaggedAsWarning_noAutoFix() {
        let source = """
        ## First

        Body.

        ## Empty

        ## Third

        Body three.
        """
        let issues = NotesValidator.validate(source)
        let emptyBody = issues.filter { $0.message.contains("has no body") }
        XCTAssertEqual(emptyBody.count, 1)
        XCTAssertEqual(emptyBody[0].severity, .warning)
        XCTAssertNil(emptyBody[0].fix)
    }

    // MARK: - Document with no H2

    func test_noH2_flaggedAsError_withFix() {
        let source = "Just some paragraph text."
        let issues = NotesValidator.validate(source)
        XCTAssertTrue(issues.contains { $0.severity == .error && $0.message.contains("No H2 slides") })
    }

    func test_noH2_fix_wrapsContentInUntitledSlide() {
        let source = "Just some paragraph text."
        let fixed = NotesValidator.applyAllFixes(source)
        XCTAssertTrue(fixed.contains("## Untitled"))
        XCTAssertTrue(fixed.contains("Just some paragraph text."))
    }

    func test_emptyDocument_noH2Error_fix_insertsSkeleton() {
        let issues = NotesValidator.validate("")
        XCTAssertTrue(issues.contains { $0.message.contains("No H2 slides") })
        let fixed = NotesValidator.applyAllFixes("")
        XCTAssertTrue(fixed.contains("## Untitled"))
    }

    // MARK: - applyAllFixes is idempotent on clean docs

    func test_applyAllFixes_isIdempotent_onCleanDoc() {
        let clean = NotesViewModel.sampleMarkdown
        let once = NotesValidator.applyAllFixes(clean)
        let twice = NotesValidator.applyAllFixes(once)
        XCTAssertEqual(once, clean)
        XCTAssertEqual(twice, clean)
    }

    // MARK: - apply single fix updates only its line

    func test_singleFix_onlyTouchesIntendedLine() throws {
        let source = """
        ## Good

        Body.

        # BadH1

        More.
        """
        let issues = NotesValidator.validate(source)
        let h1Issue = try XCTUnwrap(issues.first { $0.message.contains("H1") })
        let fix = try XCTUnwrap(h1Issue.fix)
        let fixed = fix(source)
        XCTAssertTrue(fixed.contains("## BadH1"))
        XCTAssertFalse(fixed.contains("# BadH1"))
        // Original "## Good" should still be untouched.
        XCTAssertTrue(fixed.contains("## Good"))
    }

    // MARK: - applyAllFixes clears all auto-fixable issues

    func test_applyAllFixes_resolvesEveryAutoFixableIssue() {
        let messy = """
        # Intro

        ### Gotcha

        ##
        """
        let fixed = NotesValidator.applyAllFixes(messy)
        let remaining = NotesValidator.validate(fixed)
        // Only non-auto-fixable issues should remain (empty body is warn-only).
        XCTAssertTrue(remaining.allSatisfy { $0.fix == nil })
    }
}

