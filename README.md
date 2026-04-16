# Presenter Notes

A focused macOS app for navigating your presentation notes live on stage.
Notes are written in plain Markdown, chunked by H2 headings, and you move
between chunks with a presentation remote, the arrow keys, or — if you
feel brave — your own voice.

The app has two modes in a single window:

- **Present** — a scrolling, highlight-current-chunk view designed for
  use on stage, with optional speech-driven auto-advance.
- **Edit** — a three-pane Markdown editor (outline · source · preview)
  that enforces the "slides format" and offers one-click fixes for any
  rule you break.

Built with SwiftUI, targets macOS 13 (Ventura) and later.

## Opening the project

1. Open `PresenterNotes.xcodeproj` in Xcode 15 or newer.
2. In the target's *Signing & Capabilities* tab, pick your team so the
   hardened runtime and sandbox entitlements get signed. The App Sandbox
   is already enabled with *Audio Input* and *User Selected File
   (Read/Write)* entitlements.
3. Product → Run (⌘R).

On first launch the app loads a built-in sample script so you can
immediately try the UI.

## The markdown format ("slides format")

Split your talk into chunks with H2 headings. Everything above the first
H2 becomes an untitled preamble.

```markdown
## Welcome

Thanks for joining today. I'm excited to walk you through what we've been
building over the last few months.

## The Problem

Presenters today juggle two different things on stage: their slides, and
their notes…

## Thank You

That's the whole pitch. I'd love to take questions now.
```

The format has five rules, enforced by `NotesValidator`:

1. Chunks are delimited by H2 headings (`## Title`).
2. No H1 — `# ` would confuse the parser. Auto-fix rewrites to `## `.
3. No H3 or deeper — use bold text for in-chunk emphasis. Auto-fix
   converts `### Sub` to `**Sub**`.
4. Every H2 needs a non-empty title. Auto-fix inserts `## Untitled`.
5. Every H2 chunk needs at least one line of body text. This one isn't
   auto-fixed — you have to write the body yourself.

A sample file lives at `sample-notes.md` in the repo root. Click
**Open Markdown…** to load your own.

## Present mode

The main view is a scrolling document. The chunk you're on is highlighted
with an accent border and larger type; earlier and later chunks fade back.
Every time you advance the view animates the new chunk to the top of the
window.

You can advance in three ways:

- **Keyboard / remote**: Right Arrow, Page Down, or Space move forward.
  Left Arrow, Page Up, or Delete move back. Most presentation clickers
  emit Page Up / Page Down or arrow keys, so they work with no setup.
- **On-screen controls**: the chevrons in the toolbar, or click any chunk
  in the view to jump to it.
- **Your voice**: toggle the **Listen** button and the app starts
  tracking the microphone with on-device speech recognition. When you
  speak the last few words of the current chunk, the app advances
  automatically.

While you talk, words you've already spoken in the current chunk are
highlighted in the body text in real time — so you can glance at the
notes and see exactly where the speech follower thinks you are. The
matcher is forgiving: each recognised word can skip up to three
still-unspoken words in the chunk, which means small paraphrases don't
derail the highlight. The highlight resets whenever you navigate to a
different chunk or edit the source.

The status bar at the bottom of the window shows whether speech is active
and what the recognizer most recently heard.

## Edit mode

Switch to edit mode from the toolbar segmented control, the menu
(**View → Edit Mode**), or the ⌘2 shortcut. Edit mode is a three-pane
split view:

- **Outline** — every parsed chunk, in order. Click a row to jump the
  preview to that chunk.
- **Editor** — a monospaced `TextEditor` bound to the raw markdown
  source. Edits re-parse and re-validate on every keystroke.
- **Preview** — a live, scrollable rendering of every chunk with the
  currently selected chunk highlighted, so you can see the Present-mode
  layout as you type.

Above the panes, the editor toolbar exposes **Open…**, **New**,
**New Chunk** (appends a fresh `## New Chunk` stub), a dirty indicator,
**Save**, and **Save As…**. Below the editor, a validation bar summarises
the errors and warnings in the current document. Each fixable issue has
its own per-row **Fix** button, and the **Fix All** button applies every
auto-fix in one click.

Save uses the real file URL when one is present (via
`startAccessingSecurityScopedResource`) and falls back to Save As — which
uses SwiftUI's `fileExporter` — for unsaved documents. The dirty flag is
derived from comparing the current source against the last-saved snapshot.

## How the speech follower works

For each chunk, the parser extracts the last six spoken words, lowercased
and stripped of punctuation — the *trailing signature*. As you talk,
`SpeechController` keeps a rolling window of the last ~40 recognised
words. When the trailing signature of the current chunk appears as a
contiguous subsequence near the end of that rolling window, the app
advances.

This approach is deliberately forgiving:

- You can paraphrase earlier parts of the chunk and still advance as long
  as you land on (or near) the written closing words.
- Advances are throttled to once per second so a noisy match can't
  double-advance.
- When you advance manually, the rolling window clears and the matcher
  starts waiting for the new chunk's trailing signature, so manual and
  voice navigation cooperate rather than fight.

If you want to change the matcher's aggressiveness, tweak these constants:

