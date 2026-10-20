import Foundation

/// Output names: `Title [ASIN].m4b`, then `Title [ASIN] (2).m4b`, ... on collisions. Downloads use
/// the same scheme with their own extension (`Title [ASIN].aaxc`).
public enum ExportFileNaming {
    public static let fileExtension = "m4b"
    /// APFS/HFS+ limit on a file name, in UTF-8 bytes.
    static let maximumFileNameBytes = 255
    /// Room kept for a collision suffix such as " (9999)".
    static let collisionSuffixReserve = 7

    public static func baseName(for book: Audiobook, extension ext: String = fileExtension) -> String {
        let asin = book.asin.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let tail = " [\(asin.isEmpty ? "unknown" : asin)]"
        let budget = maximumFileNameBytes - tail.utf8.count - collisionSuffixReserve - ".\(ext)".utf8.count
        return truncated(sanitizedTitle(book.title), toUTF8Bytes: budget) + tail
    }

    /// Makes a title safe as a file name on macOS and other common file systems.
    public static func sanitizedTitle(_ title: String) -> String {
        var result = ""
        for character in title.precomposedStringWithCanonicalMapping {
            switch character {
            case ":":
                result += " - "
            case "/", "\\", "?", "*", "\"", "<", ">", "|":
                result += "_"
            case _ where character.unicodeScalars.allSatisfy({ CharacterSet.controlCharacters.contains($0) }):
                result += " "
            default:
                result.append(character)
            }
        }
        let collapsed = result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        // Leading dots would hide the file; trailing dots and spaces trip up other systems.
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    public static func fileName(base: String, attempt: Int, extension ext: String = fileExtension) -> String {
        attempt <= 1 ? "\(base).\(ext)" : "\(base) (\(attempt)).\(ext)"
    }

    /// The first `fileName(base:attempt:extension:)` in `directory` for which `exists` is false.
    public static func availableURL(
        in directory: URL, base: String, extension ext: String = fileExtension, exists: (URL) -> Bool) -> URL {
        var attempt = 1
        while true {
            let url = directory.appendingPathComponent(
                fileName(base: base, attempt: attempt, extension: ext),
                isDirectory: false)
            if !exists(url) { return url }
            attempt += 1
        }
    }

    /// The ASIN tagged in a file name: the last `[ALNUM]` group of the name without its extension.
    /// Matching on the tag rather than the whole name survives title changes and user renames.
    /// Hidden files never match.
    public static func asin(inFileName name: String) -> String? {
        guard !name.hasPrefix(".") else { return nil }
        let stem = (name as NSString).deletingPathExtension
        var found: String?
        var current: String?
        for character in stem {
            if character == "[" {
                current = ""
            } else if character == "]" {
                if let current, !current.isEmpty { found = current }
                current = nil
            } else if current != nil {
                if character.isASCII && (character.isLetter || character.isNumber) {
                    current?.append(character)
                } else {
                    current = nil
                }
            }
        }
        return found
    }

    /// Hidden name for a file still being written: `.<base>.<token>.partial`. The base is
    /// shortened if needed so the whole name stays within the file name limit.
    public static func partialName(base: String, token: String) -> String {
        let fixed = ".\(token).partial".utf8.count + 1
        return ".\(truncated(base, toUTF8Bytes: maximumFileNameBytes - fixed)).\(token).partial"
    }

    /// Hidden name for a download kept to be continued: `.<ASIN>.download.partial`. It depends on
    /// the ASIN only, so a later attempt finds it even if the title changed meanwhile.
    public static func resumablePartialName(asin: String) -> String {
        ".\(asin.filter { $0.isASCII && ($0.isLetter || $0.isNumber) }).download.partial"
    }

    /// Whether `name` is one of the names `partialName(base:token:)` or `resumablePartialName(asin:)` produces.
    public static func isPartial(_ name: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(".partial")
    }

    static func truncated(_ text: String, toUTF8Bytes limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var result = ""
        for character in text {
            if result.utf8.count + String(character).utf8.count > limit { break }
            result.append(character)
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }
}
