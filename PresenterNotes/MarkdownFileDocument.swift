//
//  MarkdownFileDocument.swift
//  PresenterNotes
//
//  A FileDocument used by `fileExporter` for Save As. We treat the file
//  as plain text (.md files generally UTI-conform to public.plain-text).
//

import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct MarkdownFileDocument: FileDocument {

    static var readableContentTypes: [UTType] {
        [.plainText]
    }

    static var writableContentTypes: [UTType] {
        [.plainText]
    }

    var text: String

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = string
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = Data(text.utf8)
        return FileWrapper(regularFileWithContents: data)
    }
}
