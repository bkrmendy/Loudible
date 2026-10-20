import Foundation

/// Downloads encrypted audio and persists application-owned recovery and metadata.
struct DownloadWorkflow: Sendable {
    struct Result: Sendable {
        let input: URL
        let freshLicense: ContentLicense?
    }

    let licenses: LicenseProvider
    let downloader: any FileDownloader
    let downloads: LocalDownloads
    let finalizer: ExportFileFinalizer
    private var fileManager: FileManager { .default }

    func run(
        book: Audiobook, kind: ExportJob.Kind, context: ExportExecutionContext) async throws(ExporterError) -> Result {
        if let existing = downloads.scanDownloads()[book.asin] {
            if kind == .download { await context.phase(.finalizing) }
            try context.checkCancellation()
            return Result(input: existing, freshLicense: nil)
        }
        await context.phase(.licensing)
        let (license, customerID) = try await licenses.fetch(for: book)
        try context.checkCancellation()
        let input = try await download(book: book, license: license, customerID: customerID, kind: kind,
            context: context)
        return Result(input: input, freshLicense: license)
    }

    /// Downloads into a hidden staging file, writes the manifest, then moves the file
    /// to `Title [ASIN].<ext>`. The license is always fresh, since its download URL expires.
    /// Failure or suspension keeps native recovery state; explicit cancellation discards it.
    private func download(
        book: Audiobook,
        license: ContentLicense,
        customerID: String,
        kind: ExportJob.Kind,
        context: ExportExecutionContext
    ) async throws(ExporterError) -> URL {
        let ext = license.decryption.fileExtension
        let partial = downloads.partialFileURL(for: book.asin)
        let cover = downloads.manifestFolder.appendingPathComponent(".\(book.asin).\(UUID().uuidString).cover")
        defer { try? fileManager.removeItem(at: cover) }

        let resumeData = try prepareRecovery(book: book, license: license, customerID: customerID)
        do throws(ExporterError) {
            await context.phase(.downloading)
            let downloads = self.downloads
            let invocation = UUID()
            await context.report(.beginDownload(invocation))
            do {
                try await self.downloader.download(
                    from: license.downloadURL, to: partial, resumeData: resumeData,
                    recovery: { recovery in
                        // A failed recovery write leaves the initial record to restart from zero.
                        try? downloads.writePartialDownload(PartialDownload(
                            book: book, customerID: customerID, fileExtension: ext, recovery: recovery,
                            decryption: license.decryption,
                            updatedAt: Date()))
                    },
                    progress: { value in Task { await context.report(.download(invocation, value)) } })
            } catch {
                await context.report(.endDownload(invocation))
                throw ExporterError.from(error)
            }
            await context.report(.endDownload(invocation))
            try context.checkCancellation()

            if kind == .download { await context.phase(.finalizing) }
            // The cover is a nicety for books that later leave the library; failing to get it is fine.
            if let coverURL = book.coverImageURL {
                try? await downloader.download(from: coverURL, to: cover, progress: { _ in })
            }
            try context.checkCancellation()
            return try finalize(book: book, license: license, cover: cover)
        } catch {
            if Task.isCancelled, !(await context.keepsRecovery()) { downloads.removePartialDownload(asin: book.asin) }
            throw error
        }
    }

    private func finalize(
        book: Audiobook, license: ContentLicense, cover: URL
    ) throws(ExporterError) -> URL {
        let ext = license.decryption.fileExtension
        let base = ExportFileNaming.baseName(for: book, extension: ext)
        let partial = downloads.partialFileURL(for: book.asin)
        let manifest = DownloadManifest(
            book: book,
            decryption: license.decryption,
            chapters: license.chapters,
            downloadedAt: Date())
        try downloads.writeManifest(manifest, coverFile: fileManager.fileExists(atPath: cover.path) ? cover : nil)
        let url: URL
        do {
            url = try finalizer.moveIntoPlace(partial, directory: downloads.folder, base: base, extension: ext)
        } catch {
            downloads.removeManifest(asin: book.asin)
            throw error
        }
        downloads.removePartialDownload(asin: book.asin)
        return url
    }

    private func prepareRecovery(
        book: Audiobook, license: ContentLicense, customerID: String
    ) throws(ExporterError) -> Data? {
        let ext = license.decryption.fileExtension
        var resumeData: Data?
        if let record = downloads.partialDownload(for: book.asin),
           record.customerID == customerID, record.book.asin == book.asin,
           record.fileExtension == ext, record.decryption == license.decryption {
            resumeData = record.recovery.resumeData
        } else {
            downloads.removePartialDownload(asin: book.asin)
        }
        try downloads.writePartialDownload(PartialDownload(
            book: book, customerID: customerID, fileExtension: ext, recovery: DownloadRecovery(),
            decryption: license.decryption, updatedAt: Date()))
        return resumeData
    }

}
