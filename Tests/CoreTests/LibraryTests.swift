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

    @Test func mergeAppendsNewTitlesAndKeepsTheFirstCopy() {
        let home = [Fixtures.book("B1", title: "Home"), Fixtures.book("B2")]
        let other = [Fixtures.book("B3", marketplace: .uk), Fixtures.book("B1", title: "Other", marketplace: .uk)]
        let merged = LibraryRules.merge(home, other)
        #expect(merged.map(\.asin) == ["B1", "B2", "B3"])
        #expect(merged[0].title == "Home" && merged[0].marketplace == .us)
        #expect(merged[2].marketplace == .uk)
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
            $0 = { number, _, _, _ in LibraryPage(entries: number <= pages.count ? pages[number - 1] : [], totalCount: totalCount) }
        }
    }

    @Test func fetchesAllPagesUntilShortPage() async throws {
        script([[Fixtures.entry("B1"), Fixtures.entry("B2")], [Fixtures.entry("B3"), Fixtures.entry("B4")], [Fixtures.entry("B5")]])
        let books = try await service(pageSize: 2).fetchPurchasedBooks(in: .us)
        #expect(books.map(\.asin) == ["B1", "B2", "B3", "B4", "B5"])
        #expect(api.requestedPages.current == [1, 2, 3])
    }

    @Test func fullLastPageNeedsOneEmptyPageWithoutTotal() async throws {
        script([[Fixtures.entry("B1"), Fixtures.entry("B2")]])
        _ = try await service(pageSize: 2).fetchPurchasedBooks(in: .us)
        #expect(api.requestedPages.current == [1, 2])
    }

    @Test func totalCountStopsAfterLastFullPage() async throws {
        script([[Fixtures.entry("B1"), Fixtures.entry("B2")], [Fixtures.entry("B3"), Fixtures.entry("B4")]], totalCount: 4)
        let books = try await service(pageSize: 2).fetchPurchasedBooks(in: .us)
        #expect(books.count == 4)
        #expect(api.requestedPages.current == [1, 2])
    }

    @Test func emptyLibrary() async throws {
        script([])
        #expect(try await service(pageSize: 2).fetchPurchasedBooks(in: .us).isEmpty)
        #expect(api.requestedPages.current == [1])
    }

    @Test func repeatedPageTerminates() async throws {
        let page = [Fixtures.entry("B1"), Fixtures.entry("B2")]
        api.libraryHandler.withLock { $0 = { _, _, _, _ in LibraryPage(entries: page) } }
        let books = try await service(pageSize: 2).fetchPurchasedBooks(in: .us)
        #expect(books.map(\.asin) == ["B1", "B2"])
        #expect(api.requestedPages.current == [1, 2])
    }

    @Test func overlappingPagesAreDeduplicated() async throws {
        script([[Fixtures.entry("B1"), Fixtures.entry("B2")], [Fixtures.entry("B2"), Fixtures.entry("B3")], [Fixtures.entry("B4")]])
        let books = try await service(pageSize: 2).fetchPurchasedBooks(in: .us)
        #expect(books.map(\.asin) == ["B1", "B2", "B3", "B4"])
    }

    @Test func filtersExcludedEntriesAcrossPages() async throws {
        script([
            [Fixtures.entry("B1"), Fixtures.entry("P1", isAYCE: true)],
            [Fixtures.entry("E1", deliveryType: "PodcastEpisode", contentType: "Podcast")],
        ])
        #expect(try await service(pageSize: 2).fetchPurchasedBooks(in: .us).map(\.asin) == ["B1"])
    }

    @Test func failingPageFailsTheFetch() async throws {
        api.libraryHandler.withLock {
            $0 = { number, _, _, _ in
                if number == 2 { throw ExporterError.http(status: 500, message: nil) }
                return LibraryPage(entries: [Fixtures.entry("B1"), Fixtures.entry("B2")])
            }
        }
        await #expect(throws: ExporterError.http(status: 500, message: nil)) {
            try await service(pageSize: 2).fetchPurchasedBooks(in: .us)
        }
    }

    @Test func rejectedTokenIsRefreshedAndRetriedOnce() async throws {
        let calls = Locked(0)
        api.libraryHandler.withLock {
            $0 = { _, _, _, session in
                calls.withLock { $0 += 1 }
                guard session.accessToken == "new" else { throw ExporterError.authenticationRequired }
                return LibraryPage(entries: [Fixtures.entry("B1")])
            }
        }
        api.refreshHandler.withLock { $0 = { _ in Fixtures.session(accessToken: "new") } }
        #expect(try await service(pageSize: 2).fetchPurchasedBooks(in: .us).map(\.asin) == ["B1"])
        #expect(calls.current == 2)
        #expect(api.refreshCount.current == 1)
    }

    @Test func persistentRejectionRequiresSignIn() async throws {
        api.libraryHandler.withLock { $0 = { _, _, _, _ in throw ExporterError.authenticationRequired } }
        api.refreshHandler.withLock { $0 = { _ in Fixtures.session(accessToken: "new") } }
        let auth = AuthenticationCoordinator(api: api, store: store, clock: TestClock())
        try await auth.restore()
        await #expect(throws: ExporterError.authenticationRequired) {
            try await LibraryService(api: api, auth: auth, pageSize: 2).fetchPurchasedBooks(in: .us)
        }
        #expect(await auth.state == .reauthenticationRequired(.us))
    }
}

@Suite struct MarketplaceScanTests {
    let api = MockAudibleAPI()
    let store = InMemoryCredentialStore(Fixtures.session())
    let clock = TestClock()

