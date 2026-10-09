import Foundation
import Testing
import AudibleExporterCore
import AudibleExporterPresentation
import TestSupport

@MainActor
@Suite struct LibraryViewModelTests {
    let api = MockAudibleAPI()
    let store = InMemoryCredentialStore(Fixtures.session())

    func makeModel(signedIn: Bool = true) async throws -> LibraryViewModel {
        let auth = AuthenticationCoordinator(api: api, store: store, clock: TestClock())
        try await auth.restore()
        let model = LibraryViewModel(service: LibraryService(api: api, auth: auth, pageSize: 100))
        model.isSignedIn = signedIn
        return model
    }

    func scriptLibrary(_ asins: [String]) {
        api.libraryHandler.withLock { $0 = { _, _, _ in LibraryPage(entries: asins.map { Fixtures.entry($0) }) } }
    }

    @Test func startsIdleWithActionsDisabledWhenSignedOut() async throws {
        let model = try await makeModel(signedIn: false)
        #expect(model.loadState == .idle)
        #expect(!model.canRefresh)
        #expect(!model.canSelect)
        await model.refresh()
        #expect(api.requestedPages.current.isEmpty)
    }

    @Test func showsLoadingThenLoaded() async throws {
        let gate = AsyncGate()
        api.libraryHandler.withLock { $0 = { _, _, _ in await gate.wait(); return LibraryPage(entries: [Fixtures.entry("B1")]) } }
        let model = try await makeModel()
        let refresh = Task { await model.refresh() }
        try await waitUntil { await model.isLoading }
        #expect(!model.canRefresh)
        await gate.open()
        await refresh.value
        #expect(model.loadState == .loaded)
        #expect(model.books.map(\.asin) == ["B1"])
        #expect(model.canRefresh)
        #expect(model.canSelect)
    }

    @Test func failedRefreshKeepsRowsAndShowsError() async throws {
        scriptLibrary(["B1", "B2"])
        let model = try await makeModel()
        await model.refresh()
        model.toggleSelection("B1")

        api.libraryHandler.withLock { $0 = { _, _, _ in throw ExporterError.http(status: 503, message: nil) } }
        await model.refresh()
        #expect(model.books.map(\.asin) == ["B1", "B2"])
        #expect(model.isSelected("B1"))
        #expect(model.errorMessage?.contains("503") == true)
        #expect(model.canRefresh)
    }

    @Test func successfulRefreshReconcilesSelection() async throws {
        scriptLibrary(["B1", "B2", "B3"])
        let model = try await makeModel()
        await model.refresh()
        model.setSelection(["B1", "B3"])

        scriptLibrary(["B2", "B3"])
        await model.refresh()
        #expect(model.selection.asins == ["B3"])
        #expect(model.errorMessage == nil)
    }

    @Test func searchFiltersVisibleBooksAndSelectAllUsesThem() async throws {
        api.libraryHandler.withLock {
            $0 = { _, _, _ in
                LibraryPage(entries: [Fixtures.entry("B1", title: "Alpha"), Fixtures.entry("B2", title: "Beta"), Fixtures.entry("B3", title: "Alphabet")])
            }
        }
        let model = try await makeModel()
        await model.refresh()
        model.searchText = "alpha"
        #expect(model.visibleBooks.map(\.asin) == ["B1", "B3"])
        model.selectAllVisible()
        #expect(model.selectedBooks.map(\.asin) == ["B1", "B3"])
        #expect(model.summary == "2 of 3 books, 2 selected")

        model.searchText = ""
        model.toggleSelection("B2")
        model.searchText = "alphabet"
        model.deselectAllVisible()
        #expect(model.selection.asins == ["B1", "B2"])
    }

    @Test func ignoresUnknownSelections() async throws {
        scriptLibrary(["B1"])
        let model = try await makeModel()
        await model.refresh()
        model.toggleSelection("NOPE")
        model.setSelection(["B1", "NOPE"])
        #expect(model.selection.asins == ["B1"])
    }

    @Test func resetClearsEverything() async throws {
        scriptLibrary(["B1"])
        let model = try await makeModel()
        await model.refresh()
        model.toggleSelection("B1")
        model.searchText = "x"
        model.reset()
        #expect(model.books.isEmpty && model.selection.isEmpty && model.searchText.isEmpty)
        #expect(model.loadState == .idle)
    }

    @Test func downloadedBookDroppedByRefreshStaysVisible() async throws {
        scriptLibrary(["B1", "B2"])
        let model = try await makeModel()
        await model.refresh()
        model.applyLocal([Fixtures.book("B2", title: "Kept")])
        #expect(model.books.map(\.asin) == ["B1", "B2"])
        #expect(model.books[1].title == "Book B2") // the library's version wins while it is there
        model.setSelection(["B2"])

        scriptLibrary(["B1"])
        await model.refresh()
        #expect(model.books.map(\.asin) == ["B1", "B2"])
        #expect(model.books[1].title == "Kept")
        #expect(!model.isInLibrary("B2"))
        #expect(model.isSelected("B2"))
        model.searchText = "kept"
        #expect(model.visibleBooks.map(\.asin) == ["B2"])
    }

    @Test func downloadedBooksAreHiddenWhenSignedOut() async throws {
        let model = try await makeModel(signedIn: false)
        model.applyLocal([Fixtures.book("B9")])
        #expect(model.books.isEmpty)
        model.isSignedIn = true
        #expect(model.books.map(\.asin) == ["B9"])
        model.reset()
        #expect(model.books.isEmpty)
    }
}
