# Release: ready for a real 2 TB collection

After task D (`post-wave-3-D.md`) the user asked for the app to be finished and ready for release and daily use on
their real 2 TB collection, with **no more performance work**. Three read-only audits looked for what would break,
lose data, or feel unfinished on a real collection:
- **data safety:** every path that touches the user's files or library, probed on temp files and exFAT/FAT32 images;
- **scale:** a gated measurement class (`ScaleChecks`, `PHOCASA_SCALE=1`) on 10k–150k APFS clones of the bench pairs,
  with temp stores;
- **UX and release configuration.**

Their findings became release branches, each done by a worktree subagent, reviewed and merged by the coordinator.

| Merge | Branch | What |
|---|---|---|
| `3709b07` | REL-2a | One window and one library per launch; a lock per library; a store that won't open is explained, not a crash; daily store backups |
| `a10113e` | REL-2b | Scans skip other apps' libraries; a failed store read or an unplugged drive isn't an empty library; deletes change only what reached the Trash; queued writes survive a quit or crash |
| `078a335`, `e479de7` | REL-1 | The detail view acts on the photo on screen; exports never overwrite a non-JPEG and trash the original first; confirmed file-type deletes; presets keep only the look; edits saved at quit. `e479de7`: a RAW's sidecar goes to the Trash only once the RAW has (found merging REL-1 and REL-2b) |
| `7d08005` | REL-5 | Moved, renamed and remounted photos keep their rows; every library folder is rescanned; the Folders sidebar |
| `b828df6` | REL-4 | Write problems shown with Retry; the status bar no longer covers content; menus; sort and zoom remembered; accessible controls; readable stars |
| `7b8d77e` | REL-3 | No multi-second freezes at 150k photos; Edit › Undo and Redo |
| `d34a081` | (coordinator) | A guard test: the photo keys reach the photos with the sidebar's list as first responder; the coordinator README's key-window lesson |


REL-1, REL-2a and REL-2b were combined on an integration branch (their conflicts resolved there, the sidecar fix
added), which passed the full suite and a Release build before `main` was fast-forwarded to it. REL-5 and REL-4 were
merged into `main` one at a time, with the full suite after each.

## Suite after each merge

| After | Result |
|---|---|
| task D (`8a0f33c`) | 801 executed, 35 skipped, 0 failures (gated real-file tests on) |
| REL-2a + REL-2b + REL-1 + the sidecar fix (`e479de7`) | 891 / 35 / 0 (gated real-file tests on); Release build OK |
| REL-5 (`7d08005`) | 921 / 48 / 0 |
| REL-4 (`b828df6`) | 973 / 48 / 0; Release build OK, no warnings |
| REL-3 (`7b8d77e`), gated real-file tests on | 1004 / 41 / 0; Release build OK, no warnings |
| final `main` (`d34a081`), gated real-file tests on | **1005 executed, 41 skipped, 0 failures**, 0 source warnings |

## What was wrong, and what each branch changed

### REL-2a: one library per launch, and a store that's never lost
- **Two windows, two libraries:** a `WindowGroup` with the view model in `ContentView`'s `@State` gave every window
  or tab its own `LibraryStore` on the shared store; closing the window mid-scan and clicking the Dock icon ran a
  second scan that inserted every photo again. Now a single `Window` (no New Window, no tabs), the view model owned by
  the app, and `setModelContext` a no-op for the context it already has. **Closing the window quits the app** (a
  `Window` scene's standard behaviour; the quit-time write flush is then the only way the library goes away).
- **Two processes on one store** (a Debug run beside the installed app): `LibraryLock`, a `flock` on `Phocasa.lock` in
  the library's folder, taken before anything else; a second copy shows "Phocasa is already open with this library"
  and opens nothing (checked in the real app).
- **A store that can't be opened** crashed every launch (`fatalError`). Now `LibraryUnavailableView` says where the
  store is, that nothing was changed, and where the backups are. SwiftData renames and removes nothing when a store
  fails; a file that isn't SQLite at all is refused before SQLite sees it (which would otherwise rewrite its `-shm`).
- **Backups:** `StoreBackup` copies the store, `-wal`, `-shm` and `.Phocasa_SUPPORT` (APFS clones) into
  `Application Support/Phocasa/Backups/<date>/` at launch, before the store opens: at most one a day, the newest 5
  kept, pruned only after a launch that opened the store; never another app's `default.store`. Restore: quit, move the
  live files aside, copy a backup's files in (CLAUDE.md, "Backups").

### REL-2b: the library never loses or duplicates photos or writes
- **The scanner walked into other apps' libraries** (probed: `Photos Library.photoslibrary` originals and
  derivatives, Lightroom smart previews as RAWs, Synology `@eaDir`); ratings would then have written into Photos'
  originals. Now `.skipsPackageDescendants` plus a list of library and NAS folders by name.
