import Foundation

/// The kept encrypted downloads and their manifests.
///
/// The audio file in `folder` is the source of truth for "downloaded": a book is downloaded when a
/// non-hidden `.aax`/`.aaxc` whose name carries `[ASIN]` exists there. Manifests (`<ASIN>.json`,
/// plus the cover as `<ASIN>.cover`) live in `manifestFolder`, owner-only, and a manifest without
/// its audio file is an orphan to delete. An unfinished download kept to be continued is a hidden
/// file in `folder` plus its `PartialDownload` record (`<ASIN>.partial`) in `manifestFolder`.
public struct LocalDownloads: Sendable {
    public static let audioExtensions: Set<String> = ["aax", "aaxc"]

    public let folder: URL
    public let manifestFolder: URL
    private let trash: @Sendable (URL) throws -> Void

    /// - Parameter trash: moves a file to the Trash; tests replace it so they never touch the real one.
    public init(
        folder: URL,
        manifestFolder: URL,
        trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(
            at: $0,
            resultingItemURL: nil) }) {
        self.folder = folder
        self.manifestFolder = manifestFolder
        self.trash = trash
    }

    private var fileManager: FileManager { .default }

    /// Creates both folders if needed and checks that the download folder is writable.
    public func ensureFolder() throws(ExporterError) {
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            try fileManager.createDirectory(
                at: manifestFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw .fileSystem("Could not create \(folder.path): \(error.localizedDescription)")
        }
        guard fileManager.isWritableFile(atPath: folder.path) else {
            throw .fileSystem("\(folder.path) is not writable.")
        }
    }

    // MARK: Scanning

    /// Downloaded audio files by ASIN.
    public func scanDownloads() -> [String: URL] {
        scan(folder, extensions: Self.audioExtensions)
    }

    /// Exported M4B files in `exportFolder` by ASIN.
    public func scanExports(in exportFolder: URL) -> [String: URL] {
        scan(exportFolder, extensions: [ExportFileNaming.fileExtension])
    }

    /// Non-hidden regular files with one of `extensions` (any case), keyed by the ASIN in their
    /// name. With several matches the first in name order wins.
    private func scan(_ directory: URL, extensions: Set<String>) -> [String: URL] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )) ?? []
        var result: [String: URL] = [:]
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard extensions.contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let asin = ExportFileNaming.asin(inFileName: url.lastPathComponent),
                  result[asin] == nil
            else { continue }
            // Built from `directory` so the URL matches the configured folder (no /private prefix).
            result[asin] = directory.appendingPathComponent(url.lastPathComponent, isDirectory: false)
        }
        return result
    }

    // MARK: Manifests

    public func manifestURL(for asin: String) -> URL {
        manifestFolder.appendingPathComponent("\(asin).json", isDirectory: false)
    }

    /// The stored cover image, if one was saved.
    public func coverURL(for asin: String) -> URL? {
        let url = manifestFolder.appendingPathComponent("\(asin).cover", isDirectory: false)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// Every readable manifest. Unreadable ones are skipped, not deleted.
    public func manifests() -> [DownloadManifest] {
        manifestASINs().compactMap(manifest(for:))
    }

    public func manifest(for asin: String) -> DownloadManifest? {
        decode(DownloadManifest.self, from: manifestURL(for: asin))
    }

    /// Writes the manifest (and moves `coverFile`, if any, next to it). Both are created with
    /// mode 0600 and appear atomically, so no reader sees a half-written or world-readable file.
    public func writeManifest(_ manifest: DownloadManifest, coverFile: URL? = nil) throws(ExporterError) {
        let asin = manifest.book.asin
        do {
            try writePrivately(manifest, to: manifestURL(for: asin))

            if let coverFile, fileManager.fileExists(atPath: coverFile.path) {
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: coverFile.path)
                try replace(manifestFolder.appendingPathComponent("\(asin).cover"), with: coverFile)
            }
        } catch {
            throw .fileSystem("Could not save the download details: \(error.localizedDescription)")
        }
    }

    /// Writes `value` as JSON with mode 0600, atomically, creating the folder if needed.
    private func writePrivately(_ value: some Encodable, to destination: URL) throws {
        try fileManager.createDirectory(
            at: manifestFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let temporary = manifestFolder
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: temporary.path, contents: try encoder.encode(value), attributes: [.posixPermissions: 0o600]) else {
            throw ExporterError.fileSystem("Could not write \(temporary.path).")
        }
        try replace(destination, with: temporary)
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func replace(_ destination: URL, with source: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: source)
        } else {
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    public func removeManifest(asin: String) {
        try? fileManager.removeItem(at: manifestURL(for: asin))
        try? fileManager.removeItem(at: manifestFolder.appendingPathComponent("\(asin).cover"))
    }

    /// Deletes manifests whose ASIN is not in `keeping` (the downloaded books, plus any being
    /// downloaded right now). Returns the removed ASINs.
    @discardableResult
    public func removeOrphanedManifests(keeping: Set<String>) -> Set<String> {
        let orphans = Set(manifestASINs()).subtracting(keeping)
        orphans.forEach(removeManifest(asin:))
        return orphans
    }

    private func manifestASINs() -> [String] {
        let names = (try? fileManager.contentsOfDirectory(atPath: manifestFolder.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") && $0.hasSuffix(".json") }
            .map { String($0.dropLast(".json".count)) }
            .sorted()
    }

    // MARK: Cleanup

    /// Moves the book's audio file to the Trash and deletes its manifest and any unfinished
    /// download (which is not worth the Trash). Exports are not touched.
    public func trashDownload(asin: String) throws(ExporterError) {
        removePartialDownload(asin: asin)
        if let url = scanDownloads()[asin] {
            do {
                try trash(url)
            } catch {
                throw .fileSystem("Could not move \(url.lastPathComponent) to the Trash: \(error.localizedDescription)")
            }
        }
        removeManifest(asin: asin)
    }

    /// Removes what an interrupted run left behind, except the downloads kept to be continued:
    /// `.partial` files no record refers to, records whose file is gone, and the hidden
    /// temporary files (covers, half-written records) in the manifest folder.
    public func sweepPartials() {
        var kept = Set<String>()
        for record in partialDownloads() {
            let file = partialFileURL(for: record.book.asin)
            if fileManager.fileExists(atPath: file.path) {
                kept.insert(file.lastPathComponent)
            } else {
                try? fileManager.removeItem(at: partialRecordURL(for: record.book.asin))
            }
        }
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where ExportFileNaming.isPartial(name) && !kept.contains(name) {
            try? fileManager.removeItem(at: folder.appendingPathComponent(name))
        }
        let hidden = ((try? fileManager.contentsOfDirectory(atPath: manifestFolder.path)) ?? [])
            .filter { $0.hasPrefix(".") }
        for name in hidden where name.hasSuffix(".cover") || name.hasSuffix(".tmp") {
            try? fileManager.removeItem(at: manifestFolder.appendingPathComponent(name))
        }
    }

    // MARK: Unfinished downloads

    /// Where the bytes of the book's unfinished download are kept, in the download folder.
    public func partialFileURL(for asin: String) -> URL {
        folder.appendingPathComponent(ExportFileNaming.resumablePartialName(asin: asin), isDirectory: false)
    }

    private func partialRecordURL(for asin: String) -> URL {
        manifestFolder.appendingPathComponent("\(asin).partial", isDirectory: false)
    }

    public func partialDownload(for asin: String) -> PartialDownload? {
        decode(PartialDownload.self, from: partialRecordURL(for: asin))
    }

    /// Every readable record, whether or not its file still exists.
    public func partialDownloads() -> [PartialDownload] {
        let names = (try? fileManager.contentsOfDirectory(atPath: manifestFolder.path)) ?? []
        return names
            .filter { !$0.hasPrefix(".") && $0.hasSuffix(".partial") }
            .sorted()
            .compactMap { decode(PartialDownload.self, from: manifestFolder.appendingPathComponent($0)) }
    }

    /// Owner-only, like the manifests: the record names the account.
    public func writePartialDownload(_ record: PartialDownload) throws(ExporterError) {
        do {
            try writePrivately(record, to: partialRecordURL(for: record.book.asin))
        } catch {
            throw .fileSystem("Could not save the download progress: \(error.localizedDescription)")
        }
    }

    /// Deletes the record and the bytes.
    public func removePartialDownload(asin: String) {
        try? fileManager.removeItem(at: partialFileURL(for: asin))
        try? fileManager.removeItem(at: partialRecordURL(for: asin))
    }

    /// How much of the book's unfinished download is on disk, if one is kept and its size is known.
    public func partialProgress(for record: PartialDownload) -> TransferProgress? {
        let expected = record.checkpoint.expectedLength
        guard expected > 0,
              let size = (try? fileManager
              .attributesOfItem(atPath: partialFileURL(for: record.book.asin).path))?[.size] as? Int64
        else { return nil }
        return TransferProgress(bytesReceived: min(size, expected), bytesExpected: expected)
    }
}
