import Foundation
import SwiftUI
import Testing
@testable import LoudibleApp
@testable import TestSupport

@MainActor
@Suite struct PreviewGalleryTests {
    @Test func definitionsBelongToTheirViewFiles() throws {
        let previews = try Snapshot.selected()
        #expect(previews.count == 50)
        #expect(Set(previews.map(\.id)).count == previews.count)
        #expect(Set(previews.map { $0.source.lastPathComponent }) == [
            "AccountViews.swift", "BookTile.swift", "LibraryViews.swift", "LoginSheet.swift", "ContentView.swift",
        ])
        let tiles = try Snapshot.selected(file: "BookTile.swift")
        #expect(tiles.count == 16)
        #expect(tiles.allSatisfy { $0.id.hasPrefix("tile") })
        #expect(try Snapshot.selected(states: ["tileSelected"]).map(\.id) == ["tileSelected"])
    }

    @Test func invalidFiltersFailInsteadOfRenderingEverything() {
        #expect(throws: (any Error).self) { try Snapshot.selected(file: "Missing.swift") }
        #expect(throws: (any Error).self) { try Snapshot.selected(states: ["missing"]) }
        #expect(throws: (any Error).self) { try Snapshot.selected(file: "BookTile.swift", states: ["windowLibrary"]) }
        #expect(throws: (any Error).self) { try Snapshot.selected(states: []) }
    }

    @Test func galleryUsesSiblingFoldersAndPortableEscapedLinks() {
        let source = URL(fileURLWithPath: "/checkout/Sources/BookTile.swift")
        let folder = PreviewGallery.folder(for: source, root: nil)
        #expect(folder.path == "/checkout/Sources/BookTile-Previews")
        #expect(PreviewGallery.folder(for: source, root: URL(fileURLWithPath: "/tmp/output")).path ==
            "/tmp/output/BookTile-Previews")
        let preview = ViewPreview("tileSelected", "Selected <book> & \"cover\"", width: 200, height: 280) {
            Text("Synthetic")
        }
        let html = PreviewGallery.html(source: source, previews: [preview])
        #expect(html.contains("<h1>BookTile.swift</h1>"))
        #expect(html.contains("src=\"images/tileSelected.png\""))
        #expect(html.contains("Selected &lt;book&gt; &amp; &quot;cover&quot;"))
        #expect(!html.contains("/checkout"))
        #expect(!html.contains("<script"))
    }
}
