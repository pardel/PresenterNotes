//
//  AppModeTests.swift
//  PresenterNotesTests
//

import XCTest
@testable import PresenterNotes

final class AppModeTests: XCTestCase {

    func test_allCases_presentAndEdit() {
        XCTAssertEqual(AppMode.allCases, [.present, .edit])
    }

    func test_labels() {
        XCTAssertEqual(AppMode.present.label, "Present")
        XCTAssertEqual(AppMode.edit.label, "Edit")
    }

    func test_symbolsAreNotEmpty() {
        for mode in AppMode.allCases {
            XCTAssertFalse(mode.symbol.isEmpty)
        }
    }

    func test_idEqualsRawValue() {
        XCTAssertEqual(AppMode.present.id, "present")
        XCTAssertEqual(AppMode.edit.id, "edit")
    }
}

final class MarkdownFileDocumentTests: XCTestCase {

    // We can't fabricate a FileDocument WriteConfiguration in tests
    // (its initializer is internal to SwiftUI), but we can verify that
    // the document stores and exposes its text correctly.

    func test_initStoresText() {
        let doc = MarkdownFileDocument(text: "## Hello\n\nBody.")
        XCTAssertEqual(doc.text, "## Hello\n\nBody.")
    }

    func test_initFromEmpty_hasEmptyText() {
        let doc = MarkdownFileDocument()
        XCTAssertEqual(doc.text, "")
    }

    func test_readableContentTypes_includesPlainText() {
        XCTAssertTrue(MarkdownFileDocument.readableContentTypes.contains(.plainText))
    }
}
