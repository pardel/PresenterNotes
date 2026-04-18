//
//  ContentView.swift
//  PresenterNotes
//
//  The main window: a mode-switchable shell that shows either the
//  scrolling "Present" view or the "Edit" view. The mode toggle, file
//  open, and speech controls live in the shared toolbar at the top.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ContentView: View {
    @EnvironmentObject var viewModel: NotesViewModel
    @StateObject private var speech = SpeechController()

    @State private var showFileImporter = false
    @State private var showFileExporter = false

    var body: some View {
        VStack(spacing: 0) {
            ModeBar(speech: speech)
            Divider()

            Group {
                switch viewModel.mode {
                case .present:
                    PresentView(speech: speech)
                case .edit:
                    EditorView(
                        showSaveExporter: $showFileExporter,
                        showOpenImporter: $showFileImporter
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if !viewModel.hasDocument {
                if !viewModel.restoreLastOpenedDocument() {
                    viewModel.loadSample()
                }
            }
            wireSpeech()
            installKeyboardMonitor()
            speech.requestAuthorizationIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openMarkdownRequested)) { _ in
            showFileImporter = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveMarkdownRequested)) { _ in
            do {
                try viewModel.save()
            } catch {
                showFileExporter = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .saveAsMarkdownRequested)) { _ in
            showFileExporter = true
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [UTType(filenameExtension: "md") ?? .plainText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                let needsStop = url.startAccessingSecurityScopedResource()
                defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
                viewModel.loadFromDisk(url)
            }
        }
        .fileExporter(
            isPresented: $showFileExporter,
            document: MarkdownFileDocument(text: viewModel.sourceText),
            contentType: .plainText,
            defaultFilename: viewModel.sourceURL?.deletingPathExtension().lastPathComponent ?? "Untitled.md"
        ) { result in
            if case let .success(url) = result {
                viewModel.didSaveAs(to: url)
            }
        }
    }

    // MARK: - Presentation remote / clicker support

    private static var keyMonitorInstalled = false

    /// Installs an app-wide key-event monitor that intercepts the keys
    /// presentation remotes commonly emit (Page Down/Up, arrows, Space,
    /// Return, Delete) and routes them to next/previous slide navigation.
    ///
    /// Only active in Present mode — in Edit mode the event is returned
    /// unchanged so TextEditor, scroll views, etc. can process it
    /// normally.
    ///
    /// This replaces the hidden-SwiftUI-button approach because
    /// `NSEvent.addLocalMonitorForEvents` fires before the responder
    /// chain, guaranteeing we see the event even if no SwiftUI view
    /// currently holds first-responder status (common after clicking a
    /// toolbar button or toggle).
    private func installKeyboardMonitor() {
        guard !Self.keyMonitorInstalled else { return }
        Self.keyMonitorInstalled = true

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak viewModel] event in
            guard let viewModel = viewModel else { return event }

            // Cmd+Return toggles Present / Edit
            if event.keyCode == 36 && event.modifierFlags.contains(.command) {
                viewModel.mode = viewModel.mode == .present ? .edit : .present
                return nil
            }

            // Edit mode: Cmd+B / Cmd+I toggle bold / italic markers
            if viewModel.mode == .edit && event.modifierFlags.contains(.command) {
                let marker: String?
                switch event.keyCode {
                case 11: marker = "**"  // Cmd+B → bold
                case 34: marker = "*"   // Cmd+I → italic
                default: marker = nil
                }
                if let marker = marker,
                   let textView = NSApp.keyWindow?.firstResponder as? NSTextView {
                    Self.toggleMarkdownMarker(marker, in: textView)
                    return nil
                }
            }

            guard viewModel.mode == .present else { return event }

            switch event.keyCode {
            case 53: // Escape
                viewModel.mode = .edit
                return nil
            case 124, 125, 121, 49, 36:
                if viewModel.presentStyle.usesParagraphs {
                    viewModel.nextParagraph()
                } else {
                    viewModel.next()
                }
                return nil
            case 123, 126, 116, 51:
                if viewModel.presentStyle.usesParagraphs {
                    viewModel.previousParagraph()
                } else {
                    viewModel.previous()
                }
                return nil
            default:
                return event
            }
        }
    }

    private static func toggleMarkdownMarker(_ marker: String, in textView: NSTextView) {
        let range = textView.selectedRange()
        let markerLen = marker.count

        if range.length == 0 {
            textView.insertText(marker + marker, replacementRange: range)
            textView.setSelectedRange(NSRange(location: range.location + markerLen, length: 0))
            return
        }

        let selected = (textView.string as NSString).substring(with: range)

        if selected.count >= markerLen * 2,
           selected.hasPrefix(marker),
           selected.hasSuffix(marker) {
            let inner = String(selected.dropFirst(markerLen).dropLast(markerLen))
            textView.insertText(inner, replacementRange: range)
            textView.setSelectedRange(NSRange(location: range.location, length: inner.count))
        } else {
            let wrapped = marker + selected + marker
            textView.insertText(wrapped, replacementRange: range)
            textView.setSelectedRange(NSRange(location: range.location + markerLen, length: selected.count))
        }
    }

    private func wireSpeech() {
        speech.currentTrailingWordsProvider = { [weak viewModel] in
            guard let viewModel = viewModel else { return [] }
            if viewModel.presentStyle.usesParagraphs {
                guard viewModel.paragraphs.indices.contains(viewModel.currentParagraphIndex) else { return [] }
                return NotesDocument.trailingWords(
                    from: viewModel.paragraphs[viewModel.currentParagraphIndex].text,
                    count: NotesDocument.trailingWordCount
                )
            }
            return viewModel.currentSlide?.trailingWords ?? []
        }
        speech.onAdvanceDetected = { [weak viewModel] in
            guard let viewModel = viewModel else { return }
            if viewModel.presentStyle.usesParagraphs {
                viewModel.nextParagraph()
            } else {
                viewModel.next()
            }
        }
        speech.onWordsRecognised = { [weak viewModel] words in
            viewModel?.observeRecognisedWords(words)
        }
    }
}

