//
//  EditorView.swift
//  PresenterNotes
//
//  A three-column editor for the slides-format markdown:
//    1. Outline of detected slides on the left.
//    2. Plain-text TextEditor in the middle.
//    3. Live slide preview on the right.
//
//  Underneath, a validation bar shows every rule violation detected in
//  the source and offers one-click "Fix" buttons for repairable issues.
//

import SwiftUI
import UniformTypeIdentifiers
import AppKit

extension Notification.Name {
    static let scrollEditorToSlide = Notification.Name("PresenterNotes.scrollEditorToSlide")
}

struct EditorView: View {
    @EnvironmentObject var viewModel: NotesViewModel

    @Binding var showSaveExporter: Bool
    @Binding var showOpenImporter: Bool

    @State private var pendingAction: PendingAction?

    /// Actions that would replace the current document. Routed through
    /// `pendingAction` so we can surface a save reminder when the doc has
    /// unsaved changes.
    enum PendingAction: Identifiable {
        case new
        case sample
        case open

        var id: Self { self }

        var title: String {
            switch self {
            case .new:    return "Start a new document?"
            case .sample: return "Load the sample document?"
            case .open:   return "Open another document?"
            }
        }

        var cleanActionLabel: String {
            switch self {
            case .new:    return "New Document"
            case .sample: return "Load Sample"
            case .open:   return "Open…"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            editorToolbar
            Divider()
            HSplitView {
                OutlinePane()
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)

                EditorPane()
                    .frame(minWidth: 320)

                PreviewPane()
                    .frame(minWidth: 320)
            }
            Divider()
            ValidationBar(showSaveExporter: $showSaveExporter)
        }
        .confirmationDialog(
            pendingAction?.title ?? "",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingAction
        ) { action in
            if viewModel.isDirty {
                Button("Save and Continue") { saveAndPerform(action) }
                Button("Discard Changes", role: .destructive) { perform(action) }
            } else {
                Button(action.cleanActionLabel, role: .destructive) { perform(action) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { _ in
            Text(viewModel.isDirty
                 ? "You have unsaved changes. Save them before continuing?"
                 : "This will replace the current document.")
        }
    }

    // MARK: - Pending-action flow

    private func perform(_ action: PendingAction) {
        switch action {
        case .new:    viewModel.newDocument()
        case .sample: viewModel.loadSample()
        case .open:   showOpenImporter = true
        }
    }

    private func saveAndPerform(_ action: PendingAction) {
        do {
            try viewModel.save()
            perform(action)
        } catch {
            // No writable destination yet — fall back to Save As. The
            // action doesn't chain through the async exporter flow; the
            // user can retry it after saving.
            showSaveExporter = true
        }
    }

    // MARK: - Toolbar

    private var editorToolbar: some View {
        HStack(spacing: 12) {
            Button {
                if viewModel.isDirty {
                    pendingAction = .open
                } else {
                    showOpenImporter = true
                }
            } label: {
                Label("Open…", systemImage: "doc.text")
            }

            Button {
                pendingAction = .new
            } label: {
                Label("New", systemImage: "doc.badge.plus")
            }

            Button {
                pendingAction = .sample
            } label: {
                Label("Sample", systemImage: "sparkles")
            }

            Divider().frame(height: 18)

            Button {
                insertNewSlide()
            } label: {
                Label("New Slide", systemImage: "text.append")
            }

            Spacer()

            HStack(spacing: 4) {
                if viewModel.isDirty {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 8, height: 8)
                    Text("Unsaved changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if viewModel.sourceURL != nil {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(.green)
                    Text("Saved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                saveOrExport()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .disabled(!viewModel.isDirty && viewModel.sourceURL != nil)

            Button {
                showSaveExporter = true
            } label: {
                Label("Save As…", systemImage: "square.and.arrow.down.on.square")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Actions

    private func insertNewSlide() {
        let addition = (viewModel.sourceText.hasSuffix("\n\n") ? "" : (viewModel.sourceText.hasSuffix("\n") ? "\n" : "\n\n"))
            + "## New Slide\n\nAdd your notes here.\n"
        viewModel.sourceText += addition
    }

    private func saveOrExport() {
        do {
            try viewModel.save()
        } catch {
            // Fall back to Save As if we don't have a writable destination.
            showSaveExporter = true
        }
    }
}

// MARK: - OutlinePane

struct OutlinePane: View {
    @EnvironmentObject var viewModel: NotesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Outline")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            if viewModel.slides.isEmpty {
                Text("No slides yet.\nStart with `## Heading`.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(viewModel.slides) { slide in
                            OutlineRow(
                                index: slide.id + 1,
                                title: slide.title ?? "Preamble",
                                isCurrent: slide.id == viewModel.currentIndex
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                NotificationCenter.default.post(
                                    name: .scrollEditorToSlide,
                                    object: slide.id
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct OutlineRow: View {
    let index: Int
    let title: String
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20, alignment: .trailing)
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isCurrent ? Color.accentColor.opacity(0.18) : Color.clear)
        )
    }
}

// MARK: - EditorPane

struct EditorPane: View {
    @EnvironmentObject var viewModel: NotesViewModel
    @State private var suppressScrollTracking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Markdown")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)
            TextEditor(text: $viewModel.sourceText)
                .font(.system(size: 14, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .onReceive(
            NotificationCenter.default.publisher(for: NSTextView.didChangeSelectionNotification)
        ) { notification in
            guard !suppressScrollTracking else { return }
            guard let textView = notification.object as? NSTextView,
                  textView.string == viewModel.sourceText else { return }
            let offset = textView.selectedRange().location
            let idx = Self.slideIndex(forCursorAt: offset, in: viewModel.sourceText)
            if idx != viewModel.currentIndex {
                viewModel.jump(to: idx)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSView.boundsDidChangeNotification)
        ) { notification in
            guard !suppressScrollTracking else { return }
            guard let clipView = notification.object as? NSClipView,
                  let textView = clipView.documentView as? NSTextView,
                  textView.string == viewModel.sourceText else { return }
            let visibleRect = clipView.documentVisibleRect
            let samplePoint = NSPoint(x: 0, y: visibleRect.minY + visibleRect.height * 0.33)
            let charIndex = textView.characterIndexForInsertion(at: samplePoint)
            let idx = Self.slideIndex(forCursorAt: charIndex, in: viewModel.sourceText)
            if idx != viewModel.currentIndex {
                viewModel.jump(to: idx)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .scrollEditorToSlide)
        ) { notification in
            guard let slideId = notification.object as? Int else { return }

            viewModel.jump(to: slideId)

            suppressScrollTracking = true

            let sourceText = viewModel.sourceText
            DispatchQueue.main.async {
                guard let textView = Self.findEditorTextView(matching: sourceText) else {
                    suppressScrollTracking = false
                    return
                }

                let offset = Self.characterOffset(forSlide: slideId, in: sourceText)
                let range = NSRange(location: offset, length: 0)
                textView.setSelectedRange(range)
                textView.scrollRangeToVisible(range)

                if let scrollView = textView.enclosingScrollView,
                   let window = textView.window {
                    let clipView = scrollView.contentView
                    let visibleHeight = clipView.bounds.height
                    var actual = NSRange()
                    let screenRect = textView.firstRect(
                        forCharacterRange: range, actualRange: &actual)
                    if screenRect.height > 0 {
                        let windowRect = window.convertFromScreen(screenRect)
                        let localPoint = textView.convert(windowRect.origin, from: nil)
                        let targetY = max(localPoint.y - visibleHeight * 0.1, 0)
                        clipView.scroll(to: NSPoint(x: 0, y: targetY))
                        scrollView.reflectScrolledClipView(clipView)
                    }
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    suppressScrollTracking = false
                }
            }
        }
        .onAppear {
            guard viewModel.currentIndex > 0 else { return }
            let index = viewModel.currentIndex
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NotificationCenter.default.post(
                    name: .scrollEditorToSlide,
                    object: index
                )
            }
        }
    }

    private static func findEditorTextView(matching sourceText: String) -> NSTextView? {
        guard let contentView = NSApp.keyWindow?.contentView else { return nil }
        return findTextView(in: contentView, matching: sourceText)
    }

    private static func findTextView(in view: NSView, matching text: String) -> NSTextView? {
        if let tv = view as? NSTextView, tv.string == text { return tv }
        for sub in view.subviews {
            if let found = findTextView(in: sub, matching: text) { return found }
        }
        return nil
    }

    /// UTF-16 code-unit offset (equivalently, `NSString` index) of the
    /// start of slide `slideId` within `text`. Returned in that
    /// coordinate system because the caller feeds it into
    /// `NSRange(location:)` on `NSTextView`. Counting Swift Characters
    /// (grapheme clusters) would drift from the NSRange world for any
    /// content with emoji, CJK, or composed characters.
    static func characterOffset(forSlide slideId: Int, in text: String) -> Int {
        let lines = text.components(separatedBy: "\n")
        var charPos = 0
        var currentSlide = -1

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if NotesDocument.h2Title(in: line) != nil {
                currentSlide += 1
            } else if currentSlide < 0 && !trimmed.isEmpty {
                currentSlide = 0
            }
            if currentSlide == slideId { return charPos }
            charPos += line.utf16.count + 1  // +1 for the `\n` separator
        }
        return max(charPos - 1, 0)
    }

    /// Which slide contains the cursor at `offset`. `offset` is expected
    /// to be a UTF-16 code-unit offset (the form `NSTextView` reports
    /// via `selectedRange().location` and `characterIndexForInsertion`).
    static func slideIndex(forCursorAt offset: Int, in text: String) -> Int {
        let lines = text.components(separatedBy: "\n")
        var charPos = 0
        var slideIdx = -1
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if NotesDocument.h2Title(in: line) != nil {
                slideIdx += 1
            } else if slideIdx < 0 && !trimmed.isEmpty {
                slideIdx = 0
            }
            charPos += line.utf16.count + 1
            if charPos > offset { break }
        }
        return max(slideIdx, 0)
    }
}

// MARK: - PreviewPane

struct PreviewPane: View {
    @EnvironmentObject var viewModel: NotesViewModel
    @AppStorage(presenterFontDefaultsKey) private var selectedFontRaw: String = PresenterFont.system.rawValue
    @State private var showFontInfo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Preview")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("Font", selection: $selectedFontRaw) {
                    ForEach(PresenterFont.allCases) { font in
                        Text(font.isAvailable
                             ? font.displayName
                             : "\(font.displayName) — not installed")
                            .tag(font.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 200)

                Button {
                    showFontInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
                .buttonStyle(.borderless)
                .help("How to install the distance-readable fonts")
                .popover(isPresented: $showFontInfo, arrowEdge: .top) {
                    FontInstallInfo()
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if viewModel.slides.isEmpty {
                            Text("Nothing to preview yet.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(viewModel.slides) { slide in
                                PreviewSlideView(
                                    slide: slide,
                                    isCurrent: slide.id == viewModel.currentIndex
                                )
                                .id(slide.id)
                            }
                        }
                    }
                    .padding(16)
                }
                .onChange(of: viewModel.currentIndex) { newIndex in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newIndex, anchor: .top)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

private struct FontInstallInfo: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Distance-readable fonts")
                .font(.headline)

            Text("System (SF Pro), New York, SF Rounded, Helvetica Neue, Avenir Next and Georgia are always available on macOS.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text("These are free, open-licensed and tuned for distance legibility, but not preinstalled. Download the .ttf / .otf files and double-click to install via Font Book, then restart Presenter Notes:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 5) {
                Link("Atkinson Hyperlegible — Google Fonts",
                     destination: URL(string: "https://fonts.google.com/specimen/Atkinson+Hyperlegible")!)
                Link("Lexend — Google Fonts",
                     destination: URL(string: "https://fonts.google.com/specimen/Lexend")!)
                Link("Inter — Google Fonts",
                     destination: URL(string: "https://fonts.google.com/specimen/Inter")!)
                Link("IBM Plex Sans — Google Fonts",
                     destination: URL(string: "https://fonts.google.com/specimen/IBM+Plex+Sans")!)
            }
            .font(.caption)

            Text("Atkinson Hyperlegible (by the Braille Institute) is the strongest pick for readability from the back of a room.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 340)
    }
}

struct PreviewSlideView: View {
    let slide: NoteSlide
    let isCurrent: Bool

    @AppStorage(presenterFontDefaultsKey) private var selectedFontRaw: String = PresenterFont.system.rawValue

    private var selectedFont: PresenterFont {
        PresenterFont(rawValue: selectedFontRaw) ?? .system
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = slide.title, !title.isEmpty {
                Text(title)
                    .font(selectedFont.font(size: 22, weight: .semibold))
            }
            Text(SlideView.parseMarkdown(slide.body))
                .font(selectedFont.font(size: 17))
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .lineLimit(nil)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrent ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.05))
        )
    }
}

// MARK: - ValidationBar

struct ValidationBar: View {
    @EnvironmentObject var viewModel: NotesViewModel
    @Binding var showSaveExporter: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if viewModel.issues.isEmpty {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Text("No format issues — looks ready.")
                        .font(.caption)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(viewModel.errorCount > 0 ? .red : .orange)
                    Text(summary)
                        .font(.caption)
                    Spacer()
                    Button("Fix All") {
                        viewModel.applyAllFixes()
                    }
                    .controlSize(.small)
                    .disabled(!viewModel.issues.contains { $0.fix != nil })
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            if !viewModel.issues.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(viewModel.issues) { issue in
                            IssueRow(issue: issue)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 120)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var summary: String {
        let e = viewModel.errorCount
        let w = viewModel.warningCount
        switch (e, w) {
        case (0, let w): return "\(w) warning\(w == 1 ? "" : "s")"
        case (let e, 0): return "\(e) error\(e == 1 ? "" : "s")"
        case (let e, let w): return "\(e) error\(e == 1 ? "" : "s"), \(w) warning\(w == 1 ? "" : "s")"
        }
    }
}

struct IssueRow: View {
    @EnvironmentObject var viewModel: NotesViewModel
    let issue: ValidationIssue

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: issue.severity == .error
                  ? "xmark.octagon.fill"
                  : "exclamationmark.triangle.fill")
                .foregroundStyle(issue.severity == .error ? .red : .orange)
                .imageScale(.small)
            Text(issue.message)
                .font(.caption)
                .foregroundStyle(.primary)
            Spacer()
            if issue.fix != nil {
                Button("Fix") {
                    viewModel.apply(issue)
                }
                .controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Previews

#if DEBUG
@MainActor
private func previewModel(_ source: String? = nil) -> NotesViewModel {
    let vm = NotesViewModel()
    if let source = source {
        vm.loadMarkdown(source)
    } else {
        vm.loadSample()
    }
    return vm
}

struct EditorView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            EditorView(
                showSaveExporter: .constant(false),
                showOpenImporter: .constant(false)
            )
            .environmentObject(previewModel())
            .frame(width: 1100, height: 700)
            .previewDisplayName("EditorView — clean")

            EditorView(
                showSaveExporter: .constant(false),
                showOpenImporter: .constant(false)
            )
            .environmentObject(previewModel("""
            # Using H1 here

            Some preamble text.

            ## Good Slide

            Body content.

            ### Sub-heading

            More body.

            ##

            ## Empty Body Slide
            """))
            .frame(width: 1100, height: 700)
            .previewDisplayName("EditorView — with issues")
        }
    }
}

struct OutlinePane_Previews: PreviewProvider {
    static var previews: some View {
        OutlinePane()
            .environmentObject(previewModel())
            .frame(width: 240, height: 400)
            .previewDisplayName("OutlinePane")
    }
}

struct EditorPane_Previews: PreviewProvider {
    static var previews: some View {
        EditorPane()
            .environmentObject(previewModel())
            .frame(width: 500, height: 400)
            .previewDisplayName("EditorPane")
    }
}

struct PreviewPane_Previews: PreviewProvider {
    static var previews: some View {
        PreviewPane()
            .environmentObject(previewModel())
            .frame(width: 400, height: 500)
            .previewDisplayName("PreviewPane")
    }
}

struct PreviewSlideView_Previews: PreviewProvider {
    static var previews: some View {
        VStack {
            PreviewSlideView(
                slide: NoteSlide(id: 0, title: "Welcome", body: "Sample body text.", trailingWords: []),
                isCurrent: true
            )
            PreviewSlideView(
                slide: NoteSlide(id: 1, title: "Next", body: "More body text.", trailingWords: []),
                isCurrent: false
            )
        }
        .padding()
        .frame(width: 400)
        .previewDisplayName("PreviewSlideView")
    }
}

struct ValidationBar_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            ValidationBar(showSaveExporter: .constant(false))
                .environmentObject(previewModel())
                .frame(width: 900)
                .previewDisplayName("ValidationBar — clean")

            ValidationBar(showSaveExporter: .constant(false))
                .environmentObject(previewModel("""
                # H1 here
                ### Too deep
                ##
                """))
                .frame(width: 900)
                .previewDisplayName("ValidationBar — with issues")
        }
    }
}

struct IssueRow_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading) {
            IssueRow(issue: ValidationIssue(
                severity: .warning,
                message: "H1 heading on line 1 — only H2 is allowed.",
                lineRange: 1...1,
                fix: { $0 }
            ))
            IssueRow(issue: ValidationIssue(
                severity: .error,
                message: "Empty slide title on line 4.",
                lineRange: 4...4,
                fix: nil
            ))
        }
        .environmentObject(previewModel())
        .padding()
        .frame(width: 500)
        .previewDisplayName("IssueRow")
    }
}
#endif
