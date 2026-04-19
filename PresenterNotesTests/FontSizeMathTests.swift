//
//  FontSizeMathTests.swift
//  PresenterNotesTests
//
//  Pure tests for the static font-sizing and paragraph-styling math
//  that decide whether slides are actually readable from the back of
//  a room. These live inside SwiftUI view files but don't touch any
//  SwiftUI state, so they test cleanly as unit tests.
//

import XCTest
import CoreGraphics
@testable import PresenterNotes

final class FontSizeMathTests: XCTestCase {

    // MARK: - FullScreenSlideView.bodyFontSize

    func test_bodyFontSize_clampedAboveMinimum() {
        // A catastrophically long slide in a small container should
        // floor at 36pt rather than shrinking into illegibility.
        let body = String(repeating: "word ", count: 10_000)
        let slide = NoteSlide(id: 0, title: "T", body: body, trailingWords: [])
        let size = FullScreenSlideView.bodyFontSize(
            for: slide,
            in: CGSize(width: 400, height: 300)
        )
        XCTAssertEqual(size, 36, accuracy: 0.01)
    }

    func test_bodyFontSize_clampedBelowMaximum() {
        // A tiny slide in a huge container shouldn't fly past 140pt.
        let slide = NoteSlide(id: 0, title: "T", body: "Hi.", trailingWords: [])
        let size = FullScreenSlideView.bodyFontSize(
            for: slide,
            in: CGSize(width: 4000, height: 3000)
        )
        XCTAssertEqual(size, 140, accuracy: 0.01)
    }

    func test_bodyFontSize_midRangeIsProportional() {
        // Quadrupling container area (2× width × 2× height) should
        // grow size by ~2× — sqrt(4) — since the formula is area-based.
        // Body length chosen so both cases land mid-clamp: too long
        // and the small container floors at 36; too short and the big
        // one caps at 140, either of which would mask the relationship.
        let body = String(repeating: "word ", count: 50)
        let slide = NoteSlide(id: 0, title: nil, body: body, trailingWords: [])
        let small = FullScreenSlideView.bodyFontSize(
            for: slide, in: CGSize(width: 800, height: 600)
        )
        let big = FullScreenSlideView.bodyFontSize(
            for: slide, in: CGSize(width: 1600, height: 1200)
        )
        XCTAssertGreaterThan(small, 36)
        XCTAssertLessThan(big, 140)
        XCTAssertEqual(big / small, 2.0, accuracy: 0.1)
    }

    func test_bodyFontSize_titlePresent_leavesLessRoomForBody() {
        let body = String(repeating: "word ", count: 100)
        let withTitle = NoteSlide(id: 0, title: "Heading", body: body, trailingWords: [])
        let without  = NoteSlide(id: 0, title: nil,       body: body, trailingWords: [])
        let container = CGSize(width: 1200, height: 800)
        let titled = FullScreenSlideView.bodyFontSize(for: withTitle, in: container)
        let plain  = FullScreenSlideView.bodyFontSize(for: without,   in: container)
        // Title steals 18% of the vertical budget, so body gets smaller.
        XCTAssertLessThan(titled, plain)
    }

    func test_bodyFontSize_emptyBody_doesNotDivideByZero() {
        let slide = NoteSlide(id: 0, title: nil, body: "", trailingWords: [])
        let size = FullScreenSlideView.bodyFontSize(
            for: slide, in: CGSize(width: 1200, height: 800)
        )
        // Empty body → 1-char fallback → size is very large but clamped.
        XCTAssertEqual(size, 140, accuracy: 0.01)
    }

    func test_bodyFontSize_tinyContainer_stillClampedSafely() {
        // Container floor inside the function prevents negative usable
        // area, so even absurdly small sizes should produce a finite,
        // clamped result.
        let slide = NoteSlide(id: 0, title: "T", body: "Some body.", trailingWords: [])
        let size = FullScreenSlideView.bodyFontSize(
            for: slide, in: CGSize(width: 10, height: 10)
        )
        XCTAssertGreaterThanOrEqual(size, 36)
        XCTAssertLessThanOrEqual(size, 140)
    }

    // MARK: - TeleprompterView.activeFontSize

    func test_activeFontSize_respectsBounds() {
        let para = TeleprompterParagraph(
            id: 0, slideIndex: 0, title: nil,
            text: "Medium-length paragraph with enough words to compute a reasonable size.",
            isFirstInSlide: true, isLastInSlide: true
        )
        let size = TeleprompterView.activeFontSize(
            for: para, viewportWidth: 1200, viewportHeight: 800,
            maxSize: 80, minSize: 48
        )
        XCTAssertGreaterThanOrEqual(size, 48)
        XCTAssertLessThanOrEqual(size, 80)
    }

