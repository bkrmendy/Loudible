import Foundation
import Testing
@testable import LoudibleAdapters
import LoudibleCore
import TestSupport

@Suite struct VoucherTests {
    struct Vector: Decodable {
        let voucher_base64: String, asin: String, derived_key: String, derived_iv: String
    }

    @Test func derivesKeyAndIVFromDeviceCustomerAndASIN() throws {
        let vector = try JSONDecoder().decode(Vector.self, from: Fixture.data("voucher-vector.json"))
        let (key, iv) = Voucher.derivedKeyAndIV(asin: vector.asin, session: Fixtures.session())
        #expect(key.hexString == vector.derived_key)
        #expect(iv.hexString == vector.derived_iv)
    }

    @Test func decryptsOpenSSLEncryptedVoucher() throws {
        let vector = try JSONDecoder().decode(Vector.self, from: Fixture.data("voucher-vector.json"))
        let contents = try Voucher.decrypt(vector.voucher_base64, asin: vector.asin, session: Fixtures.session())
        #expect(contents.key == Data(hexString: "0123456789abcdef0123456789abcdef"))
        #expect(contents.iv == Data(hexString: "fedcba9876543210fedcba9876543210"))
    }

    @Test func wrongCustomerCannotReadVoucher() throws {
        let vector = try JSONDecoder().decode(Vector.self, from: Fixture.data("voucher-vector.json"))
        var other = Fixtures.session()
        other.customerID = "amzn1.account.OTHER"
        #expect(throws: ExporterError.self) { try Voucher.decrypt(vector.voucher_base64, asin: vector.asin,
                session: other) }
    }

    @Test func rejectsMalformedVouchers() {
        #expect(throws: ExporterError.self) { try Voucher.decrypt("***", asin: "B1", session: Fixtures.session()) }
        #expect(throws: ExporterError.self) { try Voucher.decrypt(Data(count: 8).base64EncodedString(), asin: "B1",
                session: Fixtures.session()) }
        #expect(throws: ExporterError.self) { try Voucher.parse(Data(#"{"key":"zz"}"#.utf8), asin: "B1") }
    }

    @Test func toleratesPaddingAndTrailingBytes() throws {
        let contents = try Voucher.parse(Data(#"{"key":"0a0b0c0d"}"#.utf8) + Data([0, 0, 0]), asin: "B1")
        #expect(contents == Voucher.Contents(key: Data([10, 11, 12, 13]), iv: nil))
        let trailing = try Voucher.parse(Data(#"{"key":"0a0b0c0d"}garbage"#.utf8), asin: "B1")
        #expect(trailing.key == Data([10, 11, 12, 13]))
    }
}

@Suite struct LicenseTests {
    private func response(_ status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.audible.com/")!, statusCode: status, httpVersion: nil,
                        headerFields: nil)!
    }

    private func parse(_ fixture: String, asin: String, status: Int = 200) throws -> ContentLicense {
        try LicenseParser.license(from: Fixture.data(fixture), response: response(status), asin: asin,
                session: Fixtures.session())
    }

    @Test func buildsSignedLicenseRequest() async throws {
        let transport = MockTransport(status: 200, body: try Fixture.data("license-aaxc.json"))
        let api = AudibleHTTPAPI(transport: transport, random: SequentialRandom(), clock: TestClock())
        var session = try Fixture.signingSession(marketplace: .us)
        session.devicePrivateKey = try Fixture.string("synthetic-device-key.pem")
        _ = try? await api.license(for: "B000000001", marketplace: .us, session: session)

        let request = try #require(transport.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.audible.com/1.0/content/B000000001/licenserequest")
        #expect(request.value(forHTTPHeaderField: "x-adp-signature") != nil)
        let body = try #require(request.jsonBody)
        #expect(body["consumption_type"] as? String == "Download")
        #expect(body["quality"] as? String == "High")
        let features = try #require(body["supported_media_features"] as? [String: Any])
        #expect(features["drm_types"] as? [String] == ["Adrm"])
        #expect(features["chapter_titles_type"] as? String == "Tree")
        #expect((body["response_groups"] as? String)?.contains("chapter_info") == true)
    }

    @Test func requestsLicenseFromTheBooksStore() async throws {
        let transport = MockTransport(status: 200, body: try Fixture.data("license-aaxc.json"))
        let api = AudibleHTTPAPI(transport: transport, random: SequentialRandom(), clock: TestClock())
        var session = try Fixture.signingSession(marketplace: .us)
        session.devicePrivateKey = try Fixture.string("synthetic-device-key.pem")
        _ = try? await api.license(for: "B000000001", marketplace: .uk, session: session)

        let request = try #require(transport.lastRequest)
        #expect(request.url?.absoluteString == "https://api.audible.co.uk/1.0/content/B000000001/licenserequest")
        #expect(request.value(forHTTPHeaderField: "x-adp-signature") != nil)
    }

    @Test func parsesAAXCLicense() throws {
        let license = try parse("license-aaxc.json", asin: "B000000001")
        #expect(license.decryption == .aaxc(key: Data(hexString: "0123456789abcdef0123456789abcdef")!,
                iv: Data(hexString: "fedcba9876543210fedcba9876543210")!))
        #expect(license.downloadURL
            .absoluteString == "https://cds.audible.example/download/B000000001.aaxc?token=synthetic")
        #expect(license.runtimeMilliseconds == 185_000)
        #expect(license.codec == "mp4a.40.2")
        #expect(license.chapters == [
            Chapter(title: "Opening Credits", startMilliseconds: 0, lengthMilliseconds: 15_000),
            Chapter(title: "Part One", startMilliseconds: 15_000, lengthMilliseconds: 5_000),
            Chapter(title: "Chapter 1", startMilliseconds: 20_000, lengthMilliseconds: 60_000),
            Chapter(title: "Chapter 2", startMilliseconds: 80_000, lengthMilliseconds: 60_000),
            Chapter(title: "Chapter 3", startMilliseconds: 140_000, lengthMilliseconds: 45_000),
        ])
    }

    @Test func parsesLegacyAAXActivationBytes() throws {
        let license = try parse("license-aax.json", asin: "B000000002")
        #expect(license.decryption == .aax(activationBytes: Data([0x1c, 0xeb, 0x00, 0xda])))
    }

    @Test func missingKeyIsReported() {
        #expect(throws: ExporterError.missingDecryptionKey(asin: "B000000003")) {
            try parse("license-missing-key.json", asin: "B000000003")
        }
    }

    @Test func deniedLicenseNamesTheReason() {
        #expect(throws: ExporterError.licenseDenied(asin: "B000000005", reason: "Title is not owned by customer")) {
            try parse("license-denied.json", asin: "B000000005")
        }
        #expect(throws: ExporterError.licenseDenied(asin: "B1", reason: "Forbidden title")) {
            try LicenseParser.license(from: Data(#"{"message":"Forbidden title"}"#.utf8), response: response(403),
                asin: "B1", session: Fixtures.session())
        }
    }

    @Test func unsupportedDRMIsRejectedForTheTitle() {
        #expect(throws: ExporterError.unsupportedDRM(asin: "B000000004", drmType: "Widevine")) {
            try parse("license-widevine.json", asin: "B000000004")
        }
    }

    @Test func malformedLicensesAreRejected() throws {
        #expect(throws: ExporterError.self) {
            try LicenseParser.license(from: Data("{}".utf8), response: response(), asin: "B1",
                session: Fixtures.session())
        }
        #expect(throws: ExporterError.authenticationRequired) {
            try LicenseParser.license(from: Data(), response: response(401), asin: "B1", session: Fixtures.session())
        }
        var json = try Fixture.json("license-aaxc.json")
        var license = try #require(json["content_license"] as? [String: Any])
        var metadata = try #require(license["content_metadata"] as? [String: Any])
        metadata["content_url"] = ["offline_url": "http://insecure.example/file"]
        license["content_metadata"] = metadata
        json["content_license"] = license
        #expect(throws: ExporterError.malformedResponse("License for B000000001 has no download URL.")) {
            try LicenseParser.license(from: JSONSerialization.data(withJSONObject: json), response: response(),
                asin: "B000000001", session: Fixtures.session())
        }
    }
}

