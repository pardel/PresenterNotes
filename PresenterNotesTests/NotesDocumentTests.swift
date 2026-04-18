//
//  NotesDocumentTests.swift
//  PresenterNotesTests
//

import XCTest
@testable import PresenterNotes

final class NotesDocumentTests: XCTestCase {

    // MARK: - parse

    func test_parse_emptyString_returnsNoSlides() {
        XCTAssertTrue(NotesDocument.parse("").isEmpty)
    }

    func test_parse_whitespaceOnly_returnsNoSlides() {
        XCTAssertTrue(NotesDocument.parse("   \n\n  \n").isEmpty)
    }

    func test_parse_singleH2_oneSlide() {
        let source = "## Hello\n\nThis is the body."
        let slides = NotesDocument.parse(source)
        XCTAssertEqual(slides.count, 1)
        XCTAssertEqual(slides[0].title, "Hello")
        XCTAssertEqual(slides[0].body, "This is the body.")
        XCTAssertEqual(slides[0].id, 0)
    }

    func test_parse_multipleH2_preservesOrderAndIDs() {
        let source = """
        ## One

        Body one.

        ## Two

        Body two.

        ## Three

        Body three.
        """
        let slides = NotesDocument.parse(source)
        XCTAssertEqual(slides.map { $0.title }, ["One", "Two", "Three"])
        XCTAssertEqual(slides.map { $0.id }, [0, 1, 2])
        XCTAssertEqual(slides.map { $0.body }, ["Body one.", "Body two.", "Body three."])
    }

    func test_parse_preamble_beforeFirstH2_becomesUntitledSlide() {
        let source = """
        Some intro text.

        ## First

        Body.
        """
        let slides = NotesDocument.parse(source)
        XCTAssertEqual(slides.count, 2)
        XCTAssertNil(slides[0].title)
        XCTAssertEqual(slides[0].body, "Some intro text.")
        XCTAssertEqual(slides[1].title, "First")
    }

    func test_parse_H3_doesNotStartNewSlide() {
        let source = """
        ## Slide

        ### Sub heading

        Body.
        """
        let slides = NotesDocument.parse(source)
        XCTAssertEqual(slides.count, 1)
        XCTAssertEqual(slides[0].title, "Slide")
        XCTAssertTrue(slides[0].body.contains("### Sub heading"))
    }

    func test_parse_trimsTrailingHashesFromTitle() {
        let source = "## Title ##\n\nBody."
        let slides = NotesDocument.parse(source)
        XCTAssertEqual(slides.count, 1)
        XCTAssertEqual(slides[0].title, "Title")
    }

    func test_parse_normalizesCRLF() {
        let source = "## Title\r\n\r\nBody."
        let slides = NotesDocument.parse(source)
        XCTAssertEqual(slides.count, 1)
        XCTAssertEqual(slides[0].title, "Title")
        XCTAssertEqual(slides[0].body, "Body.")
    }

    // MARK: - trailingWords

    func test_trailingWords_lowercasesAndStripsPunctuation() {
        let words = NotesDocument.trailingWords(
            from: "Hello, world! This is *bold* text.",
            count: 6
        )
        XCTAssertEqual(words, ["hello", "world", "this", "is", "bold", "text"])
    }

    func test_trailingWords_returnsLastNWords() {
        let body = "one two three four five six seven eight"
        XCTAssertEqual(
            NotesDocument.trailingWords(from: body, count: 3),
            ["six", "seven", "eight"]
        )
    }

    func test_trailingWords_fewerWordsThanCount_returnsAll() {
        let words = NotesDocument.trailingWords(from: "only three words here", count: 10)
        XCTAssertEqual(words, ["only", "three", "words", "here"])
    }

    func test_trailingWords_emptyBody_returnsEmpty() {
        XCTAssertTrue(NotesDocument.trailingWords(from: "", count: 6).isEmpty)
        XCTAssertTrue(NotesDocument.trailingWords(from: "   ", count: 6).isEmpty)
    }

    func test_trailingWords_usedByParse_endToEnd() {
        let source = "## Welcome\n\nThanks for joining us today!"
        let slides = NotesDocument.parse(source)
        XCTAssertEqual(
            slides[0].trailingWords,
            ["thanks", "for", "joining", "us", "today"]
        )
    }

    // MARK: - bodyMatchTokens / normaliseMatchWord

