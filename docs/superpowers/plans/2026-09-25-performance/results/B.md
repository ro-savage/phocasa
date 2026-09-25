# Task B results: a development library for real-app checks

**Branch:** `feat/development-library` (from `main` at `b389de4`) · **Status:** complete; the three real-app checks
that need it (Move to Bin across a relaunch, a 500+ library's background launch, the capture-date backfill of an
existing library) are the coordinator's to run.

- A **Debug** launch with **`PHOCASA_DEVELOPMENT_LIBRARY=1`** keeps its library in
  `~/Library/Application Support/Phocasa-Development/Phocasa.store` and its thumbnails in
  `Phocasa-Development/Thumbnails/v1` (`PHOCASA_THUMBNAIL_CACHE_DIR` still overrides the cache). The library survives a
  relaunch.
- In that mode the app never reads, moves or opens `Application Support/Phocasa/` or a `default.store`:
  `StoreLocation.prepare` isn't called, so no legacy move runs. It never writes `~/Library/Caches/com.phocasa.app`.
- A **Release** build ignores the flag. A Debug launch **without** it (how the user runs the app) opens the real
  library exactly as before.
- **The unit-test host stays in memory, even with the flag** (see "How the flag combines with
  `XCTestConfigurationFilePath`"; this differs from the suggestion in the hand-off).
- One pure function, `LibraryLocation.resolve(environment:isDebugBuild:applicationSupport:caches:)`, decides the store
  and the thumbnail cache. `PhocasaApp` and `ImageLoader.shared` both read `LibraryLocation.current`, so they can't
  disagree.
- **Suite:** `Executed 640 tests, with 41 tests skipped and 0 failures` (baseline 627 / 41 / 0; 13 new tests), 0 source
  warnings.

## The flag

| Environment | Debug build | Release build |
|---|---|---|
| nothing (a normal launch) | user's library, `Caches/com.phocasa.app/Thumbnails/v1` | same |
| `PHOCASA_DEVELOPMENT_LIBRARY=1` | **development library**, `Phocasa-Development/Thumbnails/v1` (or `PHOCASA_THUMBNAIL_CACHE_DIR`) | user's library (flag ignored) |
| `PHOCASA_DEVELOPMENT_LIBRARY` = anything else (`0`, empty, `true`) | user's library | user's library |
| `XCTestConfigurationFilePath` (any value) | in-memory; disk cache only at `PHOCASA_THUMBNAIL_CACHE_DIR` | same |
| `XCTestConfigurationFilePath` + `PHOCASA_DEVELOPMENT_LIBRARY=1` | **in-memory** (test host wins) | same |

Only the exact value `1` turns it on. An environment variable, not a launch argument: `ProcessInfo` reads it in one
place, and a launch argument would also land in the `UserDefaults` argument domain.

### How the flag combines with `XCTestConfigurationFilePath`

The hand-off suggested the development flag should win over the test host. I made the **test host win** instead:

- The scheme's Test action has `shouldUseLaunchSchemeArgsEnv = "YES"` (Xcode's default), so it shares the Run
  action's environment. If anyone adds `PHOCASA_DEVELOPMENT_LIBRARY=1` to the scheme's Run environment (the natural
  way to use it from Xcode), a "flag wins" rule would put every unit-test run on the shared on-disk development store,
  which the user ruled out ("tests must not share state across runs or worktrees"). With "test host wins", nothing in
  a test run can turn development mode on.