@Suite(.serialized) struct DownloadTests {
    let payload = Data((0..<200_000).map { UInt8($0 % 251) })

    @Test func downloadsCompleteFileWithProgress() async throws {
        let server = try LocalHTTPServer(reply: .body(payload))
        defer { server.stop() }
        let url = try await server.start()
        let directory = try TemporaryDirectory("download")
        defer { directory.cleanUp() }
        let destination = directory.url.appendingPathComponent("book.aaxc")
        let reported = Locked<[TransferProgress]>([])

        try await URLSessionFileDownloader()
            .download(from: url, to: destination) { value in reported.withLock { $0.append(value) } }

        #expect(try Data(contentsOf: destination) == payload)
        let expected = Int64(payload.count)
        #expect(reported.current.last == TransferProgress(bytesReceived: expected, bytesExpected: expected))
        #expect(reported.current.map(\.bytesReceived) == reported.current.map(\.bytesReceived).sorted())
    }

    @Test func truncatedResponseFailsAndKeepsWhatArrived() async throws {
        let server = try LocalHTTPServer(reply: .truncated(body: payload.prefix(50_000), declaredLength: payload.count))
        defer { server.stop() }
        let url = try await server.start()
        let directory = try TemporaryDirectory("download")
        defer { directory.cleanUp() }
        let destination = directory.url.appendingPathComponent("book.aaxc")

        await #expect(throws: ExporterError.self) {
            try await URLSessionFileDownloader().download(from: url, to: destination) { _ in }
        }
        #expect(try Data(contentsOf: destination) == payload.prefix(50_000))
    }

    @Test(arguments: [403, 404, 500])
    func httpFailureFailsAndLeavesNothing(status: Int) async throws {
        let server = try LocalHTTPServer(reply: .status(status))
        defer { server.stop() }
        let url = try await server.start()
        let directory = try TemporaryDirectory("download")
        defer { directory.cleanUp() }
        let destination = directory.url.appendingPathComponent("book.aaxc")

        await #expect(throws: ExporterError.download("HTTP \(status)")) {
            try await URLSessionFileDownloader().download(from: url, to: destination) { _ in }
        }
        #expect(directory.contents().isEmpty)
    }

    @Test func cancellationStopsDownloadAndKeepsWhatArrived() async throws {
        let server = try LocalHTTPServer(reply: .stall(body: payload.prefix(10_000), declaredLength: payload.count))
        defer { server.stop() }
        let url = try await server.start()
        let directory = try TemporaryDirectory("download")
        defer { directory.cleanUp() }
        let destination = directory.url.appendingPathComponent("book.aaxc")

        let checkpoints = Locked<[DownloadCheckpoint]>([])

        let task = Task {
            try await URLSessionFileDownloader().download(from: url, to: destination, resume: nil,
                checkpoint: { value in
                checkpoints.withLock { $0.append(value) } }, progress: { _ in })
        }
        // The server has answered with a partial body and now holds the connection open.
        try await waitUntil { server.requestCount == 1 }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: ExporterError.cancelled) { try await task.value }
        #expect(try Data(contentsOf: destination) == payload.prefix(10_000))
        // Flushed when the transfer stopped, so all of it can be continued.
        #expect(checkpoints.current.last == DownloadCheckpoint(expectedLength: Int64(payload.count), validator: .none,
                committedLength: 10_000))
    }

    @Test func alreadyCancelledTaskDoesNotConnect() async throws {
        let server = try LocalHTTPServer(reply: .body(payload))
        defer { server.stop() }
        let url = try await server.start()
        let directory = try TemporaryDirectory("download")
        defer { directory.cleanUp() }

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await URLSessionFileDownloader()
                .download(from: url, to: directory.url.appendingPathComponent("x")) { _ in }
        }
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(server.requestCount == 0)
        #expect(directory.contents().isEmpty)
    }

    // MARK: Resuming

    var total: Int64 { Int64(payload.count) }

    @Test func resumesWithRangeAndIfRange() async throws {
        let file = LocalHTTPServer.File(body: payload, etag: "\"v1\"")
        // Bytes after the committed length may not have survived a crash; they are rewritten.
        let existing = payload.prefix(80_000) + Data(repeating: 0, count: 5_000)
        let point = ResumePoint(committedLength: 80_000, expectedLength: total, validator: .etag("\"v1\""))

        let run = try await resume(file, existing: existing, from: point)

        #expect(run.result == payload)
        #expect(run.server.requests.map { $0["range"] } == ["bytes=80000-"])
        #expect(run.server.requests.first?["if-range"] == "\"v1\"")
        #expect(run.checkpoints.first == DownloadCheckpoint(expectedLength: total, validator: .etag("\"v1\""),
                committedLength: 80_000))
        #expect(run.checkpoints.last?.committedLength == total)
        #expect(run.progress.first.map(\.bytesReceived).map { $0 >= 80_000 } == true)
        #expect(run.progress.last == TransferProgress(bytesReceived: total, bytesExpected: total))
    }

    @Test func resumesWithLastModifiedOrSizeAlone() async throws {
        let date = "Wed, 14 Oct 2026 10:00:00 GMT"
        let byDate = try await resume(
            LocalHTTPServer.File(body: payload, lastModified: date), existing: payload.prefix(1_000),
            from: ResumePoint(committedLength: 1_000, expectedLength: total, validator: .lastModified(date))
        )
        #expect(byDate.result == payload)
        #expect(byDate.server.requests.map { $0["range"] } == ["bytes=1000-"])
        #expect(byDate.server.requests.first?["if-range"] == date)

        let bySize = try await resume(
            LocalHTTPServer.File(body: payload), existing: payload.prefix(1_000),
            from: ResumePoint(committedLength: 1_000, expectedLength: total, validator: .none)
        )
        #expect(bySize.result == payload)
        #expect(bySize.server.requests.map { $0["range"] } == ["bytes=1000-"])
        #expect(bySize.server.requests.first?["if-range"] == nil)
    }

    @Test func serverIgnoringRangeStartsOver() async throws {
        let run = try await resume(LocalHTTPServer.File(body: payload, etag: "\"v1\"", honorsRange: false),
                existing: Data(repeating: 7, count: 1_000),
                from: ResumePoint(committedLength: 1_000, expectedLength: total, validator: .etag("\"v1\"")))
        #expect(run.result == payload)
        #expect(run.server.requestCount == 1)
        #expect(run.checkpoints.first?.committedLength == 0)
    }

    @Test func changedFileStartsOver() async throws {
        // A server honouring If-Range sends the new file whole.
        let honest = try await resume(
            LocalHTTPServer.File(body: payload, etag: "\"v2\""), existing: Data(repeating: 7, count: 1_000),
            from: ResumePoint(committedLength: 1_000, expectedLength: total, validator: .etag("\"v1\""))
        )
        #expect(honest.result == payload)
        #expect(honest.server.requestCount == 1)

        // One that sends a range of the new file anyway is caught by the validator, and asked again.
        let broken = try await resume(LocalHTTPServer.File(body: payload, etag: "\"v2\"", ignoresIfRange: true),
                existing: Data(repeating: 7, count: 1_000),
                from: ResumePoint(committedLength: 1_000, expectedLength: total, validator: .etag("\"v1\"")))
        #expect(broken.result == payload)
        #expect(broken.server.requests.map { $0["range"] } == ["bytes=1000-", nil])
    }

    @Test func differentSizeWithoutValidatorStartsOver() async throws {
        let run = try await resume(
            LocalHTTPServer.File(body: payload), existing: Data(repeating: 7, count: 1_000),
            from: ResumePoint(committedLength: 1_000, expectedLength: total + 1, validator: .none)
        )
        #expect(run.result == payload)
        #expect(run.server.requests.map { $0["range"] } == ["bytes=1000-", nil])
    }

    @Test func unsatisfiableRangeStartsOver() async throws {
        let run = try await resume(
            LocalHTTPServer.File(body: payload, rangeStatus: 416), existing: payload.prefix(1_000),
            from: ResumePoint(committedLength: 1_000, expectedLength: total, validator: .none)
        )
        #expect(run.result == payload)
        #expect(run.server.requests.map { $0["range"] } == ["bytes=1000-", nil])
    }

    @Test func completeFileIsConfirmedByItsLastByte() async throws {
        let run = try await resume(
            LocalHTTPServer.File(body: payload, etag: "\"v1\""), existing: payload,
            from: ResumePoint(committedLength: total, expectedLength: total, validator: .etag("\"v1\""))
        )
        #expect(run.result == payload)
        #expect(run.server.requests.map { $0["range"] } == ["bytes=\(total - 1)-"])
    }

    @Test func checkpointsFollowFlushesDuringTheTransfer() async throws {
        let run = try await resume(LocalHTTPServer.File(body: payload, etag: "\"v1\"", pauseAfter: 60_000),
                existing: Data(),
                from: ResumePoint(committedLength: 0, expectedLength: total, validator: .etag("\"v1\"")),
                checkpointInterval: 50_000)
        #expect(run.result == payload)
        // On the response, once 50 000 bytes have arrived in the first part, and at the end.
        let committed = run.checkpoints.map(\.committedLength)
        #expect(committed.count >= 3)
        #expect(committed.first == 0 && committed.last == total)
        #expect(committed.dropFirst().first.map { $0 >= 50_000 && $0 <= 60_000 } == true)
        #expect(committed == committed.sorted())
    }

    @Test func droppedConnectionKeepsTheBytesAndTheirCheckpoint() async throws {
        let server = try LocalHTTPServer(reply: .file(LocalHTTPServer.File(body: payload, etag: "\"v1\"",
                dropAfter: 30_000)))
        defer { server.stop() }
        let url = try await server.start()
        let directory = try TemporaryDirectory("download")
        defer { directory.cleanUp() }
        let destination = directory.url.appendingPathComponent("book.aaxc")
        let checkpoints = Locked<[DownloadCheckpoint]>([])

        await #expect(throws: ExporterError.self) {
            try await URLSessionFileDownloader().download(from: url, to: destination, resume: nil,
                checkpoint: { value in
                checkpoints.withLock { $0.append(value) } }, progress: { _ in })
        }
        #expect(try Data(contentsOf: destination) == payload.prefix(30_000))
        #expect(checkpoints.current.last == DownloadCheckpoint(expectedLength: total, validator: .etag("\"v1\""),
                committedLength: 30_000))
    }
}