- `NotesDocument.trailingWordCount` — how many words form the signature.
  Smaller → easier to trigger; larger → more precise.
- `SpeechController.rollingWindow` — size of the transcript buffer.
- `SpeechController.minAdvanceInterval` — minimum delay between auto
  advances.

Speech recognition runs on-device (`requiresOnDeviceRecognition = true`),
so nothing is sent to Apple's servers during a talk.

## Keyboard shortcuts

| Shortcut          | Action                          |
|-------------------|---------------------------------|
| ⌘N                | New document                    |
| ⌘O                | Open markdown…                  |
| ⌘S                | Save                            |
| ⇧⌘S               | Save as…                        |
| ⌘1                | Switch to Present mode          |
| ⌘2                | Switch to Edit mode             |
| → / Page Down / Space  | Advance to next chunk      |
| ← / Page Up / Delete   | Previous chunk             |

## Project layout

```
PresenterNotes.xcodeproj/          Xcode project (two targets)
PresenterNotes/
  PresenterNotesApp.swift          @main entry point + Commands menu
  ContentView.swift                Shell + Present mode + ChunkView
  EditorView.swift                 Edit mode (outline + editor + preview)
  NotesDocument.swift              Markdown → [NoteChunk] parser
  NotesValidator.swift             Slides-format rules + auto-fixes
  NotesViewModel.swift             ObservableObject, nav + edit state
  MarkdownFileDocument.swift       FileDocument for fileExporter
  SpeechController.swift           SFSpeechRecognizer + trailing match
  KeyCaptureView.swift             Optional AppKit key-capture bridge
  Info.plist                       Usage descriptions + bundle info
  PresenterNotes.entitlements      Sandbox + mic + file read/write
  Assets.xcassets                  App icon slot
PresenterNotesTests/
  NotesDocumentTests.swift         Parser + trailingWords
  NotesValidatorTests.swift        Every rule + applyAllFixes
  NotesViewModelTests.swift        Loading, nav, dirty, save, fixes
  SpeechControllerTests.swift      Default state, hooks, wiring
  AppModeTests.swift               AppMode + MarkdownFileDocument
sample-notes.md                    Demo script
```

`KeyCaptureView.swift` is an alternate, lower-level way to catch key
events via an NSView. It isn't used by the default UI (which relies on
SwiftUI `keyboardShortcut` + the Commands menu) but it's there if you
want to extend the remote handling later.

## Tests

A full unit-test target ships with the project. Run with
**Product → Test (⌘U)** in Xcode, or from the command line:

```sh
xcodebuild -project PresenterNotes.xcodeproj \
           -scheme PresenterNotes \
           -destination 'platform=macOS' test
```

The test target covers:

- **Parser** — empty/whitespace input, single and multiple H2, preambles,
  H3 not starting a new chunk, trailing-hash title stripping, CRLF
  normalisation, `trailingWords` lowercasing/punctuation/length, the
  body-token splitter used for highlight alignment.
- **Validator** — clean sample passes, H1/H3/H4 flagged with correct
  depth in the message, empty titles flagged as errors, empty bodies as
  warnings with no fix, no-H2 error with skeleton insertion, auto-fixes
  are idempotent on clean docs and isolated to the intended line.
- **View model** — loading from text/disk/sample/new, navigation clamping
  at bounds and on shrinking edits, dirty tracking, save-to-disk happy
  path, `SaveError.noURL` when saving without a URL, `didSaveAs` wiring,
  `applyAllFixes` and per-issue `apply`, mode switching.
- **Speech controller** — default idle state, callback wiring to
  `NotesViewModel.next`, trailing-words provider reads from view model,
  `stop()` idempotence, transcript-delta detection (only new words are
  forwarded to the highlighter, and a shrinking transcript is treated as
  a recognizer session restart).
- **App mode + FileDocument** — enum labels/symbols/ids and
  `MarkdownFileDocument` text storage + content type registration.

## Previews

Every view in the app has a `PreviewProvider` so you can iterate in
Xcode's canvas without running the full app:

- `ContentView_Previews` — full shell in both Present and Edit mode.
- `ModeBar_Previews`, `PresentView_Previews`, `ChunkView_Previews` —
  individual pieces of the Present-mode layout.
- `EditorView_Previews` — the three-pane editor, populated with the
  sample script.
- `OutlinePane_Previews`, `EditorPane_Previews`, `PreviewPane_Previews`,
  `ValidationBar_Previews`, `IssueRow_Previews` — each editor subview
  in isolation, including an "empty" and a "with issues" variant for
  the validation bar.
- `KeyCaptureView_Previews` — placeholder that shows the responder bridge.

## Bundle identifier

The project ships with `com.example.PresenterNotes`. Change it in the
target's build settings before shipping.

## Known limitations

- The markdown renderer is intentionally dumb — it treats the body of
  each chunk as plain text so line breaks survive. If you want real
  inline formatting, render each chunk's body through
  `AttributedString(markdown:)`.
- Speech matching is tuned for English. For other languages, change the
  locale in `SpeechController.init` and make sure on-device recognition
  is supported for that locale.
- Empty AppIcon — Xcode will warn on build. Drop your own icon PNGs into
  `Assets.xcassets/AppIcon.appiconset/` to silence it.
