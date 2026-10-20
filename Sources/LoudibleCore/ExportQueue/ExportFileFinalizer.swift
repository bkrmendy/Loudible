import Foundation

/// Places completed files without overwriting existing files.
struct ExportFileFinalizer: Sendable {
    private var fileManager: FileManager { .default }

    /// Moves a finished file to the first free `Title [ASIN] (n).<ext>` name. `moveItem`
    /// refuses to overwrite, so a file appearing concurrently just bumps the suffix.
    func moveIntoPlace(
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

}
