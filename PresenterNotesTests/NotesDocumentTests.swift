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

    func test_h2Title_preservesTrailingHashAttachedToTitle() {
        // Regression: greedy trailing-`#` stripping used to turn
        // legitimate titles like "C#" / "F#" / "Hello#" into "C" / "F"
        // / "Hello". Per CommonMark, the optional closing `#` sequence
        // must be preceded by whitespace; otherwise the `#` is part of
        // the title.
        XCTAssertEqual(NotesDocument.h2Title(in: "## C#"), "C#")
        XCTAssertEqual(NotesDocument.h2Title(in: "## F#"), "F#")
        XCTAssertEqual(NotesDocument.h2Title(in: "## Hello#"), "Hello#")
        XCTAssertEqual(NotesDocument.h2Title(in: "## A## Hashtag"), "A## Hashtag")
    }

    func test_h2Title_handlesHashOnlyContentAsLiteralTitle() {
        // "## ####" — the four `#`s sit immediately after the leading
        // `## ` with no space before them, so they're title content,
        // not a closing sequence. Matches CommonMark; the old behaviour
        // (strip everything, return "") over-matched.
        XCTAssertEqual(NotesDocument.h2Title(in: "## ####"), "####")
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

    // MARK: - paragraphs(from:)

    func test_paragraphs_emptySlides_returnsEmpty() {
        XCTAssertTrue(NotesDocument.paragraphs(from: []).isEmpty)
    }

    func test_paragraphs_singleSlide_singleParagraph() {
        let slides = NotesDocument.parse("## Title\n\nJust one paragraph.")
        let paras = NotesDocument.paragraphs(from: slides)
        XCTAssertEqual(paras.count, 1)
        XCTAssertEqual(paras[0].text, "Just one paragraph.")
        XCTAssertEqual(paras[0].title, "Title")
        XCTAssertTrue(paras[0].isFirstInSlide)
        XCTAssertTrue(paras[0].isLastInSlide)
    }

    func test_paragraphs_splitOnBlankLines() {
        let slides = NotesDocument.parse("## T\n\nFirst paragraph.\n\nSecond paragraph.\n\nThird.")
        let paras = NotesDocument.paragraphs(from: slides)
        XCTAssertEqual(paras.map { $0.text },
                       ["First paragraph.", "Second paragraph.", "Third."])
    }

    func test_paragraphs_titleAttachedToFirstParagraphOnly() {
        let slides = NotesDocument.parse("## Welcome\n\nFirst.\n\nSecond.\n\nThird.")
        let paras = NotesDocument.paragraphs(from: slides)
        XCTAssertEqual(paras[0].title, "Welcome")
        XCTAssertNil(paras[1].title)
        XCTAssertNil(paras[2].title)
    }

    func test_paragraphs_isFirstIsLastFlags() {
        let slides = NotesDocument.parse("## T\n\nA.\n\nB.\n\nC.")
        let paras = NotesDocument.paragraphs(from: slides)
        XCTAssertEqual(paras.count, 3)
        XCTAssertEqual(paras.map { $0.isFirstInSlide }, [true, false, false])
        XCTAssertEqual(paras.map { $0.isLastInSlide }, [false, false, true])
    }

    func test_paragraphs_sequentialIdsAcrossSlides() {
        let source = """
        ## One

        A.

        B.

        ## Two

        C.
        """
        let paras = NotesDocument.paragraphs(from: NotesDocument.parse(source))
        XCTAssertEqual(paras.map { $0.id }, [0, 1, 2])
        XCTAssertEqual(paras.map { $0.slideIndex }, [0, 0, 1])
    }

    func test_paragraphs_slideBoundariesHaveCorrectFlags() {
        // Slide 1: two paragraphs (A first+!last, B !first+last)
        // Slide 2: one paragraph (C first+last — single-paragraph slide)
        let source = """
        ## One

        A.

        B.

        ## Two

        C.
        """
        let paras = NotesDocument.paragraphs(from: NotesDocument.parse(source))
        XCTAssertEqual(paras.map { $0.isFirstInSlide }, [true, false, true])
        XCTAssertEqual(paras.map { $0.isLastInSlide },  [false, true, true])
    }

    func test_paragraphs_preambleSlidePreservesNilTitle() {
        let slides = NotesDocument.parse("Intro text before any heading.\n\n## First\n\nBody.")
        let paras = NotesDocument.paragraphs(from: slides)
        XCTAssertEqual(paras.count, 2)
        XCTAssertNil(paras[0].title)                  // preamble has no title
        XCTAssertEqual(paras[0].text, "Intro text before any heading.")
        XCTAssertEqual(paras[1].title, "First")
    }

    func test_paragraphs_emptyBodySlide_placeholderParagraph() {
        // A slide whose body is empty gets one placeholder paragraph
        // so navigation / rendering doesn't have to special-case zero.
        let slide = NoteSlide(id: 0, title: "Empty", body: "", trailingWords: [])
        let paras = NotesDocument.paragraphs(from: [slide])
        XCTAssertEqual(paras.count, 1)
        XCTAssertEqual(paras[0].text, "")
        XCTAssertEqual(paras[0].title, "Empty")
        XCTAssertTrue(paras[0].isFirstInSlide)
        XCTAssertTrue(paras[0].isLastInSlide)
    }

    func test_paragraphs_consecutiveBlankLinesDoNotYieldEmptyParagraphs() {
        // Extra blank lines between paragraphs split into more "" chunks
        // that must be filtered, not rendered as empty paragraphs.
        let slides = NotesDocument.parse("## T\n\nA.\n\n\n\n\n\nB.")
        let paras = NotesDocument.paragraphs(from: slides)
        XCTAssertEqual(paras.map { $0.text }, ["A.", "B."])
    }

    func test_paragraphs_trimsParagraphWhitespace() {
        let slides = NotesDocument.parse("## T\n\n   A with leading space.   \n\n\tB with tab.")
        let paras = NotesDocument.paragraphs(from: slides)
        XCTAssertEqual(paras.map { $0.text },
                       ["A with leading space.", "B with tab."])
    }
}
