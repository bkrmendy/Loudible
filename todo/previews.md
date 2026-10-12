# Plan: Xcode project + every view state as a `#Preview`

## Context
The goal is to look at any UI state without clicking through the running app. Today two things block that:
1. **Toolchain.** `xcode-select` points at the Command Line Tools, which ship no `PreviewsMacros` plugin (the same reason the code avoids `@State`). `#Preview` would break `swift build` and `Scripts/test.sh`. The user asked for a proper Xcode project. Xcode 27.0 (Swift 6.4, the same compiler as the CLT) is installed at `/Applications/Xcode.app`, and its `MacOSX.platform/.../host/plugins` contains `libPreviewsMacros.dylib`.
2. **Views are bound to live view models.** Every view in `Sources/LoudibleApp/ContentView.swift` (580 lines) reads `AppViewModel`/`SessionViewModel`/`LibraryViewModel`/`ExportViewModel` directly. Those models' state is `private(set)` and comes from Core actors, so most states (export at 40%, a failed job, an expired session) can't be built in a preview.

The outcome: an Xcode project you open and run with ⌘R. Views are split into pure "content" views that take values and closures, and each file ends with `#Preview`s covering every state. CLI scripts, tests and packaging keep working.

## Part 1: Xcode project and toolchain

**Package stays the source of truth.** All modules remain SwiftPM targets. The Xcode project is a thin app shell that depends on the local package.

1. **`Package.swift`**
   - Turn `LoudibleApp` from an `executableTarget` into a library `.target`. Keep the name, so `TestSupport`'s `@testable import LoudibleApp` and the snapshot harness keep working. It still holds the views, `CompositionRoot` and the `--self-test` launcher logic.
   - Make the `App` struct, `Launcher.main()` and the types the shell needs `public`.
   - Add a tiny `executableTarget` `Loudible` (`Sources/Loudible/main.swift` → `Launcher.main()`). This keeps `swift run Loudible` and `.vscode/launch.json` working.
   - Move the `-platform_version` linker hack onto this executable. Xcode builds against the real SDK and doesn't need it.
   - Add a `library` product `LoudibleApp` for the Xcode project to consume.
2. **Remove the pkg-config dependency so Xcode can find FFmpeg.** Xcode launched from the Dock never sees `PKG_CONFIG_PATH`.
   - `build-ffmpeg.sh` creates a stable symlink `Vendor/ffmpeg → ffmpeg-$FFMPEG_VERSION`.
   - `Package.swift` derives `Vendor/ffmpeg` from `#filePath`. It passes `-I …/include` to `FFmpegBridge` (`cSettings` unsafeFlags) and `-L …/lib` as linker settings.
   - `CFFmpegHeaders` drops `pkgConfig:` and keeps its module map.
   - `env.sh` keeps its version check (`61.*`) but no longer needs `PKG_CONFIG_PATH`.
   - Unsafe flags are allowed because the package is local.
