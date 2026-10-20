import Foundation

/// Converts a kept or newly downloaded book to an M4B.
struct BookExportWorkflow: Sendable {
    static let redownloadHint = "If this keeps failing, delete the download and download it again."
    let download: DownloadWorkflow
    let converter: any AudioConverter
    let finalizer: ExportFileFinalizer
    private var fileManager: FileManager { .default }

    func run(book: Audiobook, destination: URL, context: ExportExecutionContext) async throws(ExporterError) -> URL {
        let downloaded = try await download.run(book: book, kind: .export, context: context)
        let input = downloaded.input
        let license = downloaded.freshLicense
        let isKeptDownload = license == nil

        // Keys: from the license just used, else the manifest, else a fresh license.
        let decryption: ContentLicense.Decryption
        let chapters: [Chapter]
        if let license {
            (decryption, chapters) = (license.decryption, license.chapters)
        } else if let manifest = download.downloads.manifest(for: book.asin) {
            (decryption, chapters) = (manifest.decryption, manifest.chapters)
        } else {
            await context.phase(.licensing)
            let (fresh, _) = try await download.licenses.fetch(for: book)
            (decryption, chapters) = (fresh.decryption, fresh.chapters)
        }
        try context.checkCancellation()

        let base = ExportFileNaming.baseName(for: book)
        let partial = destination.appendingPathComponent(ExportFileNaming.partialName(
            base: base,
            token: UUID().uuidString))
        defer { try? fileManager.removeItem(at: partial) }

        await context.phase(.converting)
        let request = ConversionRequest(
            input: input, output: partial, decryption: decryption, chapters: chapters,
            metadata: BookMetadata(book: book))
        do throws(ExporterError) {
            do {
                try await converter
                    .convert(request, progress: { value in Task { await context.report(.conversion(value)) } })
            } catch { throw ExporterError.from(error) }
        } catch .conversion(let detail) where isKeptDownload {
            throw .conversion("\(detail) \(Self.redownloadHint)")
        }
        try context.checkCancellation()
        guard fileManager.fileExists(atPath: partial.path) else {
            throw .conversion("The converter did not produce an output file.")
        }

        await context.phase(.finalizing)
        try context.checkCancellation()
        return try finalizer
            .moveIntoPlace(partial, directory: destination, base: base, extension: ExportFileNaming.fileExtension)
    }

}
