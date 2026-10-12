# Loudible (native macOS)

A small SwiftUI app that signs in to Audible, lists the audiobooks you bought, and exports the
selected ones to M4B files. It is independent of Libation: it does not use or change Libation's
settings, database, or folders.

## Requirements

- Apple Silicon Mac and Xcode 27 in `/Applications` (the Command Line Tools alone are not
  enough: SwiftUI previews need Xcode's macro plugins). Homebrew is not needed.
- FFmpeg is built from source by `Scripts/build-ffmpeg.sh`, which `test.sh` and `build-app.sh`
  run for you. It downloads the release pinned in `Scripts/ffmpeg-version.sh`, checks its SHA-256,
  and installs a minimal LGPL build into `Vendor/` (about a minute, done once).

The code is a Swift package. `App/Loudible.xcodeproj` wraps it in an app target: open it,
press ⌘R to run, and use the canvas to see every view state as a preview. Build FFmpeg once first:

```sh
cd NativeMac
Scripts/build-ffmpeg.sh
open App/Loudible.xcodeproj
```

From the terminal, source `Scripts/env.sh` before `swift` commands; it selects Xcode's toolchain
and checks the FFmpeg build:

```sh
source Scripts/env.sh
swift build
```

## Test

```sh
Scripts/test.sh                       # everything
Scripts/test.sh --filter ExportQueue  # a subset
```

`test.sh` is the only test command. It:

1. Checks that Core and Presentation do not import SwiftUI, WebKit, or AppKit.
2. Builds the package and the tests.
3. Runs the tests in a `sandbox-exec` profile that blocks every non-loopback connection, with a
   timeout on each step (`TEST_TIMEOUT`, default 900 s).

The tests never contact Audible. They use mocks for `AudibleAPI`, the HTTP transport, and
Keychain. Download tests use a local HTTP server on 127.0.0.1. All fixtures are synthetic.

## Build and run the app

```sh
Scripts/build-app.sh     # builds the Xcode project into build/Loudible.app (ad-hoc signed)
Scripts/verify-app.sh    # checks ARM64, signatures, bundled libraries, and that FFmpeg loads
open build/Loudible.app
```

For development you can also run `source Scripts/env.sh && swift run Loudible`.

The app runs on macOS 14 or newer. `build-app.sh` copies the three FFmpeg libraries
(libavformat, libavcodec, libavutil) into `Contents/Frameworks`, rewrites their install names
to `@rpath`, and signs everything ad hoc. The result is about 3.5 MB.

### FFmpeg licensing

FFmpeg is built without `--enable-gpl`, `--enable-version3`, or `--enable-nonfree`, so it is
LGPL-2.1-or-later. `build-ffmpeg.sh` refuses any configuration that would change that, and
`--self-test` checks the license at runtime. The app ships:

- `Contents/Resources/THIRD_PARTY_NOTICES.txt`: version, configure line, and source URL with
  its SHA-256.
- `Contents/Resources/Licenses/FFmpeg/`: the LGPL text.
- `Contents/Resources/Credits.html`: the FFmpeg credit shown in the About window.

FFmpeg stays in separate dynamic libraries, so users can replace them.

### Releasing

With every release, publish the FFmpeg source tarball named in `Scripts/ffmpeg-version.sh`
(`Vendor/downloads/` holds the verified copy) and `Scripts/build-ffmpeg.sh` next to the app
download. The notices promise this.

To upgrade FFmpeg, follow the steps at the top of `Scripts/ffmpeg-version.sh`.

## Using the app

1. Choose a marketplace and click **Sign In**. Amazon's sign-in page opens in an embedded,
   non-persistent browser. If that page gives you trouble, open it in your web browser
   instead. After signing in, paste the address of the page you land on
   (`…/ap/maplanding?…`) into the sheet.
2. Your purchased library loads. Audible Plus catalog titles, podcasts, and series or podcast
   containers are hidden. Search and select one or more books.
3. **Download** keeps a book's encrypted Audible file (`Title [ASIN].aaxc`, or `.aax` for
   legacy titles) in `~/Documents/Loudible/`. **Export** turns it into
   `Title [ASIN].m4b` in the export folder: the audio is not re-encoded; chapters, metadata,
   and cover art are kept. Exporting a book that is not downloaded yet downloads it first and
   keeps the file. If a file with that name already exists, the new one gets a numbered
   suffix: `Title [ASIN] (2).m4b`.
4. Each book has a menu (the dots next to its title, or right-click) with Download, Cancel,
   Export to M4B, Show in Finder, Show Exported File in Finder, and Delete Download. Select
   books and click **Export** in the toolbar to export several at once; choose the export
   folder with the chevron next to it.
5. A badge on the cover shows the book's state: queued, downloading or exporting (a progress
   ring), failed, downloaded, or exported.

Jobs for one book run in order (download, then export); up to three different books are worked
on at once. A downloaded book is exported with the keys saved at download time, so it needs no
network. Downloaded books that later leave the library (returned, Plus title expired) stay in the
grid marked "Not in library"; they can be shown in Finder or deleted, but not exported.

The app checks the folders at launch, after Refresh Library, when it becomes active, and after
each job, so files renamed, moved, or deleted in Finder are picked up. A book counts as
downloaded when the download folder has a `.aax`/`.aaxc` file whose name contains `[ASIN]`.

Credentials are stored in one Keychain item, `Loudible.AudibleSession`. **Sign Out**
deletes that item but does not deregister the device on Amazon's side; it cancels running jobs
and keeps finished files. The decryption keys, chapters, and cover of each download are saved
as `<ASIN>.json` and `<ASIN>.cover` (mode 0600) in
`~/Library/Application Support/<bundle id>/Downloads`, not next to the audio, because they are
key material.

## Layout

| Target | Role |
| --- | --- |
| `LoudibleCore` | Models, authentication lifecycle, library rules, selection, the download/export scheduler, kept downloads and their manifests, book status and menu rules, file naming. Foundation only. |
| `LoudibleAdapters` | Audible HTTP API (PKCE login, device registration, request signing, token refresh, library, licenses, vouchers), Keychain, URLSession downloads. |
| `LoudibleFFmpeg`, `FFmpegBridge`, `CFFmpegHeaders` | In-process decryption and remuxing: `aex_remux_to_m4b` in C against FFmpeg's API, wrapped by `FFmpegConverter`. |
| `LoudiblePresentation` | `@Observable` view models: session, library, export, app wiring. |
| `LoudibleApp` | SwiftUI window, WKWebView login, folder picker, previews. No business logic. |
| `Loudible`, `App/Loudible.xcodeproj` | Launchers for `swift run` and Xcode. |

## Not verified automatically

- Live Audible sign-in, library, license, and download requests have not been run against a
  real account. The request formats follow the Audible for iPhone protocol, as used by Libation
  and the `audible` Python package.
- Decrypting real AAXC or AAX files has no automated test (by decision). It relies on FFmpeg's
  `audible_key`/`audible_iv` and `activation_bytes` demuxer options. The remux itself was checked
  by hand with a synthetic unencrypted M4A: audio packets were identical, and chapters,
  metadata, and cover art were kept.
- The UI has no automated tests. `SNAPSHOT_PATH=/abs/dir Scripts/test.sh --filter Snapshot`
  renders every preview state to PNGs for a look, but asserts nothing.