    func test_activeFontSize_longParagraph_floorsAtMin() {
        let para = TeleprompterParagraph(
            id: 0, slideIndex: 0, title: nil,
            text: String(repeating: "word ", count: 5000),
            isFirstInSlide: true, isLastInSlide: true
        )
        let size = TeleprompterView.activeFontSize(
            for: para, viewportWidth: 800, viewportHeight: 600,
            maxSize: 80, minSize: 48
        )
        XCTAssertEqual(size, 48, accuracy: 0.01)
    }

    func test_activeFontSize_shortParagraph_capsAtMax() {
        let para = TeleprompterParagraph(
            id: 0, slideIndex: 0, title: nil, text: "Short.",
            isFirstInSlide: true, isLastInSlide: true
        )
        let size = TeleprompterView.activeFontSize(
            for: para, viewportWidth: 2000, viewportHeight: 1500,
            maxSize: 80, minSize: 48
        )
        XCTAssertEqual(size, 80, accuracy: 0.01)
    }

    // MARK: - TeleprompterView.cornerRadii

    func test_cornerRadii_firstInSlide_roundsTopOnly() {
        let para = TeleprompterParagraph(
            id: 0, slideIndex: 0, title: nil, text: "t",
            isFirstInSlide: true, isLastInSlide: false
        )
        let radii = TeleprompterView.cornerRadii(for: para)
        XCTAssertGreaterThan(radii.topLeading, 0)
        XCTAssertGreaterThan(radii.topTrailing, 0)
        XCTAssertEqual(radii.bottomLeading, 0)
        XCTAssertEqual(radii.bottomTrailing, 0)
    }

    func test_cornerRadii_lastInSlide_roundsBottomOnly() {
        let para = TeleprompterParagraph(
            id: 0, slideIndex: 0, title: nil, text: "t",
            isFirstInSlide: false, isLastInSlide: true
        )
        let radii = TeleprompterView.cornerRadii(for: para)
        XCTAssertEqual(radii.topLeading, 0)
        XCTAssertEqual(radii.topTrailing, 0)
        XCTAssertGreaterThan(radii.bottomLeading, 0)
        XCTAssertGreaterThan(radii.bottomTrailing, 0)
    }

    func test_cornerRadii_middleParagraph_allSquare() {
        let para = TeleprompterParagraph(
            id: 0, slideIndex: 0, title: nil, text: "t",
            isFirstInSlide: false, isLastInSlide: false
        )
        let radii = TeleprompterView.cornerRadii(for: para)
        XCTAssertEqual(radii.topLeading, 0)
        XCTAssertEqual(radii.topTrailing, 0)
        XCTAssertEqual(radii.bottomLeading, 0)
        XCTAssertEqual(radii.bottomTrailing, 0)
    }

    func test_cornerRadii_singleParagraphSlide_fullyRounded() {
        // A single-paragraph slide is both first and last, so every
        // corner should round.
        let para = TeleprompterParagraph(
            id: 0, slideIndex: 0, title: nil, text: "t",
            isFirstInSlide: true, isLastInSlide: true
        )
        let radii = TeleprompterView.cornerRadii(for: para)
        XCTAssertGreaterThan(radii.topLeading, 0)
        XCTAssertGreaterThan(radii.topTrailing, 0)
        XCTAssertGreaterThan(radii.bottomLeading, 0)
        XCTAssertGreaterThan(radii.bottomTrailing, 0)
    }

    // MARK: - FocusedSlideView.paragraphSizes

    func test_focusedParagraphSizes_currentIsLargeOthersSmall() {
        let paras = (0..<3).map {
            TeleprompterParagraph(
                id: $0, slideIndex: 0, title: nil, text: "t",
                isFirstInSlide: $0 == 0, isLastInSlide: $0 == 2
            )
        }
        let sizes = FocusedSlideView.paragraphSizes(
            slideParagraphs: paras, currentId: 1
        )
        XCTAssertEqual(sizes.count, 3)
        XCTAssertEqual(sizes[1], FocusedSlideView.currentParagraphSize)
        XCTAssertEqual(sizes[0], FocusedSlideView.nonCurrentParagraphSize)
        XCTAssertEqual(sizes[2], FocusedSlideView.nonCurrentParagraphSize)
    }

    func test_focusedParagraphSizes_noCurrent_allSmall() {
        let paras = (0..<2).map {
            TeleprompterParagraph(
                id: $0, slideIndex: 0, title: nil, text: "t",
                isFirstInSlide: $0 == 0, isLastInSlide: $0 == 1
            )
        }
        let sizes = FocusedSlideView.paragraphSizes(
            slideParagraphs: paras, currentId: 99
        )
        XCTAssertEqual(sizes, Array(repeating: FocusedSlideView.nonCurrentParagraphSize, count: 2))
    }
}
