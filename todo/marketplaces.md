# Multi-marketplace library in NativeMac (auto-probe on every library load)

## Context
Audible keeps a separate library per marketplace. A title bought while the Amazon address was set to
another country lives only in that country's library. NativeMac today reads exactly one marketplace:
`AudibleSession.marketplace` drives sign-in, token refresh (`api.amazon.<tld>`), library and license
requests (`api.audible.<tld>`). Such titles are invisible.

Libation solves this with a manual "Marketplaces" probe plus per-account "Also scans". The same device
registration is honored in every marketplace, so only the Audible API host changes; request signing
(`RequestSigner`) covers method + path + query + date + body, not the host, so signed requests work
unchanged against another store.

Decided with the user:
- **Merge**: books from every marketplace that holds titles appear in the one library, each tagged with
  its marketplace; licenses are requested from the book's own marketplace.
- **Every library load**: a new sign-in, a restored session at launch, and the Refresh button all probe.
  Nothing is persisted.

Because the library page size is 1000, "probing" a store and "loading" it are the same single request
(`GET /1.0/library?page=1&num_results=1000`). So the probe is simply: load the home store, then load
each other store; an empty first page means nothing is there. No separate count request.

## Design

### Core (`Sources/AudibleExporterCore`)
- `Audiobook.swift`: add `public let marketplace: Marketplace` (the store that holds the title).
  Required init parameter, placed after `asin`.
- `Dependencies.swift` (`AudibleAPI`): make the store explicit, separate from the session's home
  marketplace:
  - `libraryPage(_ number:, pageSize:, marketplace:, session:)`
  - `license(for asin:, marketplace:, session:)`
  Refresh and registration keep using `session.marketplace` (tokens refresh only at home).
- `Library.swift`:
  - `LibraryService.fetchPurchasedBooks(in marketplace:)` - the existing paging loop, parameterised.
    Home store keeps going through `auth.withValidSession` (current behaviour, incl. reauth on 401).
  - New `fetchOtherMarketplaces(excluding home:) -> AsyncStream`/`AsyncThrowingStream` of a
    `MarketplaceScan` result per store (`.titles(Marketplace, [Audiobook])`, `.empty(Marketplace)`,
    `.failed(Marketplace, ExporterError)`), sequential, home excluded, order `Marketplace.all`.
    **Must not go through `withValidSession`'s 401 path**: a foreign store rejecting the request must
    never mark the session `reauthenticationRequired` and delete the Keychain item. Get a token via
    `auth.validSession()` (refreshes if near expiry), call `api.libraryPage` directly, and map *any*
    error to `.failed` for that store only. Cancellation propagates.
  - `LibraryRules`: add `merge(_ existing: [Audiobook], _ new: [Audiobook])` deduplicating by ASIN,
    first (home) wins. Selection stays keyed by ASIN.
  - Optionally add the marketplace name to `LibrarySearch` fields so "japan" filters those titles.
- `ExportQueue.swift` (`exportOnce`): `api.license(for: book.asin, marketplace: book.marketplace, session:)`.
  Keep `withValidSession` here: the library load already proved that store accepts the tokens.

### Adapters (`Sources/AudibleExporterAdapters`)
- `AudibleHTTPAPI.swift`: pass the explicit marketplace to `LibraryRequest.request` and
  `LicenseRequest.request` instead of `session.marketplace`. Signing unchanged.
- `LibraryResponse.swift`: `LibraryParser.page(from:response:marketplace:)` / `entry(_:marketplace:)`
  stamp `Audiobook.marketplace`.
- Voucher key derivation (`LicenseResponse.swift`) uses device type/serial/customer ID/ASIN only - no
  change needed.

### Presentation (`Sources/AudibleExporterPresentation/LibraryViewModel.swift`)
`refresh()` becomes two phases so the home library appears without waiting for nine more requests:
1. Load home (`session` marketplace, passed in by `AppViewModel` or read from the service): set `books`,
   `loadState = .loaded`. Home failure behaves as today (`.failed`, previous rows kept).
2. Then iterate the other-stores stream: append merged titles as each store answers; track
   `isCheckingMarketplaces`, `otherMarketplaces: [(Marketplace, count)]`, `uncheckedMarketplaces: [Marketplace]`.
3. Only after phase 2 ends, `selection.reconcile(with: books)` - reconciling after phase 1 would drop
   selected foreign titles on every refresh.
- Keep the running phase-2 `Task`; cancel it on `reset()` (sign-out) and when a new `refresh()` starts.
- `canRefresh` stays false while either phase runs.
- `summary`: e.g. "120 books · also in UK, Japan"; a non-error notice for unchecked stores
  ("Couldn't check Japan, India") separate from `errorMessage` so it isn't shown as a red failure.

### App (`Sources/AudibleExporterApp/ContentView.swift`)
- `BookTile`: small marketplace badge (e.g. "UK") when `book.marketplace != home`.
- Grid overlay / toolbar: "Checking other marketplaces…" while phase 2 runs.
- `AccountPopover`: list "Also has titles in: United Kingdom (12), Japan (3)".
- `MessagesView`: show the unchecked-marketplaces notice in secondary style, not red.
- No new composition in `CompositionRoot`; `LibraryService` already has `api` + `auth`.

### Explicitly out of scope
- Brazil and pre-Amazon locales are not in `Marketplace.all`; adding Brazil would also put it in the
  sign-in picker, and its login differs. Leave for later.
- Choosing/ignoring stores, persisting results, the "marketplace switcher" TODO.

## Tests (Swift Testing, reuse `Tests/TestSupport`)
- `Doubles.swift` `MockAudibleAPI`: handlers gain the marketplace argument; record
  `requestedMarketplaces`. `Fixtures.book(...)` gets `marketplace: Marketplace = .us`.
- `CoreTests/LibraryTests.swift`:
  - home + one foreign store with titles -> merged, foreign titles tagged, ASIN dedup home-first;
  - empty stores produce `.empty`, one request each, home never re-requested;
  - a foreign store throwing `.authenticationRequired` -> `.failed` for that store, auth state still
    `.signedIn`, `InMemoryCredentialStore` still holds the session (regression guard for the Keychain wipe);
  - expired token refreshed once (shared refresh) before the foreign requests.
- `CoreTests/ExportQueueTests.swift`: a foreign-store book's license is requested with its marketplace.
- `AdaptersTests/LibraryAdapterTests.swift` / `LicenseAndDownloadTests.swift`: request host is
  `api.audible.<book tld>`; parser stamps marketplace.
- `PresentationTests/LibraryViewModelTests.swift`: home books visible before foreign stores finish;
  selection of a foreign title survives refresh; `reset()` cancels phase 2; failure notice not an error.
- Update existing tests/fixtures for the new signatures; `SnapshotTests` fake books get a mix of stores.

## Verification
- `Scripts/test.sh` (layering check + build + sandboxed tests) passes; targeted runs via
  `Scripts/test.sh --filter Library` etc.
- `SNAPSHOT_PATH=<scratch>/shot.png Scripts/test.sh --filter Snapshot` and look at the badge/notice.
- Not verifiable here (state it in the summary): live cross-marketplace requests against a real account,
  and actual UI behaviour. The assumption that one registration works in every store comes from Libation's
  production use (incl. issue #2020), not from a test in this repo.
