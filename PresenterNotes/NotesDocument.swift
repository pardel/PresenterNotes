//
//  NotesDocument.swift
//  PresenterNotes
//
//  Parses a markdown file into ordered "slides" where each slide is
//  delimited by an H2 heading (`## ...`). Anything that appears before
//  the first H2 becomes an untitled preamble slide.
//

import Foundation

/// A single navigable block of presenter notes.
struct NoteSlide: Identifiable, Equatable {
    let id: Int
    /// Title from the `## ...` heading. `nil` for the preamble.
    let title: String?
    /// Body text with heading stripped. Blank lines preserved.
    let body: String

    /// The last N words of the slide, lowercased and punctuation-stripped.
    /// Used for "trailing-words" speech matching.
    let trailingWords: [String]

    /// Full plain-text representation (title + body) used for search/display.
    var plainText: String {
        if let title = title, !title.isEmpty {
            return title + "\n" + body
        }
        return body
    }
}

/// A single paragraph for the teleprompter view. Each slide's body is
/// split on blank lines (`\n\n`) into paragraphs. The slide's title is
/// attached to its first paragraph only — titles don't count as separate
/// paragraphs.
struct TeleprompterParagraph: Identifiable, Equatable {
    let id: Int
    let slideIndex: Int
    let title: String?
    let text: String
    let isFirstInSlide: Bool
    let isLastInSlide: Bool
}

enum NotesDocument {

    /// How many trailing words we extract per slide for speech matching.
    static let trailingWordCount = 6

    /// Parse a markdown string into an ordered list of slides.
    static func parse(_ markdown: String) -> [NoteSlide] {
        // Normalize line endings.
        let normalized = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")

        var slides: [NoteSlide] = []
        var currentTitle: String? = nil
        var currentBody: [String] = []

        func flush() {
            let body = currentBody
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip completely empty preamble.
            if currentTitle == nil && body.isEmpty { return }
            let slide = NoteSlide(
                id: slides.count,
                title: currentTitle,
                body: body,
                trailingWords: Self.trailingWords(from: body, count: trailingWordCount)
            )
            slides.append(slide)
        }

        for line in lines {
            if let heading = Self.h2Title(in: line) {
                flush()
                currentTitle = heading
                currentBody = []
            } else {
                currentBody.append(line)
            }
        }
        flush()

        return slides
    }

    /// Single source of truth for "is this line an H2 heading, and if so
    /// what's the cleaned title?". Used by the parser, the validator,
    /// and the editor's slide-index math. Callers that only need a bool
    /// check write `h2Title(in: line) != nil`.
    ///
    /// Matches `## Title` but not `### Sub` (H3+) and not `#Title`
    /// (no space). The returned title is whitespace-trimmed and has any
    /// trailing `##` decoration stripped — so `"## Hello ##"` returns
    /// `"Hello"`. A bare `"##"` or `"## "` (which trims to `"##"`)
    /// returns nil; the validator catches those explicitly as the
    /// "empty slide title" error case.
    static func h2Title(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("## ") else { return nil }
        var title = String(trimmed.dropFirst(3))
        while title.hasSuffix("#") { title = String(title.dropLast()) }
        return title.trimmingCharacters(in: .whitespaces)
    }

    /// Extract the last `count` spoken words from the body, lowercased
    /// and stripped of punctuation. Uses `bodyMatchTokens` so the needle
    /// produced here tokenises the same way the speech-side rolling
    /// window does — a contraction like "don't" becomes one token
    /// ("dont"), not two ("don", "t").
    static func trailingWords(from body: String, count: Int) -> [String] {
        let tokens = bodyMatchTokens(in: body).filter { !$0.isEmpty }
        return Array(tokens.suffix(count))
    }

    /// Normalise a single spoken/written word for matching: lowercase,
    /// strip everything that isn't a letter or digit.
    static func normaliseMatchWord(_ word: String) -> String {
        word.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    /// Split a body into whitespace-separated tokens and return the
    /// normalised form of each.
    ///
    /// The Nth entry corresponds 1:1 with the Nth whitespace-separated
    /// token in `body`, so the same N can be used as a "how many words
    /// have been spoken" progress pointer for highlighting the body in
    /// the UI. Tokens that normalise to an empty string (punctuation-only
    /// fragments like "—") are preserved at their index so alignment is
    /// stable; the matcher will skip them.
    static func bodyMatchTokens(in body: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for ch in body {
            if ch.isWhitespace {
                if !current.isEmpty {
                    tokens.append(normaliseMatchWord(current))
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            tokens.append(normaliseMatchWord(current))
        }
        return tokens
    }

    /// Split an array of slides into a flat list of teleprompter paragraphs.
    /// Each slide's body is split on blank lines (`\n\n`). The slide's title
    /// is attached to the first paragraph only.
    static func paragraphs(from slides: [NoteSlide]) -> [TeleprompterParagraph] {
        var result: [TeleprompterParagraph] = []
        for slide in slides {
            let parts = slide.body
                .components(separatedBy: "\n\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if parts.isEmpty {
                result.append(TeleprompterParagraph(
                    id: result.count,
                    slideIndex: slide.id,
                    title: slide.title,
                    text: "",
                    isFirstInSlide: true,
                    isLastInSlide: true
                ))
            } else {
                for (i, text) in parts.enumerated() {
                    result.append(TeleprompterParagraph(
                        id: result.count,
                        slideIndex: slide.id,
                        title: i == 0 ? slide.title : nil,
                        text: text,
                        isFirstInSlide: i == 0,
                        isLastInSlide: i == parts.count - 1
                    ))
                }
            }
        }
        return result
    }
}
