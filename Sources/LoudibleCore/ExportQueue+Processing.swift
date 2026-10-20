import Foundation

// MARK: Processing

extension ExportQueue {
    func process(_ id: UUID) async {
        guard let index = index(of: id) else { return }
        let job = snapshot.jobs[index]
        while true {
            do {
                let output = try await runOnce(id, job: job)
                update(id, to: .completed(output))
                return
            } catch .authenticationRequired {
                update(id, to: .waitingForAuthentication)
                await waitForAuthentication(id)
                if Task.isCancelled {
                    update(id, to: .cancelled)
                    return
                }
                // A paused job restarts from licensing, whatever phase it then skips to.
                update(id, to: .running(.licensing, progress: 0))
            } catch .cancelled {
                update(id, to: .cancelled)
                return
            } catch {
                if Task.isCancelled {
                    update(id, to: .cancelled)
                } else {
                    update(id, to: .failed("\(job.book.title): \(error.localizedDescription)"))
                }
                return
            }
        }
    }

    private func runOnce(_ id: UUID, job: ExportJob) async throws(ExporterError) -> URL {
        switch job.kind {
        case .download:
            return try await downloadOnce(id, book: job.book)
        case .export:
            guard let destination = exportDestinations[id] else { throw .unexpected("No export folder.") }
            return try await exportOnce(id, book: job.book, destination: destination)
        }
    }

    private func downloadOnce(_ id: UUID, book: Audiobook) async throws(ExporterError) -> URL {
        // There is no re-download: a kept file is the result.
        if let existing = downloads.scanDownloads()[book.asin] {
            update(id, to: .running(.finalizing, progress: 0))
            return existing
        }
        update(id, to: .running(.licensing, progress: 0))
        let (license, customerID) = try await fetchLicense(for: book)
        try checkCancellation()
        return try await download(id, book: book, license: license, customerID: customerID, kind: .download)
    }

    private func exportOnce(_ id: UUID, book: Audiobook, destination: URL) async throws(ExporterError) -> URL {
        var license: ContentLicense?
        let input: URL
        let isKeptDownload: Bool
        if let existing = downloads.scanDownloads()[book.asin] {
            input = existing
            isKeptDownload = true
        } else {
            update(id, to: .running(.licensing, progress: 0))
            let (fresh, customerID) = try await fetchLicense(for: book)
            try checkCancellation()
            input = try await download(id, book: book, license: fresh, customerID: customerID, kind: .export)
            license = fresh
            isKeptDownload = false
        }

        // Keys: from the license just used, else the manifest, else a fresh license.
        let decryption: ContentLicense.Decryption
        let chapters: [Chapter]
        if let license {
            (decryption, chapters) = (license.decryption, license.chapters)
        } else if let manifest = downloads.manifest(for: book.asin) {
            (decryption, chapters) = (manifest.decryption, manifest.chapters)
        } else {
            update(id, to: .running(.licensing, progress: 0))
            let (fresh, _) = try await fetchLicense(for: book)
            (decryption, chapters) = (fresh.decryption, fresh.chapters)
        }
        try checkCancellation()

        let base = ExportFileNaming.baseName(for: book)
        let partial = destination.appendingPathComponent(ExportFileNaming.partialName(
            base: base,
            token: UUID().uuidString))
        defer { try? fileManager.removeItem(at: partial) }

        update(id, to: .running(.converting, progress: 0))
        let request = ConversionRequest(
            input: input, output: partial, decryption: decryption, chapters: chapters,
            metadata: BookMetadata(book: book))
        do {
            try await perform {
                try await self.converter.convert(request, progress: self.progressHandler(id, .converting))
            }
        } catch .conversion(let detail) where isKeptDownload {
            throw .conversion("\(detail) \(Self.redownloadHint)")
        }
        try checkCancellation()
        guard fileManager.fileExists(atPath: partial.path) else {
            throw .conversion("The converter did not produce an output file.")
        }

        update(id, to: .running(.finalizing, progress: 0))
        return try moveIntoPlace(partial, directory: destination, base: base, extension: ExportFileNaming.fileExtension)
    }

    /// The license, and the account that got it.
    private func fetchLicense(for book: Audiobook) async throws(ExporterError) -> (ContentLicense, customerID: String) {
        let api = self.api
        return try await auth.withValidSession { session in
            (try await api.license(for: book.asin, marketplace: book.marketplace, session: session), session.customerID)
        }
    }