    func makeService() async throws -> (LibraryService, AuthenticationCoordinator) {
        let auth = AuthenticationCoordinator(api: api, store: store, clock: clock)
        try await auth.restore()
        return (LibraryService(api: api, auth: auth, pageSize: 100), auth)
    }

    /// Each store's ASINs; stores not listed are empty.
    func script(_ libraries: [Marketplace: [String]]) {
        api.libraryHandler.withLock {
            $0 = { _, _, marketplace, _ in
                LibraryPage(entries: (libraries[marketplace] ?? []).map { Fixtures.entry($0, marketplace: marketplace) })
            }
        }
    }

    func scans(_ service: LibraryService, excluding home: Marketplace = .us) async -> [MarketplaceScan] {
        var result: [MarketplaceScan] = []
        for await scan in service.fetchOtherMarketplaces(excluding: home) { result.append(scan) }
        return result
    }

    @Test func homeLibraryUsesTheSessionsMarketplace() async throws {
        store.stored.withLock { $0 = Fixtures.session(marketplace: .germany) }
        script([.germany: ["D1"], .us: ["U1"]])
        let (service, _) = try await makeService()
        let home = try await service.fetchHomeLibrary()
        #expect(home.marketplace == .germany)
        #expect(home.books.map(\.asin) == ["D1"])
        #expect(home.books.allSatisfy { $0.marketplace == .germany })
        #expect(api.requestedMarketplaces.current == [.germany])
    }

    @Test func checksEveryOtherStoreOnceInOrder() async throws {
        script([.us: ["U1"], .uk: ["K1", "K2"], .japan: ["J1"]])
        let (service, _) = try await makeService()
        let result = await scans(service)
        let others = Marketplace.all.filter { $0 != .us }
        #expect(result.map(\.marketplace) == others)
        #expect(api.requestedMarketplaces.current == others)
        #expect(result[0] == .titles(.uk, [Fixtures.book("K1", marketplace: .uk), Fixtures.book("K2", marketplace: .uk)]))
        #expect(result.last == .titles(.japan, [Fixtures.book("J1", marketplace: .japan)]))
        #expect(result[1] == .empty(.germany))
    }

    @Test func excludedEntriesLeaveAStoreEmpty() async throws {
        api.libraryHandler.withLock {
            $0 = { _, _, marketplace, _ in
                LibraryPage(entries: marketplace == .uk ? [Fixtures.entry("P1", isAYCE: true, marketplace: .uk)] : [])
            }
        }
        let (service, _) = try await makeService()
        #expect(await scans(service).first == .empty(.uk))
    }

    @Test func rejectedStoreFailsAloneAndKeepsTheSession() async throws {
        api.libraryHandler.withLock {
            $0 = { _, _, marketplace, _ in
                switch marketplace {
                case .uk: throw ExporterError.authenticationRequired
                case .germany: throw ExporterError.http(status: 503, message: nil)
                case .japan: return LibraryPage(entries: [Fixtures.entry("J1", marketplace: .japan)])
                default: return LibraryPage(entries: [])
                }
            }
        }
        let (service, auth) = try await makeService()
        let result = await scans(service)
        #expect(result[0] == .failed(.uk, .authenticationRequired))
        #expect(result[1] == .failed(.germany, .http(status: 503, message: nil)))
        #expect(result.last == .titles(.japan, [Fixtures.book("J1", marketplace: .japan)]))
        // Regression guard: a foreign store's 401 must not end the session or wipe the Keychain.
        #expect(await auth.state == .signedIn(Fixtures.session()))
        #expect(store.stored.current == Fixtures.session())
        #expect(api.refreshCount.current == 0)
    }

    @Test func expiredTokenIsRefreshedOnceForAllStores() async throws {
        clock.advance(by: 3600)
        api.refreshHandler.withLock { $0 = { _ in Fixtures.session(accessToken: "new", expiresAt: Fixtures.referenceDate.addingTimeInterval(7200)) } }
        let tokens = Locked<[String]>([])
        api.libraryHandler.withLock {
            $0 = { _, _, _, session in
                tokens.withLock { $0.append(session.accessToken) }
                return LibraryPage(entries: [])
            }
        }
        let (service, _) = try await makeService()
        _ = await scans(service)
        #expect(api.refreshCount.current == 1)
        #expect(tokens.current.count == Marketplace.all.count - 1)
        #expect(tokens.current.allSatisfy { $0 == "new" })
    }

    @Test func stopsWhenTheConsumerIsCancelled() async throws {
        let gate = AsyncGate()
        api.libraryHandler.withLock {
            $0 = { _, _, _, _ in
                await gate.wait()
                return LibraryPage(entries: [])
            }
        }
        let (service, _) = try await makeService()
        let consumer = Task { await scans(service) }
        try await waitUntil { api.requestedMarketplaces.current.count == 1 }
        consumer.cancel()
        await gate.open()
        _ = await consumer.value
        // Give a runaway producer the chance to ask another store.
        try await Task.sleep(for: .milliseconds(50))
        #expect(api.requestedMarketplaces.current.count == 1)
    }
}

@Suite struct LibrarySearchTests {
    let books = [
        Audiobook(asin: "B1", marketplace: .us, title: "Les Misérables", authors: ["Victor Hugo"], narrators: ["Narrator One"]),
        Audiobook(asin: "B2", marketplace: .us, title: "Dune", subtitle: "Book One", authors: ["Frank Herbert"], seriesTitle: "Dune Chronicles"),
        Audiobook(asin: "B3", marketplace: .us, title: "Project Hail Mary", authors: ["Andy Weir"], narrators: ["Ray Porter"]),
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
