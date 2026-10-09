import Foundation
import Testing
import AudibleExporterCore
import TestSupport

@Suite struct LibraryRulesTests {
    @Test func keepsOwnedBooks() {
        #expect(LibraryRules.exclusion(for: Fixtures.entry("B1")) == nil)
        #expect(LibraryRules.exclusion(for: Fixtures.entry("B1", deliveryType: "MultiPartBook", relationships: [
            ProductRelationship(asin: "B2", direction: .child, type: "component"),
        ])) == nil)
        #expect(LibraryRules.exclusion(for: Fixtures.entry("B1", relationships: [
            ProductRelationship(asin: "S1", direction: .parent, type: "series"),
        ])) == nil)
    }

    @Test func excludesPlusCatalogTitles() {
        #expect(LibraryRules.exclusion(for: Fixtures.entry("B1", isAYCE: true)) == .plusCatalog)
    }

    @Test func excludesPodcasts() {
        #expect(LibraryRules.exclusion(for: Fixtures.entry("B1", deliveryType: "PodcastEpisode", contentType: "Podcast")) == .podcast)
        #expect(LibraryRules.exclusion(for: Fixtures.entry("B1", contentType: "Podcast")) == .podcast)
        #expect(LibraryRules.exclusion(for: Fixtures.entry("B1", relationships: [
            ProductRelationship(asin: "P1", direction: .parent, type: "Episode"),
        ])) == .podcast)
    }

    @Test func excludesContainers() {
        #expect(LibraryRules.exclusion(for: Fixtures.entry("B1", deliveryType: "PodcastParent")) == .container)
        #expect(LibraryRules.exclusion(for: Fixtures.entry("B1", deliveryType: "PodcastSeason")) == .container)
        #expect(LibraryRules.exclusion(for: Fixtures.entry("B1", relationships: [
            ProductRelationship(asin: "E1", direction: .child, type: "episode"),
        ])) == .container)
        #expect(LibraryRules.exclusion(for: Fixtures.entry("B1", relationships: [
            ProductRelationship(asin: "S2", direction: .child, type: "season"),
        ])) == .container)
    }

    @Test func deduplicatesByASINKeepingFirst() {
        let books = LibraryRules.purchasedBooks(from: [
            Fixtures.entry("B1", title: "First"), Fixtures.entry("B2"), Fixtures.entry("B1", title: "Second"),
        ])
        #expect(books.map(\.asin) == ["B1", "B2"])
        #expect(books[0].title == "First")
    }
}

@Suite struct LibraryServiceTests {
    let api = MockAudibleAPI()
    let store = InMemoryCredentialStore(Fixtures.session())

    func service(pageSize: Int) async throws -> LibraryService {
        let auth = AuthenticationCoordinator(api: api, store: store, clock: TestClock())
        try await auth.restore()
        return LibraryService(api: api, auth: auth, pageSize: pageSize)
    }

    func script(_ pages: [[LibraryEntry]], totalCount: Int? = nil) {
        api.libraryHandler.withLock {
            $0 = { number, _, _ in LibraryPage(entries: number <= pages.count ? pages[number - 1] : [], totalCount: totalCount) }
        }
    }

    @Test func fetchesAllPagesUntilShortPage() async throws {
        script([[Fixtures.entry("B1"), Fixtures.entry("B2")], [Fixtures.entry("B3"), Fixtures.entry("B4")], [Fixtures.entry("B5")]])
        let books = try await service(pageSize: 2).fetchPurchasedBooks()
        #expect(books.map(\.asin) == ["B1", "B2", "B3", "B4", "B5"])
        #expect(api.requestedPages.current == [1, 2, 3])
    }

    @Test func fullLastPageNeedsOneEmptyPageWithoutTotal() async throws {
        script([[Fixtures.entry("B1"), Fixtures.entry("B2")]])
        _ = try await service(pageSize: 2).fetchPurchasedBooks()
        #expect(api.requestedPages.current == [1, 2])
    }

    @Test func totalCountStopsAfterLastFullPage() async throws {
        script([[Fixtures.entry("B1"), Fixtures.entry("B2")], [Fixtures.entry("B3"), Fixtures.entry("B4")]], totalCount: 4)
        let books = try await service(pageSize: 2).fetchPurchasedBooks()
        #expect(books.count == 4)
        #expect(api.requestedPages.current == [1, 2])
    }

    @Test func emptyLibrary() async throws {
        script([])
        #expect(try await service(pageSize: 2).fetchPurchasedBooks().isEmpty)
        #expect(api.requestedPages.current == [1])
    }

    @Test func repeatedPageTerminates() async throws {
        let page = [Fixtures.entry("B1"), Fixtures.entry("B2")]
        api.libraryHandler.withLock { $0 = { _, _, _ in LibraryPage(entries: page) } }
        let books = try await service(pageSize: 2).fetchPurchasedBooks()
        #expect(books.map(\.asin) == ["B1", "B2"])
        #expect(api.requestedPages.current == [1, 2])
    }