    /// Downloads into a hidden staging file, writes the manifest, then moves the file
    /// to `Title [ASIN].<ext>`. The license is always fresh, since its download URL expires.
    /// Failure or suspension keeps native recovery state; explicit cancellation discards it.
    private func download(
        _ id: UUID, book: Audiobook, license: ContentLicense, customerID: String, kind: ExportJob.Kind
    ) async throws(ExporterError) -> URL {
        let ext = license.decryption.fileExtension
        let base = ExportFileNaming.baseName(for: book, extension: ext)
        let partial = downloads.partialFileURL(for: book.asin)
        let cover = downloads.manifestFolder.appendingPathComponent(".\(book.asin).\(UUID().uuidString).cover")
        defer { try? fileManager.removeItem(at: cover) }

        let resumeData = try prepareRecovery(book: book, license: license, customerID: customerID)
        do throws(ExporterError) {
            update(id, to: .running(.downloading, progress: 0))
            let downloads = self.downloads
            try await perform {
                try await self.downloader.download(
                    from: license.downloadURL, to: partial, resumeData: resumeData,
                    recovery: { recovery in
                        // A failed recovery write leaves the initial record to restart from zero.
                        try? downloads.writePartialDownload(PartialDownload(
                            book: book, customerID: customerID, fileExtension: ext, recovery: recovery,
                            decryption: license.decryption,
                            updatedAt: Date()))
                    },
                    progress: self.downloadProgressHandler(id))
            }
            try checkCancellation()

            if kind == .download { update(id, to: .running(.finalizing, progress: 0)) }
            // The cover is a nicety for books that later leave the library; failing to get it is fine.
            if let coverURL = book.coverImageURL {
                try? await downloader.download(from: coverURL, to: cover, progress: { _ in })
            }
            try checkCancellation()
            let manifest = DownloadManifest(
                book: book,
                decryption: license.decryption,
                chapters: license.chapters,
                downloadedAt: Date())
            try downloads.writeManifest(manifest, coverFile: fileManager.fileExists(atPath: cover.path) ? cover : nil)
            let url: URL
            do {
                url = try moveIntoPlace(partial, directory: downloads.folder, base: base, extension: ext)
            } catch {
                downloads.removeManifest(asin: book.asin)
                throw error
            }
            downloads.removePartialDownload(asin: book.asin)
            return url
        } catch {
            if Task.isCancelled && !suspended.contains(id) { downloads.removePartialDownload(asin: book.asin) }
            throw error
        }
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

    /// Moves a finished file to the first free `Title [ASIN] (n).<ext>` name. `moveItem`
    /// refuses to overwrite, so a file appearing concurrently just bumps the suffix.
    private func moveIntoPlace(
        _ partial: URL,
        directory: URL,
        base: String,
        extension ext: String) throws(ExporterError) -> URL {
        var attempt = 1
        while attempt < 10_000 {
            let candidate = directory.appendingPathComponent(ExportFileNaming.fileName(
                base: base,
                attempt: attempt,
                extension: ext))
            if !fileManager.fileExists(atPath: candidate.path) {
                do {
                    try fileManager.moveItem(at: partial, to: candidate)
                    return candidate
                } catch {
                    guard fileManager.fileExists(atPath: candidate.path) else {
                        throw .fileSystem("Could not move the file into place: \(error.localizedDescription)")
                    }
                }
            }
            attempt += 1
        }
        throw .fileSystem("Too many files named \(base).")
    }

    private func perform(_ operation: () async throws -> Void) async throws(ExporterError) {
        do {
            try await operation()
        } catch {
            throw ExporterError.from(error)
        }
    }

    private func checkCancellation() throws(ExporterError) {
        if Task.isCancelled { throw .cancelled }
    }

    private nonisolated func progressHandler(_ id: UUID, _ phase: ExportJob.Phase) -> @Sendable (Double) -> Void {
        { [weak self] progress in
            Task { await self?.reportProgress(id, phase, progress) }
        }
    }

    private nonisolated func downloadProgressHandler(_ id: UUID) -> @Sendable (TransferProgress) -> Void {
        { [weak self] transferred in
            Task { await self?.reportProgress(id, .downloading, transferred.fraction, transferred: transferred) }
        }
    }

    private func reportProgress(
        _ id: UUID,
        _ phase: ExportJob.Phase,
        _ progress: Double,
        transferred: TransferProgress? = nil) {
        guard let index = index(of: id),
              case .running(let currentPhase, let current) = snapshot.jobs[index].state,
              currentPhase == phase,
              progress >= 1 || progress - current >= 0.005
        else { return }
        update(id, to: .running(phase, progress: min(max(progress, 0), 1)), transferred: transferred)
    }

    func index(of id: UUID) -> Int? {
        snapshot.jobs.firstIndex { $0.id == id }
    }

    func update(_ id: UUID, to state: ExportJob.State, transferred: TransferProgress? = nil) {
        guard let index = index(of: id) else { return }
        // Late or out-of-order progress reports are invalid transitions and simply dropped.
        try? snapshot.jobs[index].transition(to: state, transferred: transferred)
    }

    // MARK: Authentication pause

    private func waitForAuthentication(_ id: UUID) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    authenticationWaiters[id] = continuation
                    snapshot.isWaitingForAuthentication = true
                }
            }
        } onCancel: {
            Task { await self.wakeAuthenticationWaiter(id) }
        }
    }

    private func wakeAuthenticationWaiter(_ id: UUID) {
        authenticationWaiters.removeValue(forKey: id)?.resume()
        if authenticationWaiters.isEmpty {
            snapshot.isWaitingForAuthentication = false
            schedule()
        }
    }
}
