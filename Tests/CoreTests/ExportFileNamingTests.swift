import Foundation
import Testing
import LoudibleCore
import TestSupport

@Suite struct ExportFileNamingTests {
    @Test func usesTitleAndASIN() {
        #expect(ExportFileNaming.baseName(for: Audiobook(asin: "B0123", marketplace: .us, title: "Project Hail Mary")) == "Project Hail Mary [B0123]")
        #expect(ExportFileNaming.fileName(base: "X [B1]", attempt: 1) == "X [B1].m4b")
        #expect(ExportFileNaming.fileName(base: "X [B1]", attempt: 3) == "X [B1] (3).m4b")
    }

    @Test(arguments: [
        ("Dune: Part One", "Dune - Part One"),
        ("AC/DC \\ Live?", "AC_DC _ Live_"),
        ("A*B\"C<D>E|F", "A_B_C_D_E_F"),
        ("Line\nBreak\tTab", "Line Break Tab"),
        ("  .hidden title. ", "hidden title"),
        ("...", "Untitled"),
        ("", "Untitled"),
        ("Cafe\u{301}", "Café"),
    ])
    func sanitizesTitles(title: String, expected: String) {
        #expect(ExportFileNaming.sanitizedTitle(title) == expected)
    }

    @Test func sanitizesASIN() {
        #expect(ExportFileNaming.baseName(for: Audiobook(asin: "B0/../1", marketplace: .us, title: "T")) == "T [B01]")
    }

    @Test func longTitlesFitFileNameLimitWithCollisionSuffix() {
        let book = Audiobook(asin: "B000000001", marketplace: .us, title: String(repeating: "Ü", count: 400))
        let name = ExportFileNaming.fileName(base: ExportFileNaming.baseName(for: book), attempt: 9999)
        #expect(name.utf8.count <= 255)
        #expect(name.hasSuffix(" [B000000001] (9999).m4b"))
    }

    @Test func picksFirstFreeName() throws {
        let directory = try TemporaryDirectory("naming")
        defer { directory.cleanUp() }
        let base = "Book [B1]"
        for name in ["Book [B1].m4b", "Book [B1] (2).m4b"] {
            FileManager.default.createFile(atPath: directory.url.appendingPathComponent(name).path, contents: Data())
        }
        let url = ExportFileNaming.availableURL(in: directory.url, base: base) { FileManager.default.fileExists(atPath: $0.path) }
        #expect(url.lastPathComponent == "Book [B1] (3).m4b")
    }

    @Test func extensionParameter() {
        let book = Audiobook(asin: "B1", marketplace: .us, title: "X")
        #expect(ExportFileNaming.fileName(base: ExportFileNaming.baseName(for: book, extension: "aaxc"), attempt: 2, extension: "aaxc") == "X [B1] (2).aaxc")
        let long = Audiobook(asin: "B000000001", marketplace: .us, title: String(repeating: "Ü", count: 400))
        #expect(ExportFileNaming.fileName(base: ExportFileNaming.baseName(for: long, extension: "aaxc"), attempt: 9999, extension: "aaxc").utf8.count <= 255)
    }

    @Test(arguments: [
        ("Dune [B0123].aaxc", "B0123"),
        ("Dune [B0123] (2).aaxc", "B0123"),
        ("My copy of Dune [B0123] edited.aax", "B0123"),
        ("Dune [Book 1] [B0123].m4b", "B0123"),
        ("[B0123] [B0999].m4b", "B0999"),
    ])
    func findsASINInFileName(name: String, asin: String) {
        #expect(ExportFileNaming.asin(inFileName: name) == asin)
    }

    @Test(arguments: ["Dune.aaxc", "Dune [].aaxc", "Dune [B-12].aaxc", ".Dune [B0123].aaxc", ".Dune [B0123].abc.partial"])
    func findsNoASIN(name: String) {
        #expect(ExportFileNaming.asin(inFileName: name) == nil)
    }

    @Test func partialNamesAreHiddenAndFitTheLimit() {
        let token = UUID().uuidString
        let name = ExportFileNaming.partialName(base: String(repeating: "Ü", count: 200) + " [B1]", token: token)
        #expect(name.hasPrefix("."))
        #expect(name.hasSuffix(".\(token).partial"))
        #expect(name.utf8.count <= 255)
        #expect(ExportFileNaming.isPartial(name))
        #expect(!ExportFileNaming.isPartial("Book [B1].partial"))
        #expect(!ExportFileNaming.isPartial(".Book [B1].aaxc"))
    }
}