    func test_normaliseMatchWord_lowercasesAndStrips() {
        XCTAssertEqual(NotesDocument.normaliseMatchWord("Hello,"), "hello")
        XCTAssertEqual(NotesDocument.normaliseMatchWord("don't"), "dont")
        XCTAssertEqual(NotesDocument.normaliseMatchWord("—"), "")
        XCTAssertEqual(NotesDocument.normaliseMatchWord(""), "")
    }

    func test_bodyMatchTokens_splitsByWhitespace() {
        XCTAssertEqual(
            NotesDocument.bodyMatchTokens(in: "Hello, world! This is fine."),
            ["hello", "world", "this", "is", "fine"]
        )
    }

    func test_bodyMatchTokens_preservesIndexForPunctuationTokens() {
        // Each whitespace-separated piece becomes one token, even if it
        // normalises to empty; this keeps the index aligned with the
        // view's whitespace splitting for highlighting.
        let body = "— alpha beta"
        let tokens = NotesDocument.bodyMatchTokens(in: body)
        XCTAssertEqual(tokens, ["", "alpha", "beta"])
    }

    func test_bodyMatchTokens_handlesNewlinesAndTabs() {
        let body = "one\ttwo\nthree   four"
        XCTAssertEqual(
            NotesDocument.bodyMatchTokens(in: body),
            ["one", "two", "three", "four"]
        )
    }

    func test_bodyMatchTokens_emptyBodyIsEmpty() {
        XCTAssertTrue(NotesDocument.bodyMatchTokens(in: "").isEmpty)
        XCTAssertTrue(NotesDocument.bodyMatchTokens(in: "   \n  ").isEmpty)
    }

    // MARK: - h2Title

    func test_h2Title_returnsTitleForSimpleH2() {
        XCTAssertEqual(NotesDocument.h2Title(in: "## Hello"), "Hello")
    }

    func test_h2Title_stripsTrailingDecoration() {
        XCTAssertEqual(NotesDocument.h2Title(in: "## Hello ##"), "Hello")
        XCTAssertEqual(NotesDocument.h2Title(in: "## Hello #"), "Hello")
        XCTAssertEqual(NotesDocument.h2Title(in: "## Hello ####"), "Hello")
    }

    func test_h2Title_trimsLeadingWhitespace() {
        XCTAssertEqual(NotesDocument.h2Title(in: "   ## Indented"), "Indented")
        XCTAssertEqual(NotesDocument.h2Title(in: "\t## Tabbed"), "Tabbed")
    }

    func test_h2Title_rejectsH1AndDeeperHeadings() {
        XCTAssertNil(NotesDocument.h2Title(in: "# Title"))
        XCTAssertNil(NotesDocument.h2Title(in: "### Sub"))
        XCTAssertNil(NotesDocument.h2Title(in: "#### Deeper"))
        XCTAssertNil(NotesDocument.h2Title(in: "##### Deepest"))
    }

    func test_h2Title_rejectsMissingSpaceAfterHashes() {
        XCTAssertNil(NotesDocument.h2Title(in: "##Hello"))
        XCTAssertNil(NotesDocument.h2Title(in: "#Hello"))
    }

    func test_h2Title_rejectsBareHashes() {
        // Both `"##"` and `"## "` trim to `"##"`, which lacks the
        // required `"## "` (hash-hash-space) prefix. The validator
        // catches these as the empty-title error case.
        XCTAssertNil(NotesDocument.h2Title(in: "##"))
        XCTAssertNil(NotesDocument.h2Title(in: "## "))
        XCTAssertNil(NotesDocument.h2Title(in: "  ##  "))
    }

    func test_h2Title_returnsEmptyForHashOnlyDecoration() {
        // `"## ####"` passes the prefix check (there's a real space
        // after the two hashes), then the trailing-hash stripper eats
        // all the # characters, leaving an empty title.
        XCTAssertEqual(NotesDocument.h2Title(in: "## ####"), "")
    }

    func test_h2Title_preservesInnerPunctuation() {
        XCTAssertEqual(
            NotesDocument.h2Title(in: "## Hello, World!"),
            "Hello, World!"
        )
    }

    func test_h2Title_rejectsEmptyAndWhitespace() {
        XCTAssertNil(NotesDocument.h2Title(in: ""))
        XCTAssertNil(NotesDocument.h2Title(in: "   "))
        XCTAssertNil(NotesDocument.h2Title(in: "\n"))
    }
}
