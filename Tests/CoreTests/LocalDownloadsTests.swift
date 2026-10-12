import Foundation
import Testing
import LoudibleCore
import TestSupport

@Suite struct LocalDownloadsTests {
    let root: TemporaryDirectory
    let trashed = Locked<[String]>([])
    let downloads: LocalDownloads

    init() throws {
        root = try TemporaryDirectory("local-downloads")
        let trashed = self.trashed
        downloads = LocalDownloads(
            folder: root.url.appendingPathComponent("Downloads", isDirectory: true),
            manifestFolder: root.url.appendingPathComponent("Manifests", isDirectory: true),
            trash: { url in
                trashed.withLock { $0.append(url.lastPathComponent) }
                try FileManager.default.removeItem(at: url)
            }
        )
        try downloads.ensureFolder()
    }

    func touch(_ name: String, in folder: URL? = nil) throws {
        try Data("x".utf8).write(to: (folder ?? downloads.folder).appendingPathComponent(name))
    }

    func manifest(_ asin: String) -> DownloadManifest {
        DownloadManifest(
            book: Fixtures.book(asin), decryption: .aaxc(key: Data(repeating: 1, count: 16), iv: Data(repeating: 2, count: 16)),
            chapters: [Chapter(title: "One", startMilliseconds: 0, lengthMilliseconds: 10)], downloadedAt: Fixtures.referenceDate
        )
    }

    func manifestFiles() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: downloads.manifestFolder.path)) ?? []).sorted()
    }

    @Test func scanMatchesOnTheASINTagOnly() throws {
        defer { root.cleanUp() }
        try touch("Renamed by me [B1].aaxc")
        try touch("Old [B2].AAX")
        try touch(".Hidden [B3].aaxc")
        try touch(".Book [B4].1234.partial")
        try touch("Notes [B5].txt")
        try touch("Exported [B6].m4b")
        try touch("No tag.aaxc")
        try FileManager.default.createDirectory(at: downloads.folder.appendingPathComponent("Folder [B7].aaxc"), withIntermediateDirectories: true)

        let found = downloads.scanDownloads()
        #expect(found.keys.sorted() == ["B1", "B2"])
        #expect(found["B1"]?.lastPathComponent == "Renamed by me [B1].aaxc")
    }

    @Test func duplicatesResolveInNameOrder() throws {
        defer { root.cleanUp() }
        try touch("Book [B1] (2).aaxc")
        try touch("Book [B1].aaxc")
        try touch("A copy [B1].aax")
        #expect(downloads.scanDownloads()["B1"]?.lastPathComponent == "A copy [B1].aax")
    }

    @Test func scansExportsInTheGivenFolder() throws {
        defer { root.cleanUp() }
        let exports = root.url.appendingPathComponent("Exports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        try touch("Book [B1].m4b", in: exports)
        try touch("Book [B2].aaxc", in: exports)
        #expect(downloads.scanExports(in: exports).keys.sorted() == ["B1"])
        #expect(downloads.scanExports(in: root.url.appendingPathComponent("missing")).isEmpty)
    }

    @Test func manifestRoundTripIsOwnerOnly() throws {
        defer { root.cleanUp() }
        let cover = root.url.appendingPathComponent("cover.tmp")
        try Data("png".utf8).write(to: cover)
        try downloads.writeManifest(manifest("B1"), coverFile: cover)

        #expect(downloads.manifest(for: "B1") == manifest("B1"))
        #expect(downloads.manifests() == [manifest("B1")])
        #expect(manifestFiles() == ["B1.cover", "B1.json"])
        for name in manifestFiles() {
            let attributes = try FileManager.default.attributesOfItem(atPath: downloads.manifestFolder.appendingPathComponent(name).path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "\(name)")
        }
        #expect(try Data(contentsOf: #require(downloads.coverURL(for: "B1"))) == Data("png".utf8))

        // Writing again replaces it.
        var updated = manifest("B1")
        updated.chapters = []
        try downloads.writeManifest(updated)
        #expect(downloads.manifest(for: "B1")?.chapters == [])
    }

    @Test func orphanedManifestsAreRemoved() throws {
        defer { root.cleanUp() }
        try downloads.writeManifest(manifest("B1"))
        try downloads.writeManifest(manifest("B2"))
        let removed = downloads.removeOrphanedManifests(keeping: ["B1"])
        #expect(removed == ["B2"])
        #expect(manifestFiles() == ["B1.json"])
    }

    @Test func trashMovesTheAudioAndDeletesTheManifestOnly() throws {
        defer { root.cleanUp() }
        try touch("Book [B1].aaxc")
        try touch("Book [B1].m4b")
        try downloads.writeManifest(manifest("B1"))
        try downloads.trashDownload(asin: "B1")
        #expect(trashed.current == ["Book [B1].aaxc"])
        #expect(downloads.scanDownloads().isEmpty)
        #expect(manifestFiles().isEmpty)
        #expect(FileManager.default.fileExists(atPath: downloads.folder.appendingPathComponent("Book [B1].m4b").path))
    }

    @Test func sweepRemovesOnlyPartials() throws {
        defer { root.cleanUp() }
        try touch(".Book [B1].1234.partial")
        try touch("Book [B1].partial")
        try touch(".DS_Store")
        try touch("Book [B2].aaxc")
        downloads.sweepPartials()
        let left = try FileManager.default.contentsOfDirectory(atPath: downloads.folder.path).sorted()
        #expect(left == [".DS_Store", "Book [B1].partial", "Book [B2].aaxc"])
    }
}
