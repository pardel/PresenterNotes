//
//  KeyCaptureView.swift
//  PresenterNotes
//
//  A transparent NSView bridge that captures global key events for the
//  app window. Presentation remotes typically emit Page Down / Page Up
//  or the right / left arrow keys, so we handle both.
//

import SwiftUI
import AppKit

struct KeyCaptureView: NSViewRepresentable {
    let onNext: () -> Void
    let onPrevious: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyCatcherNSView()
        view.onNext = onNext
        view.onPrevious = onPrevious
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let v = nsView as? KeyCatcherNSView {
            v.onNext = onNext
            v.onPrevious = onPrevious
            DispatchQueue.main.async {
                if v.window?.firstResponder !== v {
                    v.window?.makeFirstResponder(v)
                }
            }
        }
    }
}

#if DEBUG
struct KeyCaptureView_Previews: PreviewProvider {
    static var previews: some View {
        KeyCaptureView(onNext: {}, onPrevious: {})
            .frame(width: 300, height: 100)
            .overlay(Text("KeyCaptureView is invisible;\nfocus and press arrows.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary))
            .previewDisplayName("KeyCaptureView")
    }
}
#endif

private final class KeyCatcherNSView: NSView {
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        // Keycodes:
        //   123 = left arrow
        //   124 = right arrow
        //   125 = down arrow
        //   126 = up arrow
        //   121 = Page Down   (common remote "next")
        //   116 = Page Up     (common remote "previous")
        //    49 = Space       (common remote "next")
        //    51 = Delete      (often "previous" on remotes)
        //    36 = Return
        switch event.keyCode {
        case 124, 125, 121, 49, 36:
            onNext?()
        case 123, 126, 116, 51:
            onPrevious?()
        default:
            super.keyDown(with: event)
        }
    }
}
