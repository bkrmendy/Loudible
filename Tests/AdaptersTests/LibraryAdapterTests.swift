import Foundation
import Testing
@testable import LoudibleAdapters
import LoudibleCore
import TestSupport

@Suite struct LibraryAdapterTests {
    private func response(status: Int = 200, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.audible.com/1.0/library")!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    @Test func buildsSignedLibraryRequest() async throws {
        let transport = MockTransport(status: 200, body: Data(#"{"items": []}"#.utf8))
        let api = AudibleHTTPAPI(transport: transport, random: SequentialRandom(), clock: TestClock())
        _ = try await api.libraryPage(3, pageSize: 50, marketplace: .canada, session: Fixture.signingSession(marketplace: .canada))

        let request = try #require(transport.lastRequest)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.host == "api.audible.ca")
        #expect(request.url?.path == "/1.0/library")
        #expect(request.queryItems["num_results"] == "50")
        #expect(request.queryItems["page"] == "3")
        #expect(request.queryItems["response_groups"]?.contains("relationships") == true)
        #expect(request.value(forHTTPHeaderField: "x-adp-token") == "{enc:synthetic-adp-token}")
        #expect(request.value(forHTTPHeaderField: "x-adp-signature")?.hasSuffix(":2027-01-15T08:00:00.000000Z") == true)
    }

    @Test func asksTheRequestedStoreNotTheSessionsOwn() async throws {
        let transport = MockTransport(status: 200, body: try Fixture.data("library-page.json"))
        let api = AudibleHTTPAPI(transport: transport, random: SequentialRandom(), clock: TestClock())
        let page = try await api.libraryPage(1, pageSize: 50, marketplace: .japan, session: Fixture.signingSession(marketplace: .us))

        let request = try #require(transport.lastRequest)
        #expect(request.url?.host == "api.audible.co.jp")
        #expect(request.value(forHTTPHeaderField: "x-adp-signature") != nil)
        #expect(!page.entries.isEmpty)
        #expect(page.entries.allSatisfy { $0.book.marketplace == .japan })
    }

    @Test func parsesItemsAndOptionalFields() throws {
        let page = try LibraryParser.page(from: Fixture.data("library-page.json"), response: response(headers: ["Total-Count": "42"]), marketplace: .uk)
        #expect(page.totalCount == 42)
        #expect(page.entries.map(\.book.asin) == ["B000000001", "B000000002", "B000000003", "B000000004", "B000000005", "B000000006"])

        let full = page.entries[0]
        #expect(full.book.title == "The Synthetic Novel")
        #expect(page.entries.allSatisfy { $0.book.marketplace == .uk })
        #expect(full.book.subtitle == "A Test Fixture")
        #expect(full.book.authors == ["Ada Author", "Bea Coauthor"])
        #expect(full.book.narrators == ["Nora Narrator"])
        #expect(full.book.seriesTitle == "Fixture Saga")
        #expect(full.book.publisher == "Example Audio")
        #expect(full.book.runtimeMinutes == 754)
        #expect(full.book.releaseDate == "2021-03-04")
        let purchased = try #require(full.book.purchaseDate)
        #expect(abs(purchased.timeIntervalSince(ISO8601DateFormatter().date(from: "2022-05-06T07:08:09Z")!) - 0.123) < 0.001)
        #expect(full.book.coverImageURL?.absoluteString == "https://m.media-amazon.example/images/I/synthetic._SL500_.jpg")
        #expect(full.contentDeliveryType == "SinglePartBook")
        #expect(full.isAYCE == false)
        #expect(full.relationships == [ProductRelationship(asin: "S1", direction: .parent, type: "series")])

        let minimal = page.entries[1]
        #expect(minimal.book == Audiobook(asin: "B000000002", marketplace: .uk, title: "Minimal Book"))
        #expect(minimal.contentDeliveryType == nil && minimal.isAYCE == nil && minimal.relationships.isEmpty)

        #expect(page.entries[2].isAYCE == true)
        #expect(page.entries[2].book.authors.isEmpty)

        let lenient = page.entries[5]
        #expect(lenient.book.title == "B000000006") // empty title falls back to the ASIN
        #expect(lenient.isAYCE == false)
        #expect(lenient.book.runtimeMinutes == 120)
        #expect(lenient.book.purchaseDate != nil)
    }

    @Test func appliesOwnershipRulesToParsedFixture() throws {
        let page = try LibraryParser.page(from: Fixture.data("library-page.json"), response: response(), marketplace: .us)
        #expect(LibraryRules.purchasedBooks(from: page.entries).map(\.asin) == ["B000000001", "B000000002", "B000000006"])
    }

    @Test func emptyLibrary() throws {
        let page = try LibraryParser.page(from: Data(#"{"items": [], "response_groups": []}"#.utf8), response: response(), marketplace: .us)
        #expect(page.entries.isEmpty)
        #expect(page.totalCount == nil)
    }

    @Test func mapsErrorResponses() {
        #expect(throws: ExporterError.authenticationRequired) {
            try LibraryParser.page(from: Data(), response: response(status: 401), marketplace: .us)
        }
        #expect(throws: ExporterError.http(status: 500, message: "Internal failure")) {
            try LibraryParser.page(from: Data(#"{"message": "Internal failure"}"#.utf8), response: response(status: 500), marketplace: .us)
        }
        #expect(throws: ExporterError.malformedResponse("Library response has no items.")) {
            try LibraryParser.page(from: Data("<html>".utf8), response: response(), marketplace: .us)
        }
    }

    @Test func unusableDeviceKeyRequiresSignIn() async throws {
        let transport = MockTransport(status: 200, body: Data(#"{"items": []}"#.utf8))
        let api = AudibleHTTPAPI(transport: transport, random: SequentialRandom(), clock: TestClock())
        await #expect(throws: ExporterError.authenticationRequired) {
            try await api.libraryPage(1, pageSize: 10, marketplace: .us, session: Fixtures.session())
        }
        #expect(transport.requests.current.isEmpty)
    }
}
