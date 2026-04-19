# PresenterNotes — Claude guide

A macOS SwiftUI app that displays Markdown-based presenter notes one slide at a time, with optional speech-driven auto-advance.

## Build & run

```bash
xcodebuild -project PresenterNotes.xcodeproj -scheme PresenterNotes -destination 'platform=macOS' build
```

Open `PresenterNotes.xcodeproj` in Xcode to run the app or the SwiftUI previews.

## Architecture at a glance

- `PresenterNotesApp.swift` — app entry point, key command menu.
- `NotesViewModel.swift` — single source of truth. Owns `sourceText`, parses it into `slides`, tracks `currentIndex` + `spokenWordCount`, and exposes navigation methods (`next`, `previous`, `jump`). All UI mutations go through it on the main thread.
- `NotesDocument.swift` — pure parser. `NotesDocument.parse(_:)` turns Markdown into `[NoteSlide]`; `bodyMatchTokens(in:)` and `normaliseMatchWord(_:)` define the tokenisation used for speech matching.
- `NotesValidator.swift` — surfaces validation issues (and fixes) for the edit view.
- `SpeechController.swift` — wraps `SFSpeechRecognizer` + `AVAudioEngine`. Keeps a rolling window of recognised words, calls `onWordsRecognised` with the delta of new words, and fires `onAdvanceDetected` when the trailing words of the current slide appear in order.
- `ContentView.swift` — the window shell, `PresentView` (full-screen single-slide display), and `EditorView` wiring.
- `EditorView.swift` — the markdown editing mode with validation.

### Data flow

```
sourceText (markdown)
   │  NotesDocument.parse
   ▼
slides: [NoteSlide]          ──────────────► PresentView renders current slide full-screen
   │
   │  currentIndex, spokenWordCount
   ▼
SlideView / FullScreenSlideView
   ▲
   │  onWordsRecognised delta
   │
SpeechController (mic → SFSpeechRecognizer → rolling words)
```

### Speech matching

- `SpeechController.updateRolling(with:)` is the testable entry point; tests can drive it directly without audio.
- `onWordsRecognised` is the delta since the previous callback — the view model uses it to advance `spokenWordCount` through the current slide's body tokens with a `maxSkip` of 3 so presenters can paraphrase a word or two and stay on track.
- `checkForAdvance()` looks for the slide's trailing-word signature as a contiguous subsequence in the tail of the rolling window. Minimum 1.0s between fires.
- Recognised word batches are printed to the console as `[Speech] heard: …` for debugging.

## Conventions

- **Main-thread mutation**: everything mutable on `NotesViewModel` and `SpeechController` is expected to be touched on the main queue. The speech task callbacks explicitly `DispatchQueue.main.async` before calling back into the view model.
- **Parsing is pure**: `NotesDocument` has no state and no references to the view model. Keep it that way — it's what makes the parser trivially testable.
- **Tokenisation lives in one place**: `NotesDocument.bodyMatchTokens` is the canonical tokeniser. `SlideView.highlightedBody` and `NotesViewModel.observeRecognisedWords` must stay aligned with it — if you change one, change them all together.
- **No mocks for speech logic**: tests drive `SpeechController.updateRolling(with:)` directly with strings rather than mocking `SFSpeechRecognizer`.

## Present view sizing

`PresentView` shows exactly one slide at a time using `FullScreenSlideView`, which takes the available size from a `GeometryReader` and picks a body font size via `FullScreenSlideView.bodyFontSize(for:in:)`. The title size is derived as `0.55 *` the body size. `minimumScaleFactor(0.3)` is the safety net for very long slides — it should not be the primary sizing mechanism.

If you touch sizing, remember the two failure modes:
- Short slides with too-small a font look lost on a projector.
- Long slides with too-large a font either clip or rely entirely on `minimumScaleFactor` and end up tiny anyway.