// MARK: - ModeBar

struct ModeBar: View {
    @EnvironmentObject var viewModel: NotesViewModel
    @ObservedObject var speech: SpeechController
    @AppStorage(looseMatchingDefaultsKey) private var looseMatching: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.book.closed")
                .foregroundStyle(.secondary)
            Text("Presenter Notes")
                .font(.headline)

            Spacer()

            // Presenter-only controls: slide navigation and the Listen
            // toggle only make sense when actually presenting, not while
            // editing the markdown source.
            if viewModel.mode == .present {
                // Style picker: Slide vs. Focused vs. Teleprompter
                Picker("", selection: $viewModel.presentStyle) {
                    Image(systemName: "rectangle.split.1x2").tag(PresentStyle.slide)
                    Image(systemName: "rectangle.center.inset.filled").tag(PresentStyle.focusedSlide)
                    Image(systemName: "text.justify.leading").tag(PresentStyle.teleprompter)
                }
                .pickerStyle(.segmented)
                .frame(width: 100)
                .help("Switch between slide, focused, and teleprompter views")

                Divider().frame(height: 18)

                if viewModel.presentStyle.usesParagraphs {
                    Button { viewModel.previousParagraph() } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(viewModel.currentParagraphIndex == 0)

                    Text("\(viewModel.currentParagraphIndex + 1) / \(max(viewModel.paragraphs.count, 1))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 56)

                    Button { viewModel.nextParagraph() } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(viewModel.currentParagraphIndex >= viewModel.paragraphs.count - 1)
                    Toggle(isOn: $viewModel.autoScroll) {
                        Label("Auto", systemImage: viewModel.autoScroll ? "play.fill" : "play")
                    }
                    .toggleStyle(.button)
                    .help("Auto-scroll through paragraphs at speaking pace")

                } else {
                    Button { viewModel.previous() } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(viewModel.currentIndex == 0)

                    Text("\(viewModel.currentIndex + 1) / \(max(viewModel.slides.count, 1))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 56)

                    Button { viewModel.next() } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(viewModel.currentIndex >= viewModel.slides.count - 1)
                }

                Divider().frame(height: 18)

                Toggle(isOn: Binding(
                    get: { speech.isRunning },
                    set: { newValue in
                        if newValue { speech.start() } else { speech.stop() }
                    }
                )) {
                    Label(speech.isRunning ? "Listening" : "Listen",
                          systemImage: speech.isRunning ? "waveform.circle.fill" : "waveform.circle")
                }
                .toggleStyle(.button)

                Toggle(isOn: $looseMatching) {
                    Label("Loose", systemImage: "waveform.and.magnifyingglass")
                }
                .toggleStyle(.button)
                .help("Loose matching — tolerates minor mispronunciation and filler words.")
                .onChange(of: looseMatching) { newValue in
                    speech.looseMatching = newValue
                }

                Spacer()
            }

            PresentEditSwitch(isPresenting: Binding(
                get: { viewModel.mode == .present },
                set: { viewModel.mode = $0 ? .present : .edit }
            ))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(alignment: .leading) {
            // Progress indicator: in Present mode the top bar fills from
            // left to right as the presenter advances through the deck.
            // Sits behind the controls via `.background` so it doesn't
            // affect layout.
            if viewModel.mode == .present {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.blue.opacity(0.2))
                        .frame(width: geo.size.width * progressFraction)
                }
            }
        }
        .animation(.easeInOut(duration: 0.15), value: viewModel.currentIndex)
        .animation(.easeInOut(duration: 0.15), value: viewModel.currentParagraphIndex)
        .animation(.easeInOut(duration: 0.25), value: viewModel.mode)
    }

    /// Progress for the top-bar fill. In `.slide` style the whole slide is
    /// on screen at once, so progress is slide-based. In `.focusedSlide` /
    /// `.teleprompter` the navigation unit is the paragraph, so progress
    /// should advance paragraph-by-paragraph.
    private var progressFraction: CGFloat {
        let index: Int
        let total: Int
        if viewModel.presentStyle.usesParagraphs {
            index = viewModel.currentParagraphIndex
            total = viewModel.paragraphs.count
        } else {
            index = viewModel.currentIndex
            total = viewModel.slides.count
        }
        guard total > 0 else { return 0 }
        return CGFloat(index + 1) / CGFloat(total)
    }
}

