# Contributing to PresenterNotes

Thanks for your interest. PresenterNotes is a small, focused macOS app and PRs are welcome — especially small ones.

## Build & test

Open `PresenterNotes.xcodeproj` in Xcode 15 or newer. From the command line:

```bash
xcodebuild -project PresenterNotes.xcodeproj \
           -scheme PresenterNotes \
           -destination 'platform=macOS' test
```

CI runs the same command on macOS 14 and macOS 15.

## Project layout

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the data-flow diagram and module overview. Quick orientation:

- `NotesViewModel.swift` — single source of truth.
- `NotesDocument.swift` — pure markdown parser.
- `SpeechController.swift` — `SFSpeechRecognizer` wrapper + matching.
- `ContentView.swift` / `EditorView.swift` — the two modes.

## Conventions

- **Main-thread mutation.** Anything mutable on `NotesViewModel` and `SpeechController` must be touched on the main queue.
- **Parsing is pure.** `NotesDocument` has no state and no view-model references. Keep it that way.
- **One canonical tokeniser.** `NotesDocument.bodyMatchTokens` is the canonical body tokeniser. `SlideView.highlightedBody` and `NotesViewModel.observeRecognisedWords` must stay aligned with it.
- **No mocks for speech logic.** Tests drive `SpeechController.updateRolling(with:)` directly with strings.

## PR expectations

- Small focused PRs are reviewed faster than large ones.
- Run the full test suite (`xcodebuild ... test`) before opening.
- New behaviour ships with a test.
- For UI changes, attach a short screencap or screenshot in the PR body.
- First-time contributors: look for issues labelled [`good first issue`](https://github.com/pardel/PresenterNotes/issues?q=is%3Aopen+label%3A%22good+first+issue%22).

## Discussions vs issues

- **Issues** — confirmed bugs, concrete feature requests with a defined scope.
- **Discussions** — questions, ideas, "is anyone else seeing X?", architecture conversations.

## Licence

By contributing, you agree your contributions are licensed under the MIT Licence (see [LICENSE](LICENSE)).
