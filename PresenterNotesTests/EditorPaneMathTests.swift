//
//  EditorPaneMathTests.swift
//  PresenterNotesTests
//
//  Pure-function tests for `EditorPane.characterOffset(forSlide:in:)`
//  and `EditorPane.slideIndex(forCursorAt:in:)`. These drive the
//  outline ↔ editor scroll sync and the cursor-follows-slide
//  behaviour.
//
//  Offsets are UTF-16 code-unit counts because production consumes
//  them as `NSRange.location` on `NSTextView`. Tests therefore index
//  with `NSString.substring(from:)` / `nsText.range(of:).location`
//  rather than `String.index(_:offsetBy:)` (which counts grapheme
//  clusters and would quietly lie about offsets that contain emoji,
//  CJK, or composed characters).
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
        XCTAssertTrue((text as NSString).substring(from: offset).hasPrefix("## Two"))
    }

    func test_characterOffset_preamble_isSlideZero() {
        // A document with content before the first H2 has the preamble
        // at slide 0, so offset 0 is the start of the preamble text.
        let text = "Intro line.\n\n## First\n\nBody.\n"
        XCTAssertEqual(EditorPane.characterOffset(forSlide: 0, in: text), 0)

        let offset1 = EditorPane.characterOffset(forSlide: 1, in: text)
        XCTAssertTrue((text as NSString).substring(from: offset1).hasPrefix("## First"))
    }

    func test_characterOffset_outOfRangeSlide_clampsToEnd() {
        // Past-the-last-slide requests shouldn't crash; they should
        // return a position near the end so downstream scroll-to-range
        // lands safely.
        let text = "## Only\n\nBody.\n"
        let offset = EditorPane.characterOffset(forSlide: 99, in: text)
        XCTAssertGreaterThanOrEqual(offset, 0)
        XCTAssertLessThanOrEqual(offset, (text as NSString).length)
    }

    func test_characterOffset_emptyText_returnsZeroOrClamped() {
        XCTAssertEqual(EditorPane.characterOffset(forSlide: 0, in: ""), 0)
    }

    func test_characterOffset_indentedHeading_stillCounts() {
        // Leading whitespace on an H2 line is tolerated by h2Title,
        // so the offset math should pick it up as a slide boundary.
        let text = "## One\n\nBody.\n  ## Two\n\nBody.\n"
        let offset1 = EditorPane.characterOffset(forSlide: 1, in: text)
        XCTAssertTrue((text as NSString).substring(from: offset1).hasPrefix("  ## Two"))
    }

    func test_characterOffset_multibyteContent_returnsUTF16Offset() {
        // Regression: the walker used `line.count` (grapheme clusters),
        // so any line with emoji or surrogate-pair characters produced
        // an offset that NSTextView then consumed as a UTF-16 position
        // — landing mid-character of the next line. "👋" is a single
        // Swift Character but two UTF-16 code units.
        let text = "## Hello 👋\n\nBody.\n## Two\n\nBody.\n"
        let offset = EditorPane.characterOffset(forSlide: 1, in: text)
        let ns = text as NSString
        XCTAssertTrue(ns.substring(from: offset).hasPrefix("## Two"))
        // The character-count offset would have been off by 1 (the
        // emoji), pointing one UTF-16 unit earlier.
        let characterCountOffset = offset - 1
        XCTAssertFalse(
            ns.substring(from: characterCountOffset).hasPrefix("## Two"),
            "test would pass under the old grapheme-cluster counting, invalidating the regression"
        )
    }

    // MARK: - slideIndex

    func test_slideIndex_atStart_returnsZero() {
        let text = "## One\n\nBody.\n## Two\n\nBody.\n"
        XCTAssertEqual(EditorPane.slideIndex(forCursorAt: 0, in: text), 0)
    }

    func test_slideIndex_insideFirstSlide_returnsZero() {
        let text = "## One\n\nBody.\n## Two\n\nBody.\n"
        let cursor = (text as NSString).range(of: "Body.").location
        XCTAssertEqual(EditorPane.slideIndex(forCursorAt: cursor, in: text), 0)
    }

    func test_slideIndex_insideSecondSlide_returnsOne() {
        let text = "## One\n\nBody.\n## Two\n\nTwoBody.\n"
        let cursor = (text as NSString).range(of: "TwoBody.").location
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

        let ns = text as NSString
        // Cursor still in preamble → slide 0.
        let cursor = ns.range(of: "Intro").location
        XCTAssertEqual(EditorPane.slideIndex(forCursorAt: cursor, in: text), 0)

        // Cursor in first titled slide → slide 1.
        let cursor2 = ns.range(of: "Body.").location
        XCTAssertEqual(EditorPane.slideIndex(forCursorAt: cursor2, in: text), 1)
    }

    func test_slideIndex_emptyText_returnsZero() {
        XCTAssertEqual(EditorPane.slideIndex(forCursorAt: 0, in: ""), 0)
    }

    func test_slideIndex_multibyteContent_walksUTF16() {
        // Symmetric to the characterOffset multibyte regression: with
        // an emoji in slide 0, a UTF-16 cursor landing inside slide 1
        // must still return 1.
        let text = "## Hello 👋\n\nBody.\n## Two\n\nTwoBody.\n"
        let cursor = (text as NSString).range(of: "TwoBody.").location
        XCTAssertEqual(EditorPane.slideIndex(forCursorAt: cursor, in: text), 1)
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