- **A failed store read looked like an empty library,** so a scan would have inserted every photo again (worse: an
  unreadable store made `fetchCount` return `NSNotFound` and the launch trapped). Those reads throw now; the scan
  stops and says so.
- **A delete that couldn't reach the file still changed the library** (Empty Bin with the drive unplugged, locked
  files, shares without a Trash): `FileTrasher` reports each file; only photos whose files went are removed, and an
  alert says how many couldn't be and why.
- **An unplugged drive looked like an empty library** ("No Photos – Open a folder"): now the scan is skipped, nothing
  is marked missing, and the grid says the drive isn't connected, with Rescan.
- **Writes still queued at quit were dropped** after 5 s (a bulk rating of thousands of photos on an external drive
  takes minutes): `MetadataWriteJournal` keeps them in `PendingMetadataWrites.jsonl` beside the store, replayed first
  at the next launch; "Saving to files… N left" in the status bar.

### REL-1: actions that did the wrong thing to the user's photos
- **⌫ in the detail view binned the hidden grid's selection,** not the photo on screen (open A, → to D, ⌫: A went to
  the Bin; from a 200-photo selection, all 200). Delete, Restore, Delete Forever and the tag popover now act on the
  photo on screen, then move on; ⌘A and Return do nothing there.
- **The detail view stranded itself** when its photo left the filter (culling in "Unrated"): it now keeps its place.
- **Exports:** a JPG edit's "Replace existing JPG" rendered the **RAW** over the camera JPG; "Apply edits permanently"
  could write JPEG bytes over a **HEIC, PNG or TIFF** original. The dialog now depends on the session and the files'
  bytes; a replace is refused unless the file is a JPEG by its bytes; **a copy of the original goes to the Trash
  first** (nothing is written if it can't); replacing the camera JPG clears its now-meaningless saved JPG edit.
- **"-raw-edit" exports** switched the photo's JPG to the export until the next rescan, and overwrote an earlier one.
  Now the export is a photo of its own right away, beside the original, with a free name (`-raw-edit-2`, …).
- **With the RAW or JPG filter on, Delete trashed files with no confirmation** (⌘A + ⌫ under RAW trashed every RAW).
  It asks now, naming the count and the file type.
- **Presets stored crop, rotation and flips,** so applying one to a selection cropped every photo; they keep only the
  look now. Revert and Revert All ask first.
- **An open edit wasn't saved at ⌘Q;** it is now, before the write flush.

### The sidecar fix (found merging REL-1 and REL-2b, `e479de7`)
A RAW's sidecar was trashed in the same batch as the RAW, so a RAW that couldn't be moved stayed in the library without
its rating, keywords and edits. The sidecar now goes only once its RAW has.

### REL-5: moving, renaming and remounting
- **A photo's identity is its path,** so moving a folder, renaming the root, a drive remounting as `/Volumes/Photos 1`
  or copying to a new drive gave every photo a new row and orphaned what lives only in the store (JPG edits, bin
  state). Now a scan relinks: the same path inside a folder that moved (the bookmark finds it), or the same file names
  and capture date (size and creation date when there's no capture date) when exactly one missing row and one new
  photo match; anything ambiguous is inserted as before. (Not size: every in-file rating write changes it.)
- **Only the last folder opened was ever rescanned.** Every folder opened stays a library folder and is rescanned; a
  folder inside another isn't a second root; the sidebar's Folders section has Rescan, Show in Finder and Remove from
  Library… (store rows only, confirmed).

### REL-4: failures the user can see, and the finish
- **Failed writes were silent** (read-only files and folders, locked files, full disks, NTFS drives): each write now
  reports what it did; the status bar shows "⚠︎ N files not updated" (and "kept in a sidecar"), with Show in Finder and
  Retry (the photo's current values).
- The status bar covered the grid's last row and the edit controls; counts said "1 photos"; Return didn't add a tag;
  nothing was remembered across launches (now the sort and zoom); menus had only Open Folder (now Library, Photo and
  View menus with shortcuts, off while typing); no visible way back from the detail view ("‹ Library"); the detail
  view's controls weren't buttons; a damaged file spun forever; stars were unreadable in light mode; no accessibility
  labels.

### REL-3: no freezes at the user's scale, and undo
The user asked for no performance work. These were the window freezing for seconds to minutes on ordinary actions at
their collection's size, so they were fixed as breakage, measured by the gated `ScaleChecks` (a main-queue heartbeat
every ~5 ms; temp stores; APFS clones of the bench pairs, a third with keywords).

| Longest main-thread block (ms) | 50k before → after | 150k before → after |
|---|---|---|
| first scan (empty store) | 818 → 298 | 2,464 → 901 |
| rate the whole selection | 7,205 → 225 | 22,677 → 579 |
| tag / untag 5,000 photos | 1,602 / 18,276 → 113 / 105 | 1,812 / 18,825 → 215 / 172 |
| move 5,000 to the bin / restore | 856 / 929 → 92 / 204 | 1,108 / 1,194 → 217 / 323 |
| ⌘A in the grid | 7,369 → 78 | 22,436 → 91 |
| rescan after every file's size changed (after a bulk rating) | 8,090 → 78 | 25,463 → 224 |
| empty a bin of 1,000 tagged photos | 1,172 → 338 | 3,866 → 767 |
| rate one photo | 53 → 34 | 174 → 129 |

- **Tagging was quadratic** (SwiftData rewrites a tag's whole inverse list for each photo-side change): links change
  on the tag's side, once per tag and chunk; checked that the store holds exactly the same links after a relaunch.
- **Select all** made every visible cell work out the selection's common tags: cached per selection change.
- **Big changes were one save** (about 1 µs per loaded photo plus 0.1–0.15 ms per row): memory, counts and the grid
  update at once, and the rows are written in chunks sized by time (`LibraryStore+RowWrites`, `WriteChunkSizer`), a
  photo's later change winning; its file write is made from the row once it's written, so a file never gets a value
  the store doesn't hold. Quit, full loads, scans, the detail view and edits write or wait for what's queued.
- **The first scan's inserts** are sized by time, and facts are built chunk by chunk.
- **Undo** (⌘Z / ⇧⌘Z): rating, adding and removing a tag, the bin and back, applying a preset; named ("Undo Rating").
  An undo restores each photo's previous values and writes them to the files like any change. Permanent deletes,
  file-type deletes, exports and Revert All aren't undoable (they ask first).
- **What's left:** a few blocks of 0.3–0.9 s at 150k (the first scan's last keyworded inserts, emptying a bin of 1,000
  tagged photos, restoring 5,000), set by SwiftData's own cost per save with 150k photos loaded (~140 ms) and per tag
  link. Removing that needs a schema change (tags stored differently): a decision for after real use.

## Real-app check (development mode, 2026-09-26, 20:05–20:45)

A Debug build of `main` (`7b8d77e`, the app code of the final `main`), `PHOCASA_DEVELOPMENT_LIBRARY=1`, the
development folder reset first; `lsof` showed only the development store. Photos: a local folder of 14 copies
(12 pairs, one made RAW-only, two rotated) and a 300 MB APFS disk image, "PhocasaCheck", standing in for an external
drive, with 6 pairs in `Trips/2013` (copies; `~/PhocasaBenchRAW` only read). Both folders opened.

| Check | Result |
|---|---|
| Library folders (REL-5) | the sidebar's Folders section lists `local` and `Trips`; 20 photos |
| Photo › Rate › 5 Stars, then Edit › Undo (REL-4 menus, REL-3 undo) | 5 in the store, then back to 3 |
| Photo › Move to Bin, then Undo | binned, then back |
| RAW filter, then Photo › "Delete RAW File…" (REL-1) | "Move 1 RAW file to the Trash? The JPGs stay in the library." Cancel: all three files still there |
| A read-only JPG rated (REL-4) | its RAW's sidecar got the rating; the status bar said "⚠︎ 1 file not updated"; the popover named the file ("The file is read-only."), with Show in Finder, Retry, Clear List, Retry All; made writable, **Retry wrote the rating into the JPG** (ImageIO read 2) |
| The status bar (REL-4) | below the grid, not over its last row |
| The drive image detached, relaunch (REL-2b, REL-5) | the sidebar marks `Trips` "Not connected"; the status bar: "“PhocasaCheck” isn't connected. Connect the drive and choose Rescan."; the 14 local photos shown; **all 20 rows still in the store** |
| Re-attached **renamed** to "PhocasaCheck2", Rescan (REL-5) | still 20 photos, no duplicate; the 6 relinked to `/Volumes/PhocasaCheck2/…`, ratings kept |
| `Trips/2013` renamed `2013-bangkok` in the shell, Rescan | the 6 relinked to the new folder, ratings kept |
| A pair's RAW edit, the export dialog (REL-1) | "Export RAW Edit", explaining both options; "Save as New JPG" (default), "Replace DSC08705.JPG…" (red), Cancel |
| Save as New JPG | `DSC08705-raw-edit.jpg` beside the original, a photo of its own (21 photos), its rating inside the file; the original's paths unchanged; after a relaunch still 21 |
| Relaunch (REL-2a) | one daily backup, `Backups/2026-09-26-204422`; the library back without reopening a folder |
| Earlier, on `e479de7` | a second copy on the same library: "Phocasa is already open with this library", no store opened |
| After | the 20 RAW files byte-identical (SHA-256); no `.phocasa-tmp` files; no `~/Library/Caches/com.phocasa.app`; `~/PhocasaBenchRAW` unchanged; only `Phocasa-Development/` under Application Support |

**The keyboard, and a detour.** In this session the app's window, launched from the terminal, was frontmost but never
key (`AXFocused` false, whatever was tried), so synthetic key presses vanished while clicks still worked. It looked
like the photo keys were broken after a launch, and after a long hunt it wasn't: `KeyboardShortcutTests` (a key
hosted window) passes on `main`, and a new test there shows digits, arrows, Space, Esc and ⌫ reach the photos even
with the sidebar's list as first responder, which is where AppKit puts it at launch. Earlier in the day the same
checks drove the keys fine (task D's check rated by keyboard). The coordinator README now says to check the key window
before testing keys. **For you to confirm in your first minute of use:** launch Phocasa from the Dock, click a photo,
press 3, → and ⌫ (then ⌘Z).

## Follow-ups

- **SwiftData at 150k:** a few actions still block 0.3–0.9 s (the first scan's last inserts, emptying a bin of 1,000
  tagged photos); fixing that needs a schema change (REL-3).
- **Write problems** last one session (a relaunch forgets a rating that never reached a read-only drive); saving them
  beside the write journal would fix it (REL-4).
- **Keywords changed by other apps after import** are overwritten by Phocasa's next write of that photo (metadata is
  read only when a photo is first found). A rescan could re-read changed files (question 1 below).
- **Several files with one stem in a folder** (`IMG_1.JPG` + `IMG_1.HEIC`, `x.CR2` + `x.DNG`): only one JPG-like file
  and one RAW become the photo; the others aren't shown.
- **A journalled write for a photo whose drive remounted under a new name** stays at the old path; the next change
  to that photo writes the new one (REL-5).
- **Relinking and a backup drive:** rows on a drive that isn't connected can relink to a lookalike copy on another
  drive (nothing is lost either way; REL-5).
- **Scan progress and delete-problem texts** aren't pluralised yet ("1 new photos").
- **The app icon** is the 322 px PNG scaled up (soft at large sizes, a wordmark unreadable at 16 px); **signing** is
  ad hoc (each rebuild looks like a new app to macOS's privacy prompts).
- From task D: `post-wave-3-D.md`'s follow-ups.

## Decisions for the user

1. **Other apps editing the same files:** re-read files that changed on disk at each rescan? (Recommended if you also
   rate or tag in Lightroom or Bridge.)
2. **File dates:** Phocasa puts back a file's modification date after writing its rating, so size-and-date backup
   tools (rsync, Carbon Copy Cloner's default) may skip a changed rating of the same size; Time Machine isn't affected.
   Keep, or let the date change?
3. **Closing the window quits the app** (a single `Window`); keep it running instead?
4. **Undo and bulk actions:** there's undo now; also confirm actions on more than N photos?
5. **Signing and icon:** a free Apple team ID in Xcode, and a high-resolution icon source.
