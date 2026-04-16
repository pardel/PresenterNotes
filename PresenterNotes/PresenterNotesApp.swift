//
//  PresenterNotesApp.swift
//  PresenterNotes
//

import SwiftUI
import AppKit

@main
struct PresenterNotesApp: App {
    @StateObject private var viewModel = NotesViewModel()

    var body: some Scene {
        WindowGroup("Presenter Notes") {
            ContentView()
                .environmentObject(viewModel)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { viewModel.undo() }
                    .keyboardShortcut("z", modifiers: [.command])
                    .disabled(!viewModel.canUndo)
                Button("Redo") { viewModel.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!viewModel.canRedo)
            }
            CommandGroup(replacing: .newItem) {
                Button("New") { viewModel.newDocument() }
                    .keyboardShortcut("n", modifiers: [.command])
                Button("Open Markdown…") {
                    NotificationCenter.default.post(name: .openMarkdownRequested, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    NotificationCenter.default.post(name: .saveMarkdownRequested, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command])
                Button("Save As…") {
                    NotificationCenter.default.post(name: .saveAsMarkdownRequested, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .printItem) {
                Button("Print…") { Self.printMarkdown(viewModel.sourceText, orientation: .portrait) }
                    .keyboardShortcut("p", modifiers: [.command])
                Button("Print Landscape…") { Self.printMarkdown(viewModel.sourceText, orientation: .landscape) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
            }
            CommandMenu("Navigate") {
                Button("Next") {
                    if viewModel.presentStyle.usesParagraphs { viewModel.nextParagraph() }
                    else { viewModel.next() }
                }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Previous") {
                    if viewModel.presentStyle.usesParagraphs { viewModel.previousParagraph() }
                    else { viewModel.previous() }
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                Divider()
                Button("Present Mode") { viewModel.mode = .present }
                    .keyboardShortcut("1", modifiers: [.command])
                Button("Edit Mode") { viewModel.mode = .edit }
                    .keyboardShortcut("2", modifiers: [.command])
                Divider()
                Button("Load Sample") { viewModel.loadSample() }
            }
        }
    }
}

extension PresenterNotesApp {
    static func printMarkdown(_ text: String, orientation: NSPrintInfo.PaperOrientation) {
        let slides = NotesDocument.parse(text)
        guard !slides.isEmpty else { return }

        let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
        printInfo.orientation = orientation
        printInfo.topMargin = 36
        printInfo.bottomMargin = 36
        printInfo.leftMargin = 36
        printInfo.rightMargin = 36

        let pageWidth = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let pageHeight = printInfo.paperSize.height - printInfo.topMargin - printInfo.bottomMargin

        let printView = SlidesPrintView(
            slides: slides,
            pageSize: NSSize(width: pageWidth, height: pageHeight)
        )

        let op = NSPrintOperation(view: printView, printInfo: printInfo)
        op.showsPrintPanel = true
        op.showsProgressPanel = true
        op.run()
    }
}

private extension NSFont {
    func withTraits(_ traits: NSFontTraitMask) -> NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: traits)
    }
}

private class SlidesPrintView: NSView {
    let slides: [NoteSlide]
    let pageSize: NSSize

    init(slides: [NoteSlide], pageSize: NSSize) {
        self.slides = slides
        self.pageSize = pageSize
        super.init(frame: NSRect(
            x: 0, y: 0,
            width: pageSize.width,
            height: pageSize.height * CGFloat(slides.count)
        ))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: slides.count)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        let idx = page - 1
        return NSRect(
            x: 0,
            y: CGFloat(idx) * pageSize.height,
            width: pageSize.width,
            height: pageSize.height
        )
    }

    private static func attributedBody(
        _ body: String,
        font: NSFont,
        paragraphStyle: NSParagraphStyle
    ) -> NSAttributedString {
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle
        ]
        guard let md = try? AttributedString(
            markdown: body,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return NSAttributedString(string: body, attributes: baseAttrs)
        }
        let result = NSMutableAttributedString(md)
        let fullRange = NSRange(location: 0, length: result.length)
        result.addAttributes(baseAttrs, range: fullRange)
        let fontSize = font.pointSize
        result.enumerateAttributes(in: fullRange) { attrs, range, _ in
            let isBold = (attrs[.inlinePresentationIntent] as? InlinePresentationIntent)?.contains(.stronglyEmphasized) == true
            let isItalic = (attrs[.inlinePresentationIntent] as? InlinePresentationIntent)?.contains(.emphasized) == true
            if isBold && isItalic {
                result.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize, weight: .bold).withTraits(.italicFontMask), range: range)
            } else if isBold {
                result.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize, weight: .bold), range: range)
            } else if isItalic {
                result.addAttribute(.font, value: NSFont.systemFont(ofSize: fontSize, weight: .regular).withTraits(.italicFontMask), range: range)
            }
        }
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        for (idx, slide) in slides.enumerated() {
            let pageRect = NSRect(
                x: 0,
                y: CGFloat(idx) * pageSize.height,
                width: pageSize.width,
                height: pageSize.height
            )
            guard pageRect.intersects(dirtyRect) else { continue }

            var yOffset = pageRect.minY + 8

            // Slide number
            let numberAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let numberStr = NSAttributedString(string: "Slide \(idx + 1) of \(slides.count)", attributes: numberAttrs)
            numberStr.draw(at: NSPoint(x: pageRect.minX, y: yOffset))
            yOffset += 20

            // Title
            if let title = slide.title, !title.isEmpty {
                let titleAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 28, weight: .bold)
                ]
                let titleStr = NSAttributedString(string: title, attributes: titleAttrs)
                let titleRect = NSRect(x: pageRect.minX, y: yOffset, width: pageSize.width, height: 30)
                titleStr.draw(in: titleRect)
                yOffset += 36
            }

            // Body — parse inline markdown so bold/italic render in print
            let bodyStyle = NSMutableParagraphStyle()
            bodyStyle.lineSpacing = 4
            bodyStyle.paragraphSpacing = 8
            let bodyFont = NSFont.systemFont(ofSize: 17)
            let bodyStr = Self.attributedBody(slide.body, font: bodyFont, paragraphStyle: bodyStyle)
            let bodyRect = NSRect(
                x: pageRect.minX,
                y: yOffset,
                width: pageSize.width,
                height: pageRect.maxY - yOffset - 8
            )
            bodyStr.draw(in: bodyRect)
        }
    }
}

extension Notification.Name {
    static let openMarkdownRequested   = Notification.Name("PresenterNotes.openMarkdownRequested")
    static let saveMarkdownRequested   = Notification.Name("PresenterNotes.saveMarkdownRequested")
    static let saveAsMarkdownRequested = Notification.Name("PresenterNotes.saveAsMarkdownRequested")
}
