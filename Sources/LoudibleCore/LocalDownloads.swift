import Foundation

/// The kept encrypted downloads and their manifests.
///
/// The audio file in `folder` is the source of truth for "downloaded": a book is downloaded when a
/// non-hidden `.aax`/`.aaxc` whose name carries `[ASIN]` exists there. Manifests (`<ASIN>.json`,
/// plus the cover as `<ASIN>.cover`) live in `manifestFolder`, owner-only, and a manifest without
/// its audio file is an orphan to delete.
public struct LocalDownloads: Sendable {
    public static let audioExtensions: Set<String> = ["aax", "aaxc"]

    public let folder: URL
    public let manifestFolder: URL
    private let trash: @Sendable (URL) throws -> Void

    /// - Parameter trash: moves a file to the Trash; tests replace it so they never touch the real one.
    public init(
        folder: URL,
        manifestFolder: URL,
        trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
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
        guard let data = try? Data(contentsOf: manifestURL(for: asin)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DownloadManifest.self, from: data)
    }

    /// Writes the manifest (and moves `coverFile`, if any, next to it). Both are created with
    /// mode 0600 and appear atomically, so no reader sees a half-written or world-readable file.
    public func writeManifest(_ manifest: DownloadManifest, coverFile: URL? = nil) throws(ExporterError) {
        let asin = manifest.book.asin
        do {
            try fileManager.createDirectory(
                at: manifestFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let temporary = manifestFolder.appendingPathComponent(".\(asin).\(UUID().uuidString).tmp")
            guard fileManager.createFile(
                atPath: temporary.path, contents: try encoder.encode(manifest), attributes: [.posixPermissions: 0o600]
            ) else {
                throw ExporterError.fileSystem("Could not write \(temporary.path).")
            }
            try replace(manifestURL(for: asin), with: temporary)

            if let coverFile, fileManager.fileExists(atPath: coverFile.path) {
                try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: coverFile.path)
                try replace(manifestFolder.appendingPathComponent("\(asin).cover"), with: coverFile)
            }
        } catch {
            throw .fileSystem("Could not save the download details: \(error.localizedDescription)")
        }
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

    /// Moves the book's audio file to the Trash and deletes its manifest. Exports are not touched.
    public func trashDownload(asin: String) throws(ExporterError) {
        if let url = scanDownloads()[asin] {
            do {
                try trash(url)
            } catch {
                throw .fileSystem("Could not move \(url.lastPathComponent) to the Trash: \(error.localizedDescription)")
            }
        }
        removeManifest(asin: asin)
    }

    /// Removes leftover `.partial` files from an interrupted run. Nothing else is touched.
    public func sweepPartials() {
        let names = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where ExportFileNaming.isPartial(name) {
            try? fileManager.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}