    @Test func overlappingPagesAreDeduplicated() async throws {
        script([[Fixtures.entry("B1"), Fixtures.entry("B2")], [Fixtures.entry("B2"), Fixtures.entry("B3")], [Fixtures.entry("B4")]])
        let books = try await service(pageSize: 2).fetchPurchasedBooks()
        #expect(books.map(\.asin) == ["B1", "B2", "B3", "B4"])
    }

    @Test func filtersExcludedEntriesAcrossPages() async throws {
        script([
            [Fixtures.entry("B1"), Fixtures.entry("P1", isAYCE: true)],
            [Fixtures.entry("E1", deliveryType: "PodcastEpisode", contentType: "Podcast")],
        ])
        #expect(try await service(pageSize: 2).fetchPurchasedBooks().map(\.asin) == ["B1"])
    }

    @Test func failingPageFailsTheFetch() async throws {
        api.libraryHandler.withLock {
            $0 = { number, _, _ in
                if number == 2 { throw ExporterError.http(status: 500, message: nil) }
                return LibraryPage(entries: [Fixtures.entry("B1"), Fixtures.entry("B2")])
            }
        }
        await #expect(throws: ExporterError.http(status: 500, message: nil)) {
            try await service(pageSize: 2).fetchPurchasedBooks()
        }
    }

    @Test func rejectedTokenIsRefreshedAndRetriedOnce() async throws {
        let calls = Locked(0)
        api.libraryHandler.withLock {
            $0 = { _, _, session in
                calls.withLock { $0 += 1 }
                guard session.accessToken == "new" else { throw ExporterError.authenticationRequired }
                return LibraryPage(entries: [Fixtures.entry("B1")])
            }
        }
        api.refreshHandler.withLock { $0 = { _ in Fixtures.session(accessToken: "new") } }
        #expect(try await service(pageSize: 2).fetchPurchasedBooks().map(\.asin) == ["B1"])
        #expect(calls.current == 2)
        #expect(api.refreshCount.current == 1)
    }

    @Test func persistentRejectionRequiresSignIn() async throws {
        api.libraryHandler.withLock { $0 = { _, _, _ in throw ExporterError.authenticationRequired } }
        api.refreshHandler.withLock { $0 = { _ in Fixtures.session(accessToken: "new") } }
        let auth = AuthenticationCoordinator(api: api, store: store, clock: TestClock())
        try await auth.restore()
        await #expect(throws: ExporterError.authenticationRequired) {
            try await LibraryService(api: api, auth: auth, pageSize: 2).fetchPurchasedBooks()
        }
        #expect(await auth.state == .reauthenticationRequired(.us))
    }
}

@Suite struct LibrarySearchTests {
    let books = [
        Audiobook(asin: "B1", title: "Les Misérables", authors: ["Victor Hugo"], narrators: ["Narrator One"]),
        Audiobook(asin: "B2", title: "Dune", subtitle: "Book One", authors: ["Frank Herbert"], seriesTitle: "Dune Chronicles"),
        Audiobook(asin: "B3", title: "Project Hail Mary", authors: ["Andy Weir"], narrators: ["Ray Porter"]),
    ]

    @Test func emptyQueryReturnsEverything() {
        #expect(LibrarySearch.filter(books, query: "  ").map(\.asin) == ["B1", "B2", "B3"])
    }

    @Test(arguments: [
        ("miserables", ["B1"]),
        ("HUGO", ["B1"]),
        ("ray porter", ["B3"]),
        ("chronicles", ["B2"]),
        ("book one", ["B2"]),
        ("b2", ["B2"]),
        ("dune weir", []),
        ("o", ["B1", "B2", "B3"]),
    ])
    func matchesAllTermsAcrossFields(query: String, expected: [String]) {
        #expect(LibrarySearch.filter(books, query: query).map(\.asin) == expected)
    }
}

@Suite struct LibrarySelectionTests {
    let books = (1...4).map { Fixtures.book("B\($0)") }

    @Test func togglesAndReportsInLibraryOrder() {
        var selection = LibrarySelection()
        selection.toggle("B3")
        selection.toggle("B1")
        selection.toggle("B2")
        selection.toggle("B2")
        #expect(selection.selectedBooks(in: books).map(\.asin) == ["B1", "B3"])
        #expect(selection.count == 2)
    }

    @Test func selectsAndDeselectsGroups() {
        var selection = LibrarySelection(["B4"])
        selection.select(Array(books.prefix(2)))
        #expect(selection.asins == ["B1", "B2", "B4"])
        selection.deselect([books[0], books[3]])
        #expect(selection.asins == ["B2"])
        selection.set("B3", selected: true)
        selection.clear()
        #expect(selection.isEmpty)
    }

    @Test func reconcilesAgainstRefreshedLibrary() {
        var selection = LibrarySelection(["B1", "B3", "GONE"])
        selection.reconcile(with: Array(books.prefix(2)))
        #expect(selection.asins == ["B1"])
    }
}