- The coordinator loses nothing: the only things `XCTestConfigurationFilePath` changes in the app are the store and the
  cache (`grep` finds no other use), and the flag replaces both. So a development launch sets only the flag, and the
  in-memory launch sets only `XCTestConfigurationFilePath`, as today. Setting both gives the in-memory launch (safe
  either way: neither touches the user's library).

## What changed

| File | Change |
|---|---|
| `Models/LibraryLocation.swift` (new) | `LibraryLocation`: `Store` (`.inMemory`, `.user(applicationSupport:)`, `.development(URL)`), `thumbnailCacheDirectory`, the pure `resolve(…)`, `current` (this launch, read once), `prepareStore(fileManager:)` (nil for in-memory; `StoreLocation.prepare` for the user's library; only `createDirectory` of the development folder for the development library). `isDebugBuild` from `#if DEBUG`. |
| `PhocasaApp.swift` | `isTestHost` removed; the container's configuration is `LibraryLocation.current.prepareStore()` (a file URL, or in-memory for nil). |
| `Services/ImageLoader.swift` | `shared` uses `LibraryLocation.current.thumbnailCacheDirectory`. `diskCacheDirectory(environment:)` removed (its rules moved into `resolve`, unchanged). |
| `Services/ThumbnailDiskCache.swift` | `defaultDirectory(in: caches, bundleIdentifier:)`, `directory(in: folder)` (`<folder>/Thumbnails/v1`) and `userCachesDirectory`, so `resolve` can take the Caches folder as a parameter. `defaultDirectory`'s value is unchanged. |
| `PhocasaTests/LibraryLocationTests.swift` (new) | 9 tests of `resolve` (below). |
| `PhocasaTests/StoreLocationTests.swift` | 4 development-library tests on a temp folder standing in for Application Support; a `RecordingFileManager` that records every path `prepareStore` asks about. |
| `PhocasaTests/ThumbnailDiskCacheTests.swift` | `testDiskCacheDirectorySelection` checks the same four rules through `LibraryLocation.resolve` (temp-style paths in place of the real Caches folder), plus `defaultDirectory(in: userCachesDirectory) == defaultDirectory`. |
| `CLAUDE.md` | "Development library" in Key Design Decisions (after "Store location"); `LibraryLocation` in the project structure; a Testing line. The Metadata section is untouched. |
| `Tools/coordinator/README.md` | "Checking the real app…" now resets the development folder, launches with the flag, checks `lsof`, and has a relaunch step (Cmd-Q, not `kill`; `sqlite3` on the development store only, with the app quit). The in-memory launch stays as the alternative. The "Relaunch with the disk cache" lesson no longer reopens the folder. |
| `docs/…/results/B.md` | This file. |

## Tests added (13), each seen failing first

**Red run** (`B-red`): the tests against a stub `resolve` that accepted `isDebugBuild` but ignored the flag (today's
rules). **8 of the 13 failed, with 23 assertion failures**:

| Test | Failure against the stub |
|---|---|
| `LibraryLocationTests.testTheDevelopmentFlagInADebugBuildOpensTheDevelopmentLibrary` | store `user(…)` ≠ `development(<appSupport>/Phocasa-Development/Phocasa.store)`; cache `<caches>/com.phocasa.app/Thumbnails/v1` ≠ `<appSupport>/Phocasa-Development/Thumbnails/v1` |
| `…testTheDevelopmentCacheIsNeverInTheCachesFolder` | the cache was `<caches>/com.phocasa.app/Thumbnails/v1` (all 3 assertions) |
| `…testTheCacheOverrideAppliesToTheDevelopmentLibrary` | cache ≠ the override; store `user(…)` |
| `…testTheDebugFlagDefaultsToTheBuildConfiguration` | store `user(…)` with the default Debug flag |
| `StoreLocationTests.testTheDevelopmentLibraryKeepsItsStoreInItsOwnFolder` | URL `<temp>/Phocasa/Phocasa.store`; no development folder; `["Phocasa"]` made |
| `…testTheDevelopmentLibraryLeavesTheRealAndLegacyStoresAlone` | URL was the real store; paths outside the development folder recorded; the "real" store gained the development row (`["development", "real"]`) |
| `…testTheDevelopmentLibraryRunsNoLegacyMove` | the legacy store was moved into `Phocasa/` (`.default_SUPPORT/…` → `Phocasa/.Phocasa_SUPPORT/…`); a Phocasa folder made |
| `…testTheDevelopmentLibrarySurvivesARelaunch` | URL `<temp>/Phocasa/Phocasa.store`; a Phocasa folder made |

(Every red-run store was in the test's temp folder.)

**Guard tests.** Five tests describe behaviour that exists today, so they passed against the stub. To show they bite, I
ran them against a **mutated** `resolve` (no Debug check, any non-empty flag value, the flag checked before the test
host, and `XCTestConfigurationFilePath=/dev/null/in-memory` not counted as a test host). **4 failed**:
`testAReleaseBuildIgnoresTheDevelopmentFlag`, `testADebugLaunchWithoutTheFlagOpensTheUsersLibrary`,
`testTheTestHostStaysInMemory`, `testTheTestHostWinsOverTheDevelopmentFlag`. The mutations were chosen so this test
host's own location couldn't change. The fifth, `testThisTestRunUsesAnInMemoryStore` (`LibraryLocation.current` is
in-memory, and its cache is `ImageLoader.shared`'s), has no safe mutation: breaking it would make the test host open
the user's real store or Caches, so it wasn't mutated.

| Test | Checks |
|---|---|
| `LibraryLocationTests.testTheDevelopmentFlagInADebugBuildOpensTheDevelopmentLibrary` | store `Phocasa-Development/Phocasa.store`, cache `Phocasa-Development/Thumbnails/v1` |
| `…testTheDevelopmentCacheIsNeverInTheCachesFolder` | the development cache isn't under the given Caches folder, has no `com.phocasa.app`, and isn't the default directory |
| `…testTheCacheOverrideAppliesToTheDevelopmentLibrary` | `PHOCASA_THUMBNAIL_CACHE_DIR` moves the cache only |
| `…testAReleaseBuildIgnoresTheDevelopmentFlag` | Release + flag (with and without the override) = the user's library and default cache |
| `…testADebugLaunchWithoutTheFlagOpensTheUsersLibrary` | no flag, `0`, empty, `true` = the user's library |
| `…testTheTestHostStaysInMemory` | `XCTestConfigurationFilePath` (`/x`, `/dev/null/in-memory`, Debug and Release) = in-memory, no cache |
| `…testTheTestHostWinsOverTheDevelopmentFlag` | test host + flag = in-memory; with the override, the override cache |
| `…testThisTestRunUsesAnInMemoryStore` | `LibraryLocation.current.store == .inMemory`; its cache is `ImageLoader.shared.diskCache?.directory` |
| `…testTheDebugFlagDefaultsToTheBuildConfiguration` | `isDebugBuild` is true in the Debug test build and is `resolve`'s default |
| `StoreLocationTests.testTheDevelopmentLibraryKeepsItsStoreInItsOwnFolder` | `prepareStore()` = `<temp>/Phocasa-Development/Phocasa.store`, makes that folder and nothing else; a store written there opens with its row; no `Phocasa/` or `default.store` |
| `…testTheDevelopmentLibraryLeavesTheRealAndLegacyStoresAlone` | a real store (`Phocasa/Phocasa.store`, current models) and a legacy `default.store` (the V1 helper, with external data): `prepareStore` asks the file manager about nothing outside the development folder; every file of both stores is still there, external data byte for byte; opened only afterwards, each store holds its own rows and the development store its own |
| `…testTheDevelopmentLibraryRunsNoLegacyMove` | only a legacy store (which a normal launch would move): it stays, and no `Phocasa/` is made |
| `…testTheDevelopmentLibrarySurvivesARelaunch` | a container on the development store, written (a binned photo, a rated one), released, `resolve`d and reopened: both rows, the bin flag and the rating kept |

The file-level checks compare file lists and non-SQLite bytes (`StoreLocationTests.snapshot`), not SQLite sizes: SQLite
checkpoints whenever SwiftData likes, even after the container is released, so the sizes of the `.store`/`-wal` files
aren't stable (CLAUDE.md, SwiftData). "Not opened" is shown by the recording file manager and the unchanged files;
nothing in the development path calls `StoreLocation` or Core Data.

## Suite

- `Tools/coordinator/runtests.sh <worktree> B-full` on `9ff20c1` (the later commits are docs only): `** TEST SUCCEEDED **`,
  `Executed 640 tests, with 41 tests skipped and 0 failures`. The only `warning:` lines are the two AppIntents
  notices. `MDB_MAP_FULL` lines are the known Metal usage-database noise (coordinator README).
- **Release build:** `xcodebuild -configuration Release build` (temp DerivedData) **fails on `main`'s code, not on this
  branch's**: `Library/LibraryStore+Loading.swift:108:73: error: sending 'context' risks causing data races`
  (`modelContext === context` inside `nextTurn()`, a main-actor closure capturing the task-isolated `context`). That
  file is untouched here; the diagnostic only appears under Release's whole-module build. No error or warning names a
  file this branch changed, so `LibraryLocation`'s `#else` (Release) branch compiles. See Follow-ups.

## Launch cost

Nothing measurable. `LibraryLocation.current` reads `ProcessInfo.processInfo.environment` once and builds a few URLs;
before, `PhocasaApp.isTestHost` and `ImageLoader.diskCacheDirectory` each read it. The development path adds one
`createDirectory` (the folder usually exists). A normal launch runs the same `StoreLocation.prepare` as before.

## Deviations

- **The test host wins over the development flag** (above), not the reverse as suggested.
- `ImageLoader.diskCacheDirectory(environment:)` is gone rather than kept beside `LibraryLocation`, so there's one
  decision; its test now calls `resolve` with the same four rules.
- The development cache defaults to `Phocasa-Development/Thumbnails/v1` (the hand-off's example), so resetting the
  development folder resets the cache too.

## Follow-ups

- **`main` doesn't build in Release** (above): `LibraryStore+Loading.swift:108`, region-based isolation in the
  background launch's `nextTurn()`. Debug builds and the test suite are fine. Not fixed here (outside task B); worth a
  small task before anyone makes a Release build.
- The coordinator's three real-app checks (Move to Bin across a relaunch; a 500+ library loading in the background;
  the backfill of an existing library after clearing `captureDate` with `sqlite3`), with the new procedure. I didn't
  launch the app (hand-off rule).
- A development launch still shares the app's `UserDefaults` domain (`com.phocasa.app`) and saved window state with
  the real app, as the in-memory launch does today. The app itself stores nothing there (`grep` finds no
  `UserDefaults`/`@AppStorage`), so only SwiftUI's window frame is shared.
