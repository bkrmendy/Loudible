# AGENTS.md

Loudible is a small native macOS SwiftUI app: sign in to Audible, list the purchased
library, export selected books to M4B. It lives inside the Libation checkout but is a **separate
git repository** and an independent product. It shares no code, settings, database or folders
with Libation, so the . NET instructions in `../AGENTS.md` do not apply here. `README.md` is the
user-facing description; read it for the export flow and FFmpeg licensing details.

## Toolchain

* Apple Silicon, Swift 6, **Xcode 27** at `/Applications/Xcode.app`. The Command Line Tools lack
  the macro plugins behind `#Preview` (and SwiftUI's other macros), so they cannot build this
  package any more. `@State` , `@Previewable` and `#Preview` are fine to use.
* macOS 14 minimum (`Package.swift`,  `FFMPEG_MINIMUM_MACOS`). Guard newer APIs with `#available`.
* FFmpeg 7.1 is built from a pinned, SHA-256-checked tarball by `Scripts/build-ffmpeg.sh` into
`Vendor/` (gitignored, about a minute, done once). The other scripts run it for you.
* **Before any raw `swift` command,  `source Scripts/env.sh`.** It sets `DEVELOPER_DIR` to Xcode
  (unless already set) and checks that FFmpeg is built. `Package.swift` finds FFmpeg through the
`Vendor/ffmpeg` symlink relative to itself, so Xcode needs no environment.
* `App/Loudible.xcodeproj` is a thin shell: one app target (`App/Loudible/`, 
`@main` calling `Launcher.main()` ) that depends on the local package's `LoudibleApp`

  library. It uses file-system-synchronized groups; new files in `App/Loudible/` need no
  pbxproj edit. Bundle id, version and Info.plist keys live in its build settings and
`App/Info.plist` . All other code belongs in the package.

## Commands

```sh
Scripts/test.sh                        # the only test command: lint, layering check, build, sandboxed tests
Scripts/lint.sh                        # strict SwiftLint check (downloads the pinned tool once)
Scripts/format.sh                      # SwiftFormat line wrapping only (pinned, SHA-256 checked)
Scripts/format.sh --lint               # check wrapping without changing files
Scripts/install-hooks.sh               # enable the SwiftFormat + SwiftLint pre-commit hook
Scripts/test.sh --filter ExportQueue   # a subset (args go to `swift test`)
Scripts/check-layering.sh              # layering check alone
source Scripts/env.sh && swift build   # compile check
open App/Loudible.xcodeproj      # run with ⌘R, previews in the canvas
Scripts/build-app.sh                   # build/Loudible.app via xcodebuild, release, ad-hoc signed
Scripts/verify-app.sh                  # arm64, minos, signatures, bundled dylibs, LGPL, FFmpeg loads
source Scripts/env.sh && swift run Loudible   # run for development
```

* Run tests through `Scripts/test.sh`, not bare `swift test`. It runs them under `sandbox-exec`
  with all non-loopback network denied and sets `LOUDIBLE_TEST_SANDBOX=1` , and bounds each
  step with `TEST_TIMEOUT` (default 900 s). It also works around Swift 6.4 losing the
`TestingMacros` plugin on incremental builds.
* Any change to packaging (`build-app.sh`,  `bundle_dylibs.py`,  `write-notices.py`, FFmpeg
  configure flags, linker settings, the Xcode project's build settings) must end with a passing `Scripts/verify-app.sh` .
* SwiftLint is configured in `.swiftlint.yml`;  `Scripts/lint.sh` runs it with `--strict` and
  is also run by `Scripts/test.sh` and the SwiftLint CI workflow. Its pinned, SHA-256-checked
  binary lives in `.build/tools/` ; Homebrew is not needed. Keep compiler warnings clean too; 
`FFmpegBridge` builds with `-Wall -Wextra -Werror` .
* After editing Swift files, run `Scripts/format.sh`, then `Scripts/lint.sh` from the repository
  root and fix every reported violation before handing off the change. The lint script selects Xcode itself and does
  not need `Scripts/env.sh` or an FFmpeg build. Use this wrapper rather than a globally installed
`swiftlint` so local checks, hooks and CI use the same version and configuration.
* Fix the code to satisfy lint rules; do not weaken `.swiftlint.yml` or add blanket
`swiftlint:disable` comments to make a check pass. If a targeted suppression is necessary, 
  keep its scope minimal and explain why beside it.
* `.swiftlint-baseline.json` records pre-existing violations. Remove entries as they are fixed; 
  do not regenerate it to suppress new violations.
* `.swiftformat` enables only line wrapping at 120 characters. `Scripts/format.sh` applies it; 
  tests, CI and the pre-commit hook run it with `--lint` . Keep unrelated formatting rules disabled.
* Check SwiftFormat with `Scripts/format.sh --lint`, then run SwiftLint before every commit.
  Enable the versioned pre-commit hook with `Scripts/install-hooks.sh` once per checkout; 
  either check failing must block the commit. The hook checks formatting without rewriting files.

## Feature development

After building a feature of fixing a bug, always run
* test.sh
* lint.sh
* format.sh
* dead-code.sh

Fix any issues these commands surface.

## Architecture and layering (enforced)

| Target | May use |
| --- | --- |
| `LoudibleScheduling` | Swift/Foundation only, no dependencies. Pure keyed admission policy. |
| `LoudibleCore` | Foundation + LoudibleScheduling. Models, auth lifecycle, library rules, export queue, file naming. Protocols for everything external live in `Dependencies.swift` . |
| `LoudiblePresentation` | Core + Foundation/Observation. `@Observable` view models. |
| `LoudibleAdapters` | Core. Audible HTTP API, request signing, Keychain, URLSession downloads. |
| `LoudibleFFmpeg` / `FFmpegBridge` (C) / `CFFmpegHeaders` | Decrypt + remux via `aex_remux_to_m4b` , wrapped by `FFmpegConverter` . |
| `LoudibleApp` (library) | SwiftUI/AppKit/WebKit views, `CompositionRoot` , `Launcher` , preview data. No business logic. |
| `Loudible` (executable) and the Xcode app target | Shells that call `Launcher.main()` . Nothing else. |

Views come in pairs: a pure *content* view ( `AccountPopoverContent` , `LibraryGridContent` , 
`BookTile` , `LoginSheetContent` , …) that takes values, bindings and closures, and a
thin wrapper that maps a view model onto it and turns actions into `Task { await model… }` .
Previews and snapshots use the content views; keep new views to that split.

`check-layering.sh` fails if Core or Presentation import SwiftUI/AppKit/WebKit/UIKit/Cocoa, or if
the manifest gives Scheduling any dependencies, Core dependencies other than Scheduling, or Presentation dependencies other than Core, or any build settings. Put new logic in
Core or Presentation behind a protocol, implement it in an adapter, and wire it up in
`CompositionRoot` ( `LoudibleApp.swift` ).

## Tests

* Swift Testing (`import Testing`,  `@Suite`,  `#expect`), not XCTest.
* Doubles and helpers are in `Tests/TestSupport` (`MockAudibleAPI`,  `InMemoryCredentialStore`, 
`MockDownloader` , `MockConverter` , `TestClock` , `TemporaryDirectory` , `Fixtures` ). Reuse them
  rather than adding new mocks per test file.
* Tests must never contact Audible or touch the real Keychain. Download tests use the loopback
  server in `Tests/AdaptersTests/LocalHTTPServer.swift` . All fixtures under
`Tests/AdaptersTests/Fixtures` are synthetic; never add real tokens, keys, ASIN-linked licenses
  or account data.
* Not covered automatically, so say so rather than implying it was tested: live Audible requests
  (no real account has been used), decryption of real AAX/AAXC files (no test, by decision), and
  UI behaviour. The snapshot below only shows layout; it asserts nothing.

## Looking at the UI

1. **Previews.** Open `App/Loudible.xcodeproj`; every view file ends with `#Preview`s,
   one per state. Each is one line, `PreviewCatalog.view(.someState)` : the states, their sizes
   and their sample data live in `Sources/LoudibleApp/PreviewData.swift` ( `#if DEBUG` , 
   synthetic data, in-memory fakes, logins on `.invalid` hosts, so nothing contacts Amazon). To
   add a state, add a `PreviewState` case, its size and view in `PreviewCatalog` , and a
`#Preview` line in the view's file. Whole-window states use `AppViewModel.preview(…)` .
2. **Snapshots, without Xcode.**
   

```sh
   SNAPSHOT_PATH=/abs/dir Scripts/test.sh --filter Snapshot
   SNAPSHOT_STATES=tileSelected,windowLibrary SNAPSHOT_PATH=/abs/dir Scripts/test.sh --filter Snapshot
   ```

   writes `<state>.png` for every `PreviewState` (about 25 s for all) into that folder. Use a
   scratch directory, not the repo. The window is never shown on screen (its capture is
   byte-identical to a visible one), but it needs a logged-in macOS session. Popovers and sheets
   are rendered as their content views in a plain window. The harness is
`Tests/TestSupport/Snapshot.swift` ; the test is `Tests/PresentationTests/SnapshotTests.swift` , 
   skipped unless `SNAPSHOT_PATH` is set.

Snapshots show that each state renders; they assert nothing.

`TestSupport` depends on `LoudibleApp` (via `@testable import` ) for this, so every test
binary links the app. Keep the `@Test` in one test target: `TestSupport` is linked into all three, 
so a test declared there runs three times.

## Licensing constraints

FFmpeg must stay LGPL-2.1-or-later and dynamically linked. Never add `--enable-gpl` , 
`--enable-version3` or `--enable-nonfree` , static linking, or extra FFmpeg components without a
reason; `build-ffmpeg.sh` and `verify-app.sh` reject GPL/non-free builds. To upgrade FFmpeg, 
follow the steps at the top of `Scripts/ffmpeg-version.sh` (signature check, then record the
SHA-256), and update the `61.*` libavformat check in `env.sh` and the dylib names in
`verify-app.sh` if the major versions change.

## Runtime state (for manual testing)

* Credentials: one Keychain item,  `Loudible.AudibleSession`.
* Kept downloads and exports: `~/Documents/Loudible/` (`CompositionRoot.downloadsFolder`), named
`Title [ASIN].aaxc` / `.aax` and `Title [ASIN].m4b` . There is no export folder setting; the old
`ExportDestinationPath` default is removed at launch. A book is "downloaded" when a non-hidden audio file there carries
`[ASIN]` ; written as hidden `.….partial` files first. Downloads use Alamofire native resume data; URLSession owns unfinished audio files.
  Completed transfers are staged at `.<ASIN>.download.partial` before final naming. On failure,
  quit or sign-out the app saves a token when available. The next attempt resumes or restarts
  using a fresh license URL; crashes may lose current progress. Cancel and Delete Download
  discard recovery state. App-owned staging `.partial` files are swept at launch.
* Download manifests (keys, chapters, metadata) and covers:
`~/Library/Application Support/<bundle id>/Downloads/<ASIN>.json|.cover` , mode 0600. A manifest
  without its audio file is deleted on the next rescan. Version-2 unfinished-download records (account, decryption descriptor, native resume data
  and advisory progress) are `<ASIN>.partial` in the same folder, mode 0600. Records without
  tokens restart from zero. Version-1 checkpoint records and their audio are removed at startup. After each
  complete library load, the signed-in account's records are resumed automatically, except ones
  that failed in this session. Records of another account, or of books no longer in the library, 
  are deleted.
* The old `~/Library/Caches/<bundle id>/Downloads` folder is no longer used and is removed at launch.
* Bundle id `local.loudible.Loudible` (set in the Xcode project).

## Shared skills (Codex and Claude Code)

* Keep skill sources in `.agents/skills/<name>/SKILL.md`. Each skill has a relative symlink at
  `.claude/skills/<name>` pointing to `../../.agents/skills/<name>`. Commit both together;
  the links resolve within each clone or worktree.
* From the repo root, scaffold with
  `python3 Scripts/new-skill.py <name> "What it does and when to use it"`.
  Replace the generated TODO instructions before using the skill.
* Keep `name`, `description`, Markdown instructions and supporting files portable. Avoid relying
  on agent-specific substitutions, dynamic context injection or tool names in shared instructions.
  Optional `agents/openai.yaml` metadata is specific to Codex.
* Invoke with `$<name>` in Codex or `/<name>` in Claude Code. Keep shared repository rules here
  rather than duplicating them in every skill.

## Housekeeping

* `todo/` holds the user's working notes and feature wishes; read them for intent, don't edit
  them unless asked.
* `.build/`,  `build/` and `Vendor/` are generated and gitignored.
* Code style: short doc comments on public API, comments that explain *why*, no business logic
  in views. Match the surrounding code.