3. **`Scripts/env.sh`** exports `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` when that path exists, with a clear error if it doesn't. Every script and raw `swift` command then uses the Xcode toolchain, so `#Preview`, `@State` and `@Previewable` compile everywhere. Keep the TestingMacros plugin-path workaround in `test.sh`, which still applies to Swift 6.4.
4. **New `App/Loudible.xcodeproj`** (committed, objectVersion 77 with file-system-synchronized groups, so adding files doesn't churn the pbxproj; no XcodeGen/Tuist)
   - Local package reference `..` and an app target `Loudible` with sources in `App/Loudible/`:
     - `LoudibleMain.swift`: `@main` calls `Launcher.main()`.
     - `Assets.xcassets`
   - Build settings:
     - arm64 only; `MACOSX_DEPLOYMENT_TARGET 14.0`; Swift 6 language mode.
     - Bundle id `local.loudible.Loudible`, version 0.1.0.
     - Ad-hoc signing (`CODE_SIGN_IDENTITY=-`); App Sandbox off, as today.
     - `LD_RUNPATH_SEARCH_PATHS=@executable_path/../Frameworks`.
     - Generated Info.plist with the keys `build-app.sh` writes today (`LSArchitecturePriority`, `NSPrincipalClass`, display name, `LSMinimumSystemVersion` via the deployment target).
   - A shared scheme `Loudible`.
   - `.gitignore`: stop ignoring `*.xcodeproj/` (keep `xcuserdata/`, `DerivedData/`).
5. **`Scripts/build-app.sh`**
   - Replace `swift build` + hand-written Info.plist with `xcodebuild -project App/Loudible.xcodeproj -scheme Loudible -configuration Release -derivedDataPath .build/xcode build`, then copy the `.app` to `build/`.
   - Keep the existing `bundle_dylibs.py` → `write-notices.py` → codesign steps. `verify-app.sh` stays unchanged and must pass.
   - `CONFIGURATION=debug` maps to `Debug`.

## Part 2: View refactor for previews

**Pattern.** Each view that reads a view model splits in two:
- **Content view (pure).** Takes plain values, `Binding`s for editable fields, and action closures. Previews use these.
- **Wrapper (thin).** Maps the view model onto the content view and turns actions into `Task { await model… }`. No logic beyond that mapping.

No Presentation or Core changes are needed: every value a content view needs is already a public derived property (`canSignIn`, `statusText`, `canCancel(_:)`, …). Replace `PopoverPresentation` (`ObservableObject`/`@StateObject`) with `@State` and delete the "@State is a macro" comments, here and in `LoudibleApp.swift`.

**Split `ContentView.swift` by area**, each file ending in its previews. Types stay `private`/`fileprivate` where possible and become `internal` only where another file needs them.

| File | Content views → preview states |
| --- | --- |
| `AccountViews.swift` | `AccountAvatar`: initial, no name, 24 pt / 44 pt. `AccountButtonLabel`: signed out, signed in, long name, needs re-auth. `AccountPopover` content: signed out, sign-in disabled (working), session expired, signed in (with sign out). |
| `LibraryViews.swift` | `BookTile`: unselected, selected, no cover, long title / several authors, no runtime, disabled. `LibraryGridContent` (grid + empty overlay, without the toolbar): signed out, loading, empty library, books, books with selection. `MessagesBar([String])`: none, one, several long. |
| `ExportViews.swift` | `ExportButton` content: no selection (grey), ready, running at 40%. `ExportFolderPopover`: no folder, folder set, export running (disabled). `ExportJobRow`: one preview per `ExportJob.State` (queued; running in each `Phase`; waiting for sign-in; completed with reveal button; failed with a long message; cancelled), plus a cancellable/non-cancellable pair. `ExportProgressSheet` content: running batch, paused for sign-in, finished with failures and cancellations, start error message. |
| `LoginSheet.swift` | `LoginSheet` gets the browser as a view slot. Previews pass a placeholder rectangle, so **no preview loads amazon.com**. States: idle, registering overlay, error message, pasted URL entered (Submit enabled). |
| `ContentView.swift` | `ContentView`, toolbar assembly, the `View` helper extensions (`bar`, `exportButtonBackground`, `removingToolbarTitle`, `loginSheet`). Whole-window previews at 1100×600: signed out, library loaded, loading, library load failed. |

**Preview data**: new `Sources/LoudibleApp/PreviewData.swift`, wrapped in `#if DEBUG`.
- Sample `Audiobook`s: varied titles, authors and runtimes; some without covers. Covers are a few coloured PNGs written once to a temp directory, as `Snapshot.swift` does today. `AsyncImage` needs a URL.
- `ExportJob` samples built with the public `transition(to:)`.
- Sample sessions and a `PendingLogin` with `.invalid` URLs.
- Minimal in-memory fakes (`AudibleAPI`, `CredentialStore`, `FileDownloader`, `AudioConverter`) and `AppViewModel.preview(…)` factories for the whole-window previews. Library loading uses an API call that never returns; library failure uses one that throws.
- These have to live in the app module because previews can't import `TestSupport`. In exchange, `Tests/TestSupport/Snapshot.swift` drops its private `FakeAPI`/`FakeStore`/`NoDownload`/`NoConvert` and uses these factories, so there's one set of UI fakes. Data stays synthetic, per AGENTS.md.

**One catalog of states, shared by previews and snapshots.** The snapshot harness can't render `#Preview` blocks: they expand to types only Xcode's canvas can find, and nothing public lists them at runtime. So each state is defined once, in `PreviewCatalog` (in `PreviewData.swift`, `#if DEBUG`):
- An `enum PreviewState: String, CaseIterable` names every state, e.g. `.exportRowFailed` or `.windowSignedOut`.
- Each case has a size and a view (`AnyView`).
- Every `#Preview` is one line: `#Preview("Export row – failed") { PreviewCatalog.view(.exportRowFailed) }`. Using an enum means a typo fails to compile.
- The harness loops over `PreviewState.allCases` and writes one PNG per state (see Part 3).

**Known gap, not fixed here:** a search with no matches shows a blank grid, because the overlay only checks `books.isEmpty`. A "books, no search results" preview will make this visible. I'll mention it rather than change behaviour.

## Part 3: Snapshot every state from the terminal
- `Snapshot.run(to:)` takes a folder instead of a file. It renders every `PreviewState` into `<folder>/<state>.png`.
- `SNAPSHOT_STATES=a,b` limits the run to the named states.
- Command: `SNAPSHOT_PATH=/abs/dir Scripts/test.sh --filter Snapshot`.
- Instead of a fixed 3 s sleep, it waits until `AsyncImage` covers have loaded (poll the run loop with a timeout).
- **Not headless.** Rendering needs a logged-in macOS session, because SwiftUI controls on macOS are AppKit views that only draw inside a window. `ImageRenderer` would need no window, but it was tested here and draws pickers, text fields, lists and progress bars as yellow "unsupported" placeholders. It isn't usable for this app.
- **Spike: keep the window off screen.** Today the harness shows the window on screen (`makeKeyAndOrderFront`).
  - Try a window that never appears, one at alpha 0, and one positioned far off screen.
  - Keep whichever variant still renders the toolbar, controls and Liquid Glass correctly, compared against a visible-window capture.
  - If none does, keep the brief on-screen window and say so in AGENTS.md.
  - A first scratch attempt was inconclusive: its visible-window control case came out blank too, so the test script itself was faulty.
- Popovers and sheets are separate windows that a capture of the main window doesn't include. The catalog therefore renders their content views directly, inside a plain window of the content's size.

## Docs
- `AGENTS.md`:
  - Toolchain: Xcode 27 required; `env.sh` sets `DEVELOPER_DIR`.
  - Commands: open `App/Loudible.xcodeproj`.
  - Replace the "Looking at the UI" section with previews first, snapshot second.
  - Layering table: `LoudibleApp` is now a library plus two thin shells.
  - Note that `@State` is fine.
- `README.md`: dev setup lines.
- Leave `todo/` alone. Commit the user's pending `ContentView.swift` change first, or carry it over into `ExportViews.swift`. Either way, keep the reveal-in-Finder button.

## Verification
1. `Scripts/test.sh`: layering check plus all tests pass under the Xcode toolchain, with `#Preview`s compiled in.
2. `source Scripts/env.sh && swift build`, then `swift run Loudible`: the app launches.
3. `xcodebuild -project App/Loudible.xcodeproj -scheme Loudible build` succeeds, including from a shell without `env.sh` sourced. This proves FFmpeg is found without pkg-config.
4. `Scripts/build-app.sh && Scripts/verify-app.sh`: all packaging checks pass (arm64, minos 14, bundled dylibs only, LGPL, self-test).
5. `SNAPSHOT_PATH=<scratch dir> Scripts/test.sh --filter Snapshot` writes one PNG per `PreviewState`. Look through them: this checks that every state renders, without Xcode.
6. Manual (the user, in Xcode): open the project, run with ⌘R, and check that the canvas shows the previews. Step 5 covers whether each state renders; it does not cover the canvas itself.