/// Custom pill-shaped mode switch. Knob sits on the leading edge when
/// presenting, trailing edge when editing, and the label flips to match
/// the current mode. Hugs its content width: the label reserves the
/// footprint of the wider of the two strings ("Present") so the whole
/// control doesn't resize as the user toggles it.
private struct PresentEditSwitch: View {
    @Binding var isPresenting: Bool
    @Namespace private var switchNamespace

    private let trackHeight: CGFloat = 32
    private let trackInset: CGFloat = 3
    private let knobLabelSpacing: CGFloat = 6
    private let edgePadding: CGFloat = 14
    private var knobSize: CGFloat { trackHeight - trackInset * 2 }

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) {
                isPresenting.toggle()
            }
        } label: {
            HStack(spacing: 0) {
                if isPresenting {
                    knobView
                        .padding(.leading, trackInset)
                        .padding(.trailing, knobLabelSpacing)
                    labelView
                        .padding(.trailing, edgePadding)
                } else {
                    labelView
                        .padding(.leading, edgePadding)
                        .padding(.trailing, knobLabelSpacing)
                    knobView
                        .padding(.trailing, trackInset)
                }
            }
            .frame(height: trackHeight)
            .background(
                Capsule().fill(isPresenting ? Color(white: 0.1) : Color.red)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Presentation mode"))
        .accessibilityValue(Text(isPresenting ? "on" : "off"))
    }

    private var knobView: some View {
        Circle()
            .fill(Color.white)
            .frame(width: knobSize, height: knobSize)
            .matchedGeometryEffect(id: "knob", in: switchNamespace)
    }

    /// Both labels are always in the layer stack; only the opacity swaps.
    /// That keeps the label footprint constant (= width of "Present",
    /// the wider string) regardless of which label is currently visible.
    private var labelView: some View {
        ZStack {
            Text("Present").opacity(isPresenting ? 1 : 0)
            Text("Edit").opacity(isPresenting ? 0 : 1)
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
    }
}

// MARK: - PresentView

struct PresentView: View {
    @EnvironmentObject var viewModel: NotesViewModel
    @ObservedObject var speech: SpeechController

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch viewModel.presentStyle {
                case .slide:
                    currentSlideView
                case .focusedSlide:
                    FocusedSlideView()
                case .teleprompter:
                    TeleprompterView()
                }
            }
            Divider()
            statusBar
        }
    }

    private var currentSlideView: some View {
        GeometryReader { geo in
            FullScreenSlideView(
                slide: viewModel.currentSlide,
                wordsSpoken: viewModel.spokenWordCount,
                availableSize: geo.size
            )
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeOut(duration: 0.08), value: viewModel.currentIndex)
        }
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(speech.isRunning ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(speech.isRunning ? speech.statusMessage : "Remote ready · ← → arrows or Page Up/Down")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if speech.isRunning && !speech.lastTranscript.isEmpty {
                Text(String(speech.lastTranscript.suffix(80)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            if let source = viewModel.sourceURL {
                Text(source.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - TeleprompterView

struct TeleprompterView: View {
    @EnvironmentObject var viewModel: NotesViewModel
    @AppStorage(presenterFontDefaultsKey) private var selectedFontRaw: String = PresenterFont.system.rawValue

    private var selectedFont: PresenterFont {
        PresenterFont(rawValue: selectedFontRaw) ?? .system
    }

    private let inactiveSize: CGFloat = 48
    private let maxActiveSize: CGFloat = 80
    private let titleSize: CGFloat = 36

    var body: some View {
        GeometryReader { geo in
            let viewportHeight = geo.size.height
            let viewportWidth = geo.size.width

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(viewModel.paragraphs) { para in
                            let isCurrent = para.id == viewModel.currentParagraphIndex
                            let fontSize = isCurrent
                                ? Self.activeFontSize(
                                    for: para, viewportWidth: viewportWidth,
                                    viewportHeight: viewportHeight, maxSize: maxActiveSize,
                                    minSize: inactiveSize)
                                : inactiveSize

                            VStack(alignment: .leading, spacing: 8) {
                                if para.isFirstInSlide && para.id > 0 {
                                    Divider().padding(.vertical, 16)
                                }
                                if let title = para.title, !title.isEmpty {
                                    Text(title)
                                        .font(selectedFont.font(size: titleSize, weight: .semibold))
                                        .foregroundStyle(isCurrent ? .secondary : .tertiary)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.bottom, 4)
                                }
                                Text(SlideView.highlightedBody(
                                    para.text,
                                    wordsSpoken: isCurrent ? viewModel.spokenWordCount : 0
                                ))
                                .font(selectedFont.font(size: fontSize, weight: .regular))
                                .lineSpacing(fontSize * 0.25)
                                .foregroundStyle(isCurrent ? .primary : .tertiary)
                                .textSelection(.enabled)

                                if isCurrent && viewModel.autoScroll {
                                    GeometryReader { barGeo in
                                        Capsule()
                                            .fill(Color.accentColor.opacity(0.5))
                                            .frame(width: barGeo.size.width * viewModel.autoScrollProgress)
                                    }
                                    .frame(height: 4)
                                    .padding(.top, 8)
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(
                                UnevenRoundedRectangle(
                                    cornerRadii: Self.cornerRadii(for: para),
                                    style: .continuous
                                )
                                .fill(Self.paragraphBackground(for: para, isCurrent: isCurrent))
                            )
                            .overlay(
                                UnevenRoundedRectangle(
                                    cornerRadii: Self.cornerRadii(for: para),
                                    style: .continuous
                                )
                                .strokeBorder(
                                    isCurrent ? Color.accentColor.opacity(0.6) : Color.clear,
                                    lineWidth: 2
                                )
                            )
                            .scaleEffect(isCurrent ? 1.0 : 0.92, anchor: .leading)
                            .opacity(isCurrent ? 1.0 : 0.5)
                            .id(para.id)
                            .onTapGesture {
                                viewModel.jumpToParagraph(para.id)
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 60)
                }
                .onChange(of: viewModel.currentParagraphIndex) { newValue in
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.88)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
                .onAppear {
                    proxy.scrollTo(viewModel.currentParagraphIndex, anchor: .center)
                }
                .animation(.easeOut(duration: 0.15), value: viewModel.currentParagraphIndex)
            }
        }
    }

    /// Background tint for a paragraph. The last paragraph of a slide
    /// gets a red cue so the upcoming slide change is visible; everything
    /// else falls back to the accent-when-current behaviour. Single-
    /// paragraph slides are "last" and therefore red.
    static func paragraphBackground(
        for para: TeleprompterParagraph,
        isCurrent: Bool
    ) -> Color {
        if para.isLastInSlide {
            return Color.red.opacity(isCurrent ? 0.20 : 0.10)
        }
        return isCurrent ? Color.accentColor.opacity(0.05) : .clear
    }

    /// Corner radii that round only the outer edges of a slide: top on
    /// the first paragraph, bottom on the last, square in between.
    /// Single-paragraph slides end up fully rounded.
    static func cornerRadii(for para: TeleprompterParagraph) -> RectangleCornerRadii {
        let r: CGFloat = 12
        let top = para.isFirstInSlide ? r : 0
        let bottom = para.isLastInSlide ? r : 0
        return RectangleCornerRadii(
            topLeading: top,
            bottomLeading: bottom,
            bottomTrailing: bottom,
            topTrailing: top
        )
    }

    /// Pick the largest font that still lets the paragraph fit within
    /// the viewport height. Uses the same area-based estimate as
    /// `FullScreenSlideView.bodyFontSize`, clamped to [minSize, maxSize].
    static func activeFontSize(
        for para: TeleprompterParagraph,
        viewportWidth: CGFloat,
        viewportHeight: CGFloat,
        maxSize: CGFloat,
        minSize: CGFloat
    ) -> CGFloat {
        let usableW = max(viewportWidth - 88, 200)
        let usableH = max(viewportHeight - 80, 200)
        let chars = max(CGFloat(para.text.count), 1)
        let raw = sqrt((usableW * usableH) / (chars * 0.85))
        return min(max(raw, minSize), maxSize)
    }
}

// MARK: - FocusedSlideView

/// One slide pinned to the viewport, with the current paragraph shown as
/// large as possible and the other paragraphs of the same slide shrunk
/// down as context. Navigation is paragraph-level (`nextParagraph` /
/// `previousParagraph`), so moving past the last paragraph of a slide
/// automatically jumps to the next slide's first paragraph.
struct FocusedSlideView: View {
    @EnvironmentObject var viewModel: NotesViewModel
    @AppStorage(presenterFontDefaultsKey) private var selectedFontRaw: String = PresenterFont.system.rawValue

    private var selectedFont: PresenterFont {
        PresenterFont(rawValue: selectedFontRaw) ?? .system
    }

    var body: some View {
        GeometryReader { geo in
            let slideIdx = viewModel.currentIndex
            let slideParas = viewModel.paragraphs.filter { $0.slideIndex == slideIdx }
            let currentId = viewModel.currentParagraphIndex
            let title = slideParas.first?.title ?? viewModel.currentSlide?.title
            let sizes = Self.paragraphSizes(
                slideParagraphs: slideParas,
                currentId: currentId
            )

            VStack(alignment: .leading, spacing: 6) {
                if let title, !title.isEmpty {
                    Text(title)
                        .font(selectedFont.font(size: 32, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.bottom, 8)
                }

                ForEach(Array(slideParas.enumerated()), id: \.element.id) { idx, para in
                    let isCurrent = para.id == currentId
                    let size = sizes.indices.contains(idx) ? sizes[idx] : 20
                    Text(SlideView.highlightedBody(
                        para.text,
                        wordsSpoken: isCurrent ? viewModel.spokenWordCount : 0
                    ))
                    .font(selectedFont.font(size: size, weight: .regular))
                    .lineSpacing(size * 0.05)
                    .foregroundStyle(.primary)
                    .opacity(isCurrent ? 1.0 : 0.75)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(isCurrent ? nil : 1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(isCurrent ? 0.3 : 1.0)
                    .padding(.horizontal, isCurrent ? 16 : 0)
                    .padding(.vertical, isCurrent ? 12 : 0)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(isCurrent ? Color.accentColor.opacity(0.06) : Color.clear)
                    )
                    .padding(.vertical, isCurrent ? 10 : 0)
                    .onTapGesture {
                        viewModel.jumpToParagraph(para.id)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.top, 20)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .animation(.easeOut(duration: 0.12), value: currentId)
            .animation(.easeOut(duration: 0.12), value: slideIdx)
        }
    }

    /// Font size for the current paragraph — held constant so the text
    /// doesn't jump size between paragraphs. Minimum scale factor on the
    /// Text view handles the rare overflow case.
    static let currentParagraphSize: CGFloat = 84

    /// Font size for non-current paragraphs, which render on a single
    /// truncated line and only serve as positional context.
    static let nonCurrentParagraphSize: CGFloat = 22

    static func paragraphSizes(
        slideParagraphs: [TeleprompterParagraph],
        currentId: Int
    ) -> [CGFloat] {
        slideParagraphs.map {
            $0.id == currentId ? currentParagraphSize : nonCurrentParagraphSize
        }
    }
}

// MARK: - PresenterFont

/// Font family the user has picked for Present mode.
///
/// Three groups:
///   1. `.system` / `.serif` / `.rounded` — Apple system fonts, always
///      available, resolve to optical-size variants at display sizes.
///   2. Preinstalled macOS families (Helvetica Neue, Avenir Next,
///      Georgia) — always available on any modern macOS.
///   3. Optional research-recommended families tuned for distance
///      readability (Atkinson Hyperlegible, Lexend, Inter, IBM Plex
///      Sans). These are free / OFL-licensed but not preinstalled; the
///      user must download and install them via Font Book. When missing,
///      SwiftUI silently falls back to the system font and the picker
///      marks the entry as "not installed".
enum PresenterFont: String, CaseIterable, Identifiable {
    case system
    case serif
    case rounded
    case helveticaNeue
    case avenirNext
    case georgia
    case atkinsonHyperlegible
    case lexend
    case inter
    case ibmPlexSans

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:               return "System (SF Pro)"
        case .serif:                return "New York (Serif)"
        case .rounded:              return "SF Rounded"
        case .helveticaNeue:        return "Helvetica Neue"
        case .avenirNext:           return "Avenir Next"
        case .georgia:              return "Georgia"
        case .atkinsonHyperlegible: return "Atkinson Hyperlegible"
        case .lexend:               return "Lexend"
        case .inter:                return "Inter"
        case .ibmPlexSans:          return "IBM Plex Sans"
        }
    }

    /// Font-family name to look up in the system font manager.
    /// `nil` means this case resolves to `Font.system(...)` and is
    /// therefore always available.
    var familyName: String? {
        switch self {
        case .system, .serif, .rounded:
            return nil
        case .helveticaNeue:        return "Helvetica Neue"
        case .avenirNext:           return "Avenir Next"
        case .georgia:              return "Georgia"
        case .atkinsonHyperlegible: return "Atkinson Hyperlegible"
        case .lexend:               return "Lexend"
        case .inter:                return "Inter"
        case .ibmPlexSans:          return "IBM Plex Sans"
        }
    }

    var isAvailable: Bool {
        guard let name = familyName else { return true }
        return Self.installedFamilies.contains(name)
    }

    /// Snapshot of installed font families taken once at first access.
    /// If the user installs a new font while the app is running, they
    /// need to restart to see it here — an acceptable trade for avoiding
    /// a system-font-manager call on every picker render.
    private static let installedFamilies: Set<String> = {
        Set(NSFontManager.shared.availableFontFamilies)
    }()

    func font(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        switch self {
        case .system:
            return .system(size: size, weight: weight, design: .default)
        case .serif:
            return .system(size: size, weight: weight, design: .serif)
        case .rounded:
            return .system(size: size, weight: weight, design: .rounded)
        default:
            guard let name = familyName else {
                return .system(size: size, weight: weight)
            }
            return .custom(name, size: size).weight(weight)
        }
    }
}

/// Shared UserDefaults key for the presenter font selection. Kept here so
/// both `PreviewPane` (where it's chosen) and `FullScreenSlideView`
/// (where it's consumed) reference the exact same string.
let presenterFontDefaultsKey = "PresenterNotes.selectedFont"

// MARK: - FullScreenSlideView (one slide at a time, fills the present area)

/// Renders exactly one slide, sized to fill the available area so the text
/// is readable from the back of the room. Font size is driven by a single
/// decision function, `bodyFontSize(for:in:)`, defined below.
struct FullScreenSlideView: View {
    let slide: NoteSlide?
    let wordsSpoken: Int
    let availableSize: CGSize

    @AppStorage(presenterFontDefaultsKey) private var selectedFontRaw: String = PresenterFont.system.rawValue

    private var selectedFont: PresenterFont {
        PresenterFont(rawValue: selectedFontRaw) ?? .system
    }

    var body: some View {
        if let slide = slide {
            let bodySize = Self.bodyFontSize(for: slide, in: availableSize)
            let titleSize = bodySize * 0.75

            VStack(spacing: 0) {
                if let title = slide.title, !title.isEmpty {
                    Text(title)
                        .font(selectedFont.font(size: titleSize, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                        .padding(.bottom, bodySize * 0.3)
                }
                Text(SlideView.highlightedBody(slide.body, wordsSpoken: wordsSpoken))
                    .font(selectedFont.font(size: bodySize, weight: .regular))
                    .lineSpacing(bodySize * 0.25)
                    .multilineTextAlignment(.leading)
                    .minimumScaleFactor(0.3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack {
                Text("No notes loaded")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Decide how large the body text should be for a given slide in a
    /// given container. Area-based: estimate the character-area budget
    /// (`usableWidth × usableHeight`) and solve for the font size that
    /// makes the slide's characters roughly fill it.
    ///
    /// Glyph-area approximation for our font stack:
    ///   - average glyph advance ≈ 0.52 × S
    ///   - line height with our `lineSpacing(S * 0.25)` ≈ 1.45 × S
    ///   → chars that fit ≈ (W × H) / (0.75 × S²)
    /// Solving for S with ~10% wrap slack gives the 0.85 divisor below.
    ///
    /// Clamped to [36, 140]pt — `minimumScaleFactor(0.3)` in the view is
    /// the safety net for pathologically long slides, not the main knob.
    static func bodyFontSize(for slide: NoteSlide, in container: CGSize) -> CGFloat {
        let usableW = max(container.width - 24, 200)
        let usableH = max(container.height - 16, 200)

        let hasTitle = !(slide.title ?? "").isEmpty
        let bodyHeight = usableH * (hasTitle ? 0.82 : 1.0)

        let chars = max(CGFloat(slide.body.count), 1)
        let raw = sqrt((usableW * bodyHeight) / (chars * 0.85))

        return min(max(raw, 36), 140)
    }
}

// MARK: - SlideView (big presenter-mode card)

struct SlideView: View {
    let slide: NoteSlide
    let isCurrent: Bool
    /// How many whitespace-separated words of the body have been spoken
    /// already (and should render with a highlight). Only meaningful
    /// for the current slide; pass 0 for inactive slides.
    var wordsSpoken: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title = slide.title, !title.isEmpty {
                Text(title)
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                    .foregroundStyle(isCurrent ? .primary : .secondary)
            }
            Text(Self.highlightedBody(slide.body, wordsSpoken: isCurrent ? wordsSpoken : 0))
                .font(.system(size: isCurrent ? 24 : 20, weight: isCurrent ? .regular : .light))
                .foregroundStyle(isCurrent ? .primary : .secondary)
                .lineSpacing(6)
                .textSelection(.enabled)
                .animation(.easeInOut(duration: 0.2), value: wordsSpoken)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isCurrent
                      ? Color.accentColor.opacity(0.12)
                      : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(isCurrent ? Color.accentColor.opacity(0.55) : Color.clear,
                              lineWidth: 1.5)
        )
        .animation(.easeInOut(duration: 0.25), value: isCurrent)
    }

    /// Parse inline markdown (bold, italic, code, etc.) into an
    /// `AttributedString`. Falls back to plain text if parsing fails.
    static func parseMarkdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    /// Build an `AttributedString` of the body with markdown formatting
    /// applied and the first `wordsSpoken` whitespace-separated words
    /// painted with an accent background so the presenter can see how far
    /// the speech follower thinks they've read.
    static func highlightedBody(_ body: String, wordsSpoken: Int) -> AttributedString {
        var result = parseMarkdown(body)
        guard wordsSpoken > 0 else { return result }

        var wordCount = 0
        var inWord = false
        for index in result.characters.indices {
            let ch = result.characters[index]
            if ch.isWhitespace {
                inWord = false
            } else {
                if !inWord {
                    wordCount += 1
                    inWord = true
                }
                if wordCount <= wordsSpoken {
                    let next = result.characters.index(after: index)
                    result[index..<next].backgroundColor = Color.accentColor.opacity(0.35)
                    result[index..<next].foregroundColor = .primary
                }
            }
        }
        return result
    }
}

// MARK: - Previews

#if DEBUG
private func contentPreviewModel() -> NotesViewModel {
    let vm = NotesViewModel()
    vm.loadSample()
    return vm
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ContentView()
                .environmentObject(contentPreviewModel())
                .frame(width: 1100, height: 700)
                .previewDisplayName("ContentView — Present")

            ContentView()
                .environmentObject({
                    let vm = contentPreviewModel()
                    vm.mode = .edit
                    return vm
                }())
                .frame(width: 1100, height: 700)
                .previewDisplayName("ContentView — Edit")
        }
    }
}

struct ModeBar_Previews: PreviewProvider {
    static var previews: some View {
        ModeBar(speech: SpeechController())
            .environmentObject(contentPreviewModel())
            .frame(width: 1100)
            .padding()
            .previewDisplayName("ModeBar")
    }
}

struct PresentView_Previews: PreviewProvider {
    static var previews: some View {
        PresentView(speech: SpeechController())
            .environmentObject(contentPreviewModel())
            .frame(width: 900, height: 600)
            .previewDisplayName("PresentView")
    }
}

struct SlideView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            SlideView(
                slide: NoteSlide(
                    id: 0,
                    title: "Welcome",
                    body: "Thanks for joining today. I'm excited to walk you through what we've been building.",
                    trailingWords: ["we", "ve", "been", "building"]
                ),
                isCurrent: true,
                wordsSpoken: 0
            )
            SlideView(
                slide: NoteSlide(
                    id: 1,
                    title: "Welcome — mid-read",
                    body: "Thanks for joining today. I'm excited to walk you through what we've been building.",
                    trailingWords: ["we", "ve", "been", "building"]
                ),
                isCurrent: true,
                wordsSpoken: 6
            )
            SlideView(
                slide: NoteSlide(
                    id: 2,
                    title: "The Problem",
                    body: "A shorter body paragraph that isn't currently active.",
                    trailingWords: []
                ),
                isCurrent: false
            )
        }
        .padding(40)
        .frame(width: 900)
        .previewDisplayName("SlideView")
    }
}
#endif
