//
//  NotesValidator.swift
//  PresenterNotes
//
//  Rules that enforce the "slides format" for presenter notes:
//    1. Slides are delimited by H2 headings (`## Title`).
//    2. H1 (`# `) is not used — it would confuse the parser.
//    3. H3+ (`### `, `#### `) is not used for structural headings;
//       if you need emphasis inside a slide, use bold text.
//    4. Every H2 needs a non-empty title.
//    5. Every H2 slide needs at least one line of body text.
//
//  Each `ValidationIssue` exposes an optional `fix` closure that
//  rewrites the source to repair that specific issue. The UI wires
//  these up to one-click Fix buttons.
//

import Foundation

struct ValidationIssue: Identifiable, Equatable {
    enum Severity: Equatable { case warning, error }

    let id = UUID()
    let severity: Severity
    let message: String
    /// 1-based inclusive line range in the source.
    let lineRange: ClosedRange<Int>
    /// A closure that, given the current source, returns the fixed source.
    /// Nil when the issue must be fixed by hand.
    let fix: ((String) -> String)?

    static func == (lhs: ValidationIssue, rhs: ValidationIssue) -> Bool {
        lhs.id == rhs.id
    }
}

enum NotesValidator {

    /// Validate a markdown source and return every rule violation we find.
    static func validate(_ source: String) -> [ValidationIssue] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var issues: [ValidationIssue] = []

        // Helper: rewrite a single line in the source.
        func replacingLine(_ idx: Int, with replacement: String) -> (String) -> String {
            return { src in
                var ls = src.replacingOccurrences(of: "\r\n", with: "\n")
                    .components(separatedBy: "\n")
                guard ls.indices.contains(idx) else { return src }
                ls[idx] = replacement
                return ls.joined(separator: "\n")
            }
        }

        // Helper: remove a single line.
        func removingLine(_ idx: Int) -> (String) -> String {
            return { src in
                var ls = src.replacingOccurrences(of: "\r\n", with: "\n")
                    .components(separatedBy: "\n")
                guard ls.indices.contains(idx) else { return src }
                ls.remove(at: idx)
                return ls.joined(separator: "\n")
            }
        }

        // --- Pass 1: per-line heading checks ------------------------------

        for (idx, rawLine) in lines.enumerated() {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // H1 — convert to H2.
            if trimmed.hasPrefix("# ") && !trimmed.hasPrefix("## ") {
                let title = String(trimmed.dropFirst(2))
                    .trimmingCharacters(in: .whitespaces)
                issues.append(ValidationIssue(
                    severity: .warning,
                    message: "H1 heading on line \(idx + 1) — only H2 is allowed for slide titles.",
                    lineRange: (idx + 1)...(idx + 1),
                    fix: replacingLine(idx, with: "## \(title)")
                ))
                continue
            }

            // H3+ — convert to bold text so content survives.
            // Count leading hashes first so `#### Deeper` etc. are caught too.
            do {
                var hashes = 0
                for ch in trimmed {
                    if ch == "#" { hashes += 1 } else { break }
                }
                if hashes >= 3 {
                    let afterHashes = trimmed.dropFirst(hashes)
                    if afterHashes.first == " " {
                        let rest = afterHashes.drop(while: { $0 == " " })
                        let bold = "**\(String(rest))**"
                        issues.append(ValidationIssue(
                            severity: .warning,
                            message: "H\(hashes) heading on line \(idx + 1) — use bold text inside a slide instead of deeper headings.",
                            lineRange: (idx + 1)...(idx + 1),
                            fix: replacingLine(idx, with: bold)
                        ))
                        continue
                    }
                }
            }

            // H2 with empty title.
            if trimmed == "##" || trimmed == "## " {
                issues.append(ValidationIssue(
                    severity: .error,
                    message: "Empty slide title on line \(idx + 1).",
                    lineRange: (idx + 1)...(idx + 1),
                    fix: replacingLine(idx, with: "## Untitled")
                ))
                continue
            }
            // `## ` followed by only whitespace after stripping trailing hashes.
            if let title = NotesDocument.h2Title(in: rawLine), title.isEmpty {
                issues.append(ValidationIssue(
                    severity: .error,
                    message: "Empty slide title on line \(idx + 1).",
                    lineRange: (idx + 1)...(idx + 1),
                    fix: replacingLine(idx, with: "## Untitled")
                ))
            }
        }

        // --- Pass 2: structural checks on the parsed slides ---------------

        // Walk the lines and find each H2's line number + body presence.
        struct SlideMeta {
            let titleLine: Int    // 0-based source line
            let title: String
            var bodyLines: [String]
        }
        var metas: [SlideMeta] = []
        var currentMeta: SlideMeta? = nil
        for (idx, rawLine) in lines.enumerated() {
            if let title = NotesDocument.h2Title(in: rawLine) {
                if let m = currentMeta { metas.append(m) }
                currentMeta = SlideMeta(
                    titleLine: idx,
                    title: title,
                    bodyLines: []
                )
            } else {
                currentMeta?.bodyLines.append(rawLine)
            }
        }
        if let m = currentMeta { metas.append(m) }

        for meta in metas {
            let bodyText = meta.bodyLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if bodyText.isEmpty {
                issues.append(ValidationIssue(
                    severity: .warning,
                    message: "Slide \"\(meta.title.isEmpty ? "Untitled" : meta.title)\" on line \(meta.titleLine + 1) has no body.",
                    lineRange: (meta.titleLine + 1)...(meta.titleLine + 1),
                    // No safe auto-fix — removing would destroy the heading,
                    // inserting placeholder text would be presumptuous.
                    fix: nil
                ))
            }
        }

        // --- Pass 3: whole-document check ---------------------------------

        // Does the document have *any* H2 at all? If the user has an H1 in
        // the file we don't pile on — they'll see the H1 warning and the
        // one-click fix will upgrade it to H2.
        let hasH1 = lines.contains { raw in
            let t = raw.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("# ") && !t.hasPrefix("## ")
        }
        if metas.isEmpty && !hasH1 {
            issues.append(ValidationIssue(
                severity: .error,
                message: "No H2 slides found — the slides format requires at least one `## Heading`.",
                lineRange: 1...1,
                fix: { src in
                    if src.isEmpty {
                        return "## Untitled\n\nYour first slide.\n"
                    }
                    return "## Untitled\n\n" + src
                }
            ))
        }

        return issues
    }

    /// Convenience: apply every issue with a non-nil fix, in order.
    /// Used by the "Fix all" button.
    static func applyAllFixes(_ source: String) -> String {
        var current = source
        // Re-validate after each fix so line numbers stay correct.
        while true {
            let issues = validate(current)
            guard let next = issues.first(where: { $0.fix != nil }),
                  let fix = next.fix else { break }
            let updated = fix(current)
            if updated == current { break } // safety: no progress
            current = updated
        }
        return current
    }
}
