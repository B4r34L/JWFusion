# JW Fusion

Cross-platform merger for `.jwlibrary` backup files. Select multiple backups,
merge them without losing data, export one unified backup.

Targets: **Windows Desktop** and **Android** now; iOS/macOS later (the engine
is pure Dart and already platform-agnostic).

## Project layout (Clean Architecture)

```
lib/
  domain/            Pure Dart business logic - no Flutter imports
    merge/
      jw_merge_engine.dart    The Smart Merge engine (core of the app)
      backup_manifest.dart    manifest.json parsing/generation
      merge_report.dart       Result/statistics types
    settings/
      app_settings.dart       Global flags (askUserOnConflict, ...)
  infrastructure/    Adapters touching the platform
    archive/
      jwlibrary_archive.dart  ZIP extract/repack for .jwlibrary files
    database/
      sqlite_bootstrap.dart   Native sqlite3 loading (Windows CLI)
  presentation/      UI widgets (Phase 3)
  main.dart          App entry point
bin/
  jw_fusion_cli.dart Console test harness (Phase 2 verification)
```

## How the Smart Merge works

1. Every input archive is unzipped to an isolated temp folder.
2. The **newest** backup (its database `LastModified` value) becomes the
   base and is copied verbatim - so the output always starts from a
   byte-perfect official database.
3. Each remaining backup is merged into the base, newest first. Records are
   matched by **natural keys**, never raw integer ids:
   Note -> `Guid`, UserMark -> `UserMarkGuid`, Tag -> `(Type, Name)`,
   Location -> its schema UNIQUE tuples, IndependentMedia -> content `Hash`,
   Bookmark -> `(PublicationLocationId, Slot)`, InputField ->
   `(LocationId, TextTag)`, PlaylistItem -> full content signature.
4. New records get freshly incremented primary keys with all foreign keys
   remapped. Conflicts resolve by **latest timestamp wins**
   (`Note.LastModified`, `UserMark.Version`; otherwise the newer backup).
5. Bookmark slot collisions move the older bookmark to a free slot (0-9)
   instead of deleting it.
6. Orphaned rows that JW Library itself sometimes leaves in real backups
   (dangling BlockRange/TagMap references) are repaired, so the merged file
   is healthier than its inputs.
7. The database passes `foreign_key_check` + `integrity_check`, gets
   VACUUMed, a fresh `manifest.json` with the correct SHA-256 hash is
   generated, and everything (including playlist media files) is zipped
   into a valid `.jwlibrary`.

Backups with older database schemas merge their notes, highlights, tags and
bookmarks; legacy-format playlists/tag-positions are skipped with a clear
warning rather than corrupted.

## Phase 2: test from the Windows terminal

```powershell
cd jw_fusion
flutter pub get

# One-time: put a 64-bit sqlite3.dll in this folder (only the CLI needs it;
# the Flutter app bundles its own). Download "Precompiled Binaries for
# Windows" (sqlite-dll-win-x64) from https://www.sqlite.org/download.html

dart run bin/jw_fusion_cli.dart -o merged.jwlibrary "backup1.jwlibrary" "backup2.jwlibrary"
```

The CLI prints progress, a per-table added/updated/skipped report, any
warnings, and the integrity check result. Exit code 0 = clean merge.

Import the merged file into JW Library to verify, or inspect it directly:

```powershell
tar -xf merged.jwlibrary -C temp_check   # .jwlibrary is a ZIP
```

## Phase 3: run the desktop app

The repo ships only Dart/Flutter sources; generate the platform folders once,
then run:

```powershell
cd jw_fusion
flutter create . --platforms=windows,android --project-name jw_fusion
flutter pub get
flutter run -d windows
```

The app is one dashboard with three states: add files / merging (live
percentage) / success (checkmark + "Choose where to save it"). The merge
runs in a background isolate, so the window stays responsive. Original
backup files are never modified.

## Roadmap

- [x] Phase 1 - Project structure & dependencies
- [x] Phase 2 - Pure Dart merge engine + CLI verification
- [x] Phase 3 - Windows desktop GUI (idle / processing / success states)
- [x] Phase 4 - Android build, storage permissions, responsive layout

### Efficiency & UI improvements (in progress)

- [x] Merge engine uses cached prepared statements for per-row inserts/updates
      instead of re-parsing SQL on every row
- [x] `VACUUM` only runs when the merge actually removed/changed enough data
      to be worth the full database rewrite
- [x] App follows the OS light/dark setting instead of always rendering light
<<<<<<< HEAD
- [ ] Drag-and-drop: drop `.jwlibrary` files anywhere on the idle screen
- [x] Cancel button while a merge is processing (stops and discards, original
      backups untouched either way)
- [x] Settings screen exposing the `askUserOnConflict` toggle (now persisted
      across restarts)
- [ ] Success screen shows a friendly per-category breakdown (Notes,
=======
- [x] Drag-and-drop: drop `.jwlibrary` files anywhere on the idle screen
- [x] Cancel button while a merge is processing (stops and discards, original
      backups untouched either way)
- [x] Settings screen exposing the `askUserOnConflict` toggle
- [x] Success screen shows a friendly per-category breakdown (Notes,
>>>>>>> c7791d6cf629c92cb25443109af22361a118978e
      Highlights, Bookmarks, Tags, Playlists) instead of one combined total

### Play Store release checklist

- [x] Real applicationId (`com.b4r34l.jwfusion`, was `com.example.jw_fusion`)
- [ ] Generate upload keystore + `android/key.properties` (see comment atop
      `android/app/build.gradle.kts`) - release currently falls back to debug
      signing, which Play Console will reject
- [ ] Replace the default Flutter launcher icon with real app branding
- [ ] Build and upload an `.aab`, not the `.apk` (`flutter build appbundle`)
- [ ] Privacy policy URL + Data Safety form (app makes no network calls /
      collects no data, so this should be a quick "no data collected" answer)
- [ ] Store listing: screenshots, feature graphic, description
