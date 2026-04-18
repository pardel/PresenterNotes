//
//  EditorPaneMathTests.swift
//  PresenterNotesTests
//
//  Pure-function tests for `EditorPane.characterOffset(forSlide:in:)`
//  and `EditorPane.slideIndex(forCursorAt:in:)`. These drive the
//  outline ↔ editor scroll sync and the cursor-follows-slide
//  behaviour, so they need to agree with `NotesDocument.parse` about
//  where slide boundaries live.
//

import XCTest
@testable import PresenterNotes

final class EditorPaneMathTests: XCTestCase {

    // MARK: - characterOffset

    func test_characterOffset_firstSlide_returnsZero() {
        let text = "## One\n\nBody.\n## Two\n\nBody.\n"
        XCTAssertEqual(EditorPane.characterOffset(forSlide: 0, in: text), 0)
    }

    func test_characterOffset_secondSlide_pointsAtItsHeading() {
        let text = "## One\n\nBody.\n## Two\n\nBody.\n"
        let offset = EditorPane.characterOffset(forSlide: 1, in: text)
        let start = text.index(text.startIndex, offsetBy: offset)
        XCTAssertTrue(text[start...].hasPrefix("## Two"))
    }

    func test_characterOffset_preamble_isSlideZero() {
        // A document with content before the first H2 has the preamble
        // at slide 0, so offset 0 is the start of the preamble text.
        let text = "Intro line.\n\n## First\n\nBody.\n"
        XCTAssertEqual(EditorPane.characterOffset(forSlide: 0, in: text), 0)

        let offset1 = EditorPane.characterOffset(forSlide: 1, in: text)
        let start = text.index(text.startIndex, offsetBy: offset1)
        XCTAssertTrue(text[start...].hasPrefix("## First"))
    }

    func test_characterOffset_outOfRangeSlide_clampsToEnd() {
        // Past-the-last-slide requests shouldn't crash; they should
        // return a position near the end so downstream scroll-to-range
        // lands safely.
        let text = "## Only\n\nBody.\n"
        let offset = EditorPane.characterOffset(forSlide: 99, in: text)
        XCTAssertGreaterThanOrEqual(offset, 0)
        XCTAssertLessThanOrEqual(offset, text.count)
    }

    func test_characterOffset_emptyText_returnsZeroOrClamped() {
        XCTAssertEqual(EditorPane.characterOffset(forSlide: 0, in: ""), 0)
    }

    func test_characterOffset_indentedHeading_stillCounts() {
        // Leading whitespace on an H2 line is tolerated by h2Title,
        // so the offset math should pick it up as a slide boundary.
        let text = "## One\n\nBody.\n  ## Two\n\nBody.\n"
        let offset1 = EditorPane.characterOffset(forSlide: 1, in: text)
        let start = text.index(text.startIndex, offsetBy: offset1)
        XCTAssertTrue(text[start...].hasPrefix("  ## Two"))
    }

    // MARK: - slideIndex

    func test_slideIndex_atStart_returnsZero() {
        let text = "## One\n\nBody.\n## Two\n\nBody.\n"
        XCTAssertEqual(EditorPane.slideIndex(forCursorAt: 0, in: text), 0)
    }

    func test_slideIndex_insideFirstSlide_returnsZero() {
        let text = "## One\n\nBody.\n## Two\n\nBody.\n"
        // Cursor somewhere inside the first body line.
        let cursor = text.distance(
            from: text.startIndex,
            to: text.range(of: "Body.")!.lowerBound
        )
        XCTAssertEqual(EditorPane.slideIndex(forCursorAt: cursor, in: text), 0)
    }

    func test_slideIndex_insideSecondSlide_returnsOne() {
        let text = "## One\n\nBody.\n## Two\n\nTwoBody.\n"
        let cursor = text.distance(
            from: text.startIndex,
            to: text.range(of: "TwoBody.")!.lowerBound
        )
        XCTAssertEqual(EditorPane.slideIndex(forCursorAt: cursor, in: text), 1)
    }

    func test_slideIndex_pastEnd_returnsLast() {
        let text = "## One\n\nBody.\n## Two\n\nBody.\n"
        let idx = EditorPane.slideIndex(forCursorAt: 9999, in: text)
        XCTAssertEqual(idx, 1)  // only two slides, last is index 1
    }

    func test_slideIndex_preamble_returnsZeroForTextBeforeFirstH2() {
        let text = "Intro text before heading.\n\n## First\n\nBody.\n"
        XCTAssertEqual(EditorPane.slideIndex(forCursorAt: 0, in: text), 0)

        // Cursor still in preamble → slide 0.
        let cursor = text.distance(
            from: text.startIndex,
            to: text.range(of: "Intro")!.lowerBound
        )
        XCTAssertEqual(EditorPane.slideIndex(forCursorAt: cursor, in: text), 0)

        // Cursor in first titled slide → slide 1.
        let cursor2 = text.distance(
            from: text.startIndex,
            to: text.range(of: "Body.")!.lowerBound
        )
        XCTAssertEqual(EditorPane.slideIndex(forCursorAt: cursor2, in: text), 1)
    }

    func test_slideIndex_emptyText_returnsZero() {
        XCTAssertEqual(EditorPane.slideIndex(forCursorAt: 0, in: ""), 0)
    }

    // MARK: - Round-trip

    func test_roundTrip_offsetThenIndex_recoversSlideNumber() {
        let text = """
        ## One

        First body.

        ## Two

        Second body.

        ## Three

        Third body.
        """
        for slide in 0...2 {
            let offset = EditorPane.characterOffset(forSlide: slide, in: text)
            let recovered = EditorPane.slideIndex(forCursorAt: offset, in: text)
            XCTAssertEqual(recovered, slide, "slide \(slide) did not round-trip")
        }
    }
}
