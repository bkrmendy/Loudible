import Foundation
import FFmpegBridge
import LoudibleCore

/// Decrypts AAX/AAXC with FFmpeg's MOV demuxer and remuxes the compressed audio (no
/// re-encoding) and cover art into an M4B with the license's chapters and book metadata.
///
/// The work happens in `aex_remux_to_m4b` (FFmpegBridge) on a dedicated dispatch queue,
/// never on the caller's actor.
public struct FFmpegConverter: AudioConverter {
    private static let queue = DispatchQueue(label: "Loudible.FFmpegConverter", qos: .userInitiated)

    public init() {}

    /// libavformat version, e.g. "61.7.103".
    public static var libavformatVersion: String {
        let version = aex_libavformat_version()
        return "\(version >> 16).\((version >> 8) & 0xff).\(version & 0xff)"
    }

    /// The license FFmpeg was built under, e.g. "LGPL version 2.1 or later".
    public static var license: String {
        String(cString: aex_ffmpeg_license())
    }

    /// Required FFmpeg components missing from the loaded build; empty when complete.
    public static var missingComponents: [String] {
        var buffer = [CChar](repeating: 0, count: 256)
        guard aex_missing_components(&buffer, buffer.count) > 0 else { return [] }
        return String(nulTerminated: buffer).components(separatedBy: ", ")
    }

    public func convert(_ request: ConversionRequest, progress: @escaping @Sendable (Double) -> Void) async throws {
        let cancelFlag = CancelFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                Self.queue.async {
                    do {
                        try Self.remux(request, cancelFlag: cancelFlag, progress: progress)
                        continuation.resume()
                    } catch {
                        try? FileManager.default.removeItem(at: request.output)
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelFlag.set()
        }
    }

    private static func remux(
        _ request: ConversionRequest,
        cancelFlag: CancelFlag,
        progress: @escaping @Sendable (Double) -> Void) throws {
        let options: [(String, String)] = switch request.decryption {
        case .aaxc(let key, let iv): [("audible_key", key.hexString), ("audible_iv", iv.hexString)]
        case .aax(let activationBytes): [("activation_bytes", activationBytes.hexString)]
        }
        let chapters = request.chapters.filter { $0.lengthMilliseconds > 0 }
        let titles = chapters.enumerated().map { $1.title.isEmpty ? "Chapter \($0 + 1)" : $1.title }

        let strings = CStrings()
        let cOptions = options.map { aex_tag(key: strings[$0.0], value: strings[$0.1]) }
        let cMetadata = metadata(for: request.metadata).map { aex_tag(key: strings[$0.0], value: strings[$0.1]) }
        let cChapters = zip(chapters, titles).map {
            aex_chapter(start_ms: Int64($0.startMilliseconds), end_ms: Int64($0.endMilliseconds), title: strings[$1])
        }

        let progressBox = Unmanaged.passRetained(ProgressBox(progress))
        defer { progressBox.release() }
        var message = [CChar](repeating: 0, count: 512)

        let result = aex_remux_to_m4b(
            request.input.path, request.output.path,
            cOptions, Int32(cOptions.count),
            cChapters, Int32(cChapters.count),
            cMetadata, Int32(cMetadata.count),
            cancelFlag.pointer,
            { fraction, context in
                Unmanaged<ProgressBox>.fromOpaque(context!).takeUnretainedValue().report(fraction)
            },
            progressBox.toOpaque(),
            &message, message.count
        )
        guard result < 0 else { return }
        if result == aex_error_cancelled { throw ExporterError.cancelled }
        throw ExporterError.conversion(String(nulTerminated: message))
    }

    /// Book details written over the source's tags. An empty value removes the tag.
    static func metadata(for book: BookMetadata) -> [(String, String)] {
        let authors = book.authors.joined(separator: ", ")
        var tags: [(String, String)] = [
            ("title", book.title),
            ("album", book.title),
            ("genre", "Audiobook"),
            ("comment", "ASIN: \(book.asin)"),
        ]
        if !authors.isEmpty { tags += [("artist", authors), ("album_artist", authors)] }
        if !book.narrators.isEmpty { tags.append(("composer", book.narrators.joined(separator: ", "))) }
        if let subtitle = book.subtitle, !subtitle.isEmpty { tags.append(("description", subtitle)) }
        if let publisher = book.publisher, !publisher.isEmpty { tags.append(("copyright", publisher)) }
        if let date = book.releaseDate, !date.isEmpty { tags.append(("date", date)) }
        return tags
    }
}

/// Owns a C cancellation flag polled by FFmpeg's interrupt callback and the remux loop.
final class CancelFlag: @unchecked Sendable {
    let pointer: OpaquePointer

    init() { pointer = aex_cancel_flag_create() }
    deinit { aex_cancel_flag_destroy(pointer) }

    func set() { aex_cancel_flag_set(pointer) }
}

private final class ProgressBox {
    let report: (Double) -> Void
    init(_ report: @escaping (Double) -> Void) { self.report = report }
}

private extension String {
    /// Decodes a NUL-terminated UTF-8 buffer filled in by C.
    init(nulTerminated buffer: [CChar]) {
        self.init(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// C strings that live as long as this object.
private final class CStrings {
    private var storage: [UnsafeMutablePointer<CChar>] = []

    subscript(_ string: String) -> UnsafePointer<CChar> {
        let copy = strdup(string)!
        storage.append(copy)
        return UnsafePointer(copy)
    }

    deinit { storage.forEach { free($0) } }
}
