import Foundation
import Testing
@testable import LoudibleCore
import TestSupport

@Suite struct ExportFileFinalizerTests {
    @Test func collisionsPreserveExistingFiles() throws {
        let directory = try TemporaryDirectory("finalizer")
        defer { directory.cleanUp() }
        let partial = directory.url.appendingPathComponent(".output.partial")
        let existing = directory.url.appendingPathComponent("Book.m4b")
        try Data("old".utf8).write(to: existing)
        try Data("new".utf8).write(to: partial)
        let output = try ExportFileFinalizer().moveIntoPlace(partial, directory: directory.url,
                                                           base: "Book", extension: "m4b")
        #expect(output.lastPathComponent == "Book (2).m4b")
        #expect(try Data(contentsOf: existing) == Data("old".utf8))
        #expect(try Data(contentsOf: output) == Data("new".utf8))
        #expect(!FileManager.default.fileExists(atPath: partial.path))
    }

    @Test func missingInputOrDirectoryFails() throws {
        let directory = try TemporaryDirectory("finalizer-failure")
        defer { directory.cleanUp() }
        let input = directory.url.appendingPathComponent("input")
        #expect(throws: ExporterError.self) {
            try ExportFileFinalizer().moveIntoPlace(input, directory: directory.url, base: "Book", extension: "m4b")
        }
        try Data().write(to: input)
        #expect(throws: ExporterError.self) {
            try ExportFileFinalizer().moveIntoPlace(input, directory: directory.url.appendingPathComponent("missing"),
                                                   base: "Book", extension: "m4b")
        }
    }
}
