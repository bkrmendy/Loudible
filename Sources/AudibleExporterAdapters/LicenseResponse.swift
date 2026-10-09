import CommonCrypto
import CryptoKit
import Foundation
import AudibleExporterCore

enum LicenseRequest {
    static func request(asin: String, marketplace: Marketplace) throws -> URLRequest {
        let body: [String: Any] = [
            "consumption_type": "Download",
            "supported_media_features": [
                "drm_types": ["Adrm"],
                "codecs": ["mp4a.40.2"],
                "chapter_titles_type": "Tree",
            ],
            "spatial": false,
            "quality": "High",
            "response_groups": "chapter_info,content_reference",
        ]
        var components = URLComponents()
        components.scheme = "https"
        components.host = marketplace.audibleAPIHost
        components.path = "/1.0/content/\(asin)/licenserequest"
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
}

enum LicenseParser {
    static func license(from data: Data, response: HTTPURLResponse, asin: String, session: AudibleSession) throws(ExporterError) -> ContentLicense {
        let json = JSON(data: data)
        if response.statusCode == 403 || response.statusCode == 404 {
            // Audible reports ownership problems as plain HTTP errors with a message.
            throw .licenseDenied(asin: asin, reason: json["message"].string ?? "HTTP \(response.statusCode)")
        }
        try AudibleAPIStatus.check(data: data, response: response)

        let license = json["content_license"]
        guard !license.isNull else { throw .malformedResponse("License response for \(asin) has no content_license.") }
        let status = license["status_code"].string
        guard status?.lowercased() == "granted" else {
            throw .licenseDenied(asin: asin, reason: license["message"].string ?? status ?? "unknown status")
        }

        let drmType = license["drm_type"].string
        guard drmType?.lowercased() == "adrm" else {
            throw .unsupportedDRM(asin: asin, drmType: drmType ?? "none")
        }
        guard let encryptedVoucher = license["license_response"].string else {
            throw .missingDecryptionKey(asin: asin)
        }
        let voucher = try Voucher.decrypt(encryptedVoucher, asin: asin, session: session)
        let decryption = try ContentLicense.decryption(asin: asin, drmType: drmType, key: voucher.key, iv: voucher.iv)

        let metadata = license["content_metadata"]
        guard let urlText = metadata["content_url"]["offline_url"].string, let url = URL(string: urlText), url.scheme == "https" else {
            throw .malformedResponse("License for \(asin) has no download URL.")
        }
        let chapterInfo = metadata["chapter_info"]
        return ContentLicense(
            asin: asin,
            decryption: decryption,
            downloadURL: url,
            chapters: flatten(chapterInfo["chapters"].array ?? []),
            runtimeMilliseconds: chapterInfo["runtime_length_ms"].int,
            codec: metadata["content_reference"]["codec"].string,
            contentFormat: metadata["content_reference"]["content_format"].string
        )
    }

    /// Flattens the chapter tree in playback order. A parent keeps its own (intro) segment
    /// as a chapter when it has one; zero-length entries are dropped.
    static func flatten(_ chapters: [JSON]) -> [Chapter] {
        var result: [Chapter] = []
        for chapter in chapters {
            if let start = chapter["start_offset_ms"].int, let length = chapter["length_ms"].int, length > 0 {
                result.append(Chapter(title: chapter["title"].string ?? "Chapter \(result.count + 1)", startMilliseconds: start, lengthMilliseconds: length))
            }
            result += flatten(chapter["chapters"].array ?? [])
        }
        return result.sorted { $0.startMilliseconds < $1.startMilliseconds }
    }
}

/// The license "voucher": AES-128-CBC encrypted JSON holding the content key and IV.
/// Key and IV are the halves of SHA-256(device type + device serial + customer id + ASIN).
enum Voucher {
    struct Contents: Equatable {
        let key: Data?
        let iv: Data?
    }

    static func decrypt(_ base64: String, asin: String, session: AudibleSession) throws(ExporterError) -> Contents {
        guard let ciphertext = Data(base64Encoded: base64), ciphertext.count >= kCCBlockSizeAES128 else {
            throw .malformedResponse("License voucher for \(asin) is not valid base64.")
        }
        let (key, iv) = derivedKeyAndIV(asin: asin, session: session)
        guard let plaintext = aes128CBCDecrypt(ciphertext, key: key, iv: iv) else {
            throw .malformedResponse("License voucher for \(asin) could not be decrypted.")
        }
        return try parse(plaintext, asin: asin)
    }

    static func derivedKeyAndIV(asin: String, session: AudibleSession) -> (key: Data, iv: Data) {
        let material = session.device.deviceType + session.device.serial + session.customerID + asin
        let digest = Data(SHA256.hash(data: Data(material.utf8)))
        return (digest.prefix(16), digest.suffix(16))
    }

    /// Decrypts without padding. Trailing bytes beyond the last whole block are ignored.
    static func aes128CBCDecrypt(_ ciphertext: Data, key: Data, iv: Data) -> Data? {
        let input = ciphertext.prefix(ciphertext.count - ciphertext.count % kCCBlockSizeAES128)
        var output = Data(count: input.count)
        var written = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            input.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(0),
                            keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                            inputBytes.baseAddress, input.count,
                            outputBytes.baseAddress, outputBytes.count, &written
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return output.prefix(written)
    }

    /// The plaintext is JSON padded with NULs; tolerate trailing garbage after the object.
    static func parse(_ plaintext: Data, asin: String) throws(ExporterError) -> Contents {
        var bytes = plaintext
        while bytes.last == 0 { bytes.removeLast() }
        if let end = bytes.lastIndex(of: UInt8(ascii: "}")) { bytes = bytes.prefix(through: end) }

        let json = JSON(data: bytes)
        guard json.dictionary != nil else {
            throw .malformedResponse("License voucher for \(asin) is not readable.")
        }
        func hex(_ field: String) throws(ExporterError) -> Data? {
            guard let text = json[field].string, !text.isEmpty else { return nil }
            guard let data = Data(hexString: text) else {
                throw .malformedResponse("License voucher for \(asin) has an invalid \(field).")
            }
            return data
        }
        return Contents(key: try hex("key"), iv: try hex("iv"))
    }
}
