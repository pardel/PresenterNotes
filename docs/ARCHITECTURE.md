# PresenterNotes architecture

This is the contributor-facing architecture overview. Read this before filing a non-trivial PR.

## High-level

PresenterNotes is a single-window macOS SwiftUI app with two modes — **Present** (read-only display, optional speech-driven advance) and **Edit** (three-pane markdown editor with live validation). State is centralised in one `ObservableObject`; markdown parsing is a pure function; speech matching is a small algorithm tested without mocks.

## Modules

- **`PresenterNotesApp.swift`** — `@main`, the window scene, the Commands menu wiring keyboard shortcuts to view-model actions.
- **`NotesViewModel.swift`** — single source of truth. Owns `sourceText`, parses it into `slides`, tracks `currentIndex` and `spokenWordCount`, exposes `next` / `previous` / `jump`. All UI mutation flows through this object on the main thread.
- **`NotesDocument.swift`** — pure parser. `parse(_:)` turns markdown into `[NoteSlide]`. `bodyMatchTokens(in:)` and `normaliseMatchWord(_:)` define the canonical tokenisation used by the speech matcher.
- **`NotesValidator.swift`** — slides-format rule engine. Produces `[Issue]` with optional auto-fix closures.
- **`SpeechController.swift`** — `SFSpeechRecognizer` + `AVAudioEngine` wrapper. Maintains a rolling window of recognised words. Two callbacks: `onWordsRecognised` (delta) and `onAdvanceDetected` (when the trailing signature appears in the tail of the rolling window).
- **`ContentView.swift` / `EditorView.swift`** — the two view trees.
- **`KeyCaptureView.swift`** — `NSViewRepresentable` for low-level key event capture. Currently unused by the default UI; kept for extension.

## Data flow

```
sourceText (markdown)
   │  NotesDocument.parse
   ▼
slides: [NoteSlide]              ──────────► PresentView renders current slide
   │
   │  currentIndex, spokenWordCount
   ▼
SlideView / FullScreenSlideView
   ▲
   │  onWordsRecognised delta
   │
SpeechController (mic → SFSpeechRecognizer → rolling words)
```

## Speech matching algorithm

For each chunk the parser extracts the last N spoken words (lowercased, punctuation-stripped) — the *trailing signature*. As the recogniser emits transcripts, `SpeechController` keeps a rolling window of the last ~40 recognised words. `checkForAdvance()` looks for the trailing signature as a contiguous subsequence in the tail of the rolling window.

Forgiving traits:

- The view model advances `spokenWordCount` through the body tokens with a `maxSkip` of 3, so paraphrasing one or two words does not break the highlight.
- Advances are throttled to once per second (`minAdvanceInterval`).
- Manual navigation clears the rolling window so manual and voice cooperate rather than fight.

Tunable constants worth knowing about:

- `NotesDocument.trailingWordCount` — signature length.
- `SpeechController.rollingWindow` — buffer size.
- `SpeechController.minAdvanceInterval` — minimum delay between auto advances.

## Conventions

- **Main-thread mutation.** `NotesViewModel` and `SpeechController` must be touched on the main queue. Speech callbacks dispatch to main explicitly.
- **Parsing is pure.** `NotesDocument` has no state and no view-model references. This is what makes it trivially testable.
- **One canonical tokeniser.** `NotesDocument.bodyMatchTokens` is the single source of tokenisation truth. `SlideView.highlightedBody` and `NotesViewModel.observeRecognisedWords` must stay aligned with it — change one, change all three.
- **No mocks for speech logic.** Tests drive `SpeechController.updateRolling(with:)` directly with strings.

## Test layout

- `NotesDocumentTests.swift` — parser, tokenisation, trailing words.
- `NotesValidatorTests.swift` — every rule, idempotent fixes.
- `NotesViewModelTests.swift` — loading, navigation, dirty tracking, save, fixes, mode switching.
- `SpeechControllerTests.swift` — idle state, callbacks, transcript delta detection, restart handling.
- `AppModeTests.swift` — enum + `MarkdownFileDocument`.
