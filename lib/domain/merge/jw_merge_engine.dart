import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../infrastructure/archive/jwlibrary_archive.dart';
import '../settings/app_settings.dart';
import 'backup_manifest.dart';
import 'merge_report.dart';

/// Progress callback: [progress] is 0.0..1.0, [message] is a short
/// human-readable description of the current stage.
typedef MergeProgress = void Function(double progress, String message);

/// Merges any number of `.jwlibrary` backups into a single valid backup.
///
/// Strategy ("Smart Merge"):
/// * The newest backup (by its database `LastModified` value) becomes the
///   BASE. Its database is copied verbatim to the output, so the base is
///   always a byte-perfect, schema-correct JW Library database.
/// * Every other backup is merged INTO the base, newest first. Records are
///   matched on their natural keys, never on raw integer primary keys:
///     - Note            -> Guid (UNIQUE)
///     - UserMark        -> UserMarkGuid (UNIQUE)
///     - Tag             -> (Type, Name)
///     - Location        -> full column tuple / schema UNIQUE constraints
///     - IndependentMedia-> content Hash
///     - Bookmark        -> (PublicationLocationId, Slot)
///     - InputField      -> (LocationId, TextTag)
///     - PlaylistItem    -> full content signature (label, trims, media
///                          hashes, locations, markers)
/// * Unique records are inserted with freshly assigned primary keys and all
///   foreign keys remapped.
/// * Conflicting records use "latest timestamp wins": Note rows compare
///   their own LastModified column; UserMark rows compare Version; tables
///   without per-row timestamps resolve in favour of the newer backup
///   (guaranteed by processing sources newest-to-oldest and keeping the
///   first record seen).
///
/// The engine is pure Dart (dart:io + sqlite3 + archive + crypto) so it runs
/// identically from a terminal on Windows and inside the Flutter app on
/// Android/iOS/macOS. Platform specifics (file picking, temp directories)
/// are injected by the caller.
class JwMergeEngine {
  JwMergeEngine({this.onProgress, AppSettings? settings})
      : settings = settings ?? AppSettings.instance;

  final MergeProgress? onProgress;
  final AppSettings settings;
  final JwLibraryArchive _archive = const JwLibraryArchive();
  final Random _random = Random.secure();

  static const List<String> _playlistTables = <String>[
    'PlaylistItem',
    'PlaylistItemAccuracy',
    'PlaylistItemIndependentMediaMap',
    'PlaylistItemLocationMap',
    'PlaylistItemMarker',
  ];

  /// Minimum number of rows added/updated/repaired across the whole merge
  /// before a full `VACUUM` rewrite of the output database is worth its cost.
  static const int _vacuumRowThreshold = 200;

  /// Merges [inputPaths] (2 or more `.jwlibrary` files) and writes the
  /// result to [outputPath]. [workDir] is a scratch directory the engine
  /// may fill and that the caller owns (pass a fresh temp directory; the
  /// engine deletes its own subdirectories when finished).
  Future<MergeReport> merge({
    required List<String> inputPaths,
    required String outputPath,
    required Directory workDir,
  }) async {
    if (inputPaths.length < 2) {
      throw ArgumentError('At least two .jwlibrary files are required.');
    }
    final started = DateTime.now();
    final report = MergeReport();
    final session = Directory(
        p.join(workDir.path, 'jwfusion_${started.millisecondsSinceEpoch}'));
    await session.create(recursive: true);

    final sources = <_Source>[];
    Database? out;
    _MergeContext? ctx;
    try {
      // ---- 1. Extract every archive and open its database read-only. ----
      for (var i = 0; i < inputPaths.length; i++) {
        _progress(0.05 + 0.15 * (i / inputPaths.length),
            'Reading ${p.basename(inputPaths[i])}');
        final dir = Directory(p.join(session.path, 'src_$i'));
        await _archive.extract(File(inputPaths[i]), dir);
        sources.add(await _openSource(inputPaths[i], dir));
      }

      // ---- 2. Newest backup becomes the base. ----
      sources.sort((a, b) => a.lastModified.compareTo(b.lastModified));
      final base = sources.last;
      final others = sources.sublist(0, sources.length - 1).reversed.toList();

      for (final s in sources) {
        report.sources.add(SourceSummary(
          path: s.originalPath,
          lastModified: s.lastModified,
          schemaVersion: s.schemaVersion,
          isBase: identical(s, base),
        ));
      }

      final outDir = Directory(p.join(session.path, 'out'));
      await outDir.create(recursive: true);

      // Copy the base's full contents (database, thumbnail, media files).
      for (final f in base.dir.listSync().whereType<File>()) {
        final name = p.basename(f.path);
        if (name == 'manifest.json') continue; // regenerated below
        await f.copy(p.join(outDir.path, name));
      }
      final outDbPath = p.join(outDir.path, 'userData.db');
      base.db.dispose();
      base.disposed = true;

      out = sqlite3.open(outDbPath);
      out.execute('PRAGMA foreign_keys = OFF;'); // remapping handles FKs
      ctx = _MergeContext(out, outDir, report);
      ctx.loadBaseIndexes();

      // ---- 3. Merge every other source into the base, newest first. ----
      var done = 0;
      var rowsChanged = 0;
      for (final src in others) {
        _progress(0.25 + 0.55 * (done / others.length),
            'Merging ${p.basename(src.originalPath)}');
        out.execute('BEGIN;');
        try {
          _mergeSource(ctx, src);
          out.execute('COMMIT;');
        } on Object {
          out.execute('ROLLBACK;');
          rethrow;
        }
        done++;
      }
      for (final counts in report.tables.values) {
        rowsChanged += counts.added + counts.updated;
      }

      // ---- 4. Repair orphaned records (JW Library itself sometimes leaves
      // dangling rows behind in real backups; clean them so the merged file
      // is healthier than its inputs). ----
      _progress(0.82, 'Repairing orphaned records');
      final repaired = _cleanOrphans(ctx);
      if (repaired > 0) {
        rowsChanged += repaired;
        report.warnings.add(
            'Repaired $repaired orphaned record(s) inherited from the '
            'source backups.');
      }

      // ---- 5. Finalise the database. ----
      _progress(0.85, 'Finalising database');
      final nowIso = _isoNow();
      if (ctx.tableExists('LastModified')) {
        // Newer schemas (v15+) protect this table with RAISE triggers that
        // forbid INSERT/DELETE and keep it current automatically; UPDATE is
        // always the safe path, with INSERT only for old, empty tables.
        try {
          out.execute('UPDATE LastModified SET LastModified = ?;',
              <Object?>[nowIso]);
          final count = out
              .select('SELECT COUNT(*) AS c FROM LastModified;')
              .first['c'] as int;
          if (count == 0) {
            out.execute('INSERT INTO LastModified (LastModified) VALUES (?);',
                <Object?>[nowIso]);
          }
        } on SqliteException {
          // Trigger-guarded table already maintained by the schema itself.
        }
      }
      final fkIssues = out.select('PRAGMA foreign_key_check;');
      if (fkIssues.isNotEmpty) {
        report.warnings.add(
            'Foreign key check reported ${fkIssues.length} issue(s); '
            'first: ${fkIssues.first}');
      }
      final integrity = out.select('PRAGMA integrity_check;');
      report.integrityOk = fkIssues.isEmpty &&
          integrity.length == 1 &&
          integrity.first.values.first == 'ok';
      ctx.disposeStatements();
      // VACUUM rewrites the entire file, which is only worth the cost when a
      // meaningful number of rows actually changed - a merge of two backups
      // that were already almost identical shouldn't pay for a full rewrite.
      if (rowsChanged >= _vacuumRowThreshold) {
        _progress(0.88, 'Optimising database');
        out.execute('VACUUM;');
      }
      out.dispose();
      out = null;

      // ---- 6. Manifest + repack. ----
      _progress(0.92, 'Writing manifest and packaging');
      final dbBytes = await File(outDbPath).readAsBytes();
      final manifest = BackupManifest.forMergedBackup(
        name: p.basenameWithoutExtension(outputPath),
        databaseHash: sha256.convert(dbBytes).toString(),
        schemaVersion: base.schemaVersion,
        deviceName: settings.deviceName,
      );
      await File(p.join(outDir.path, 'manifest.json'))
          .writeAsString(manifest.toJsonString(), flush: true);

      await _archive.compressDirectory(outDir, File(outputPath));

      report.outputPath = outputPath;
      report.elapsed = DateTime.now().difference(started);
      _progress(1.0, 'Done');
      return report;
    } finally {
      ctx?.disposeStatements();
      out?.dispose();
      for (final s in sources) {
        if (!s.disposed) s.db.dispose();
      }
      try {
        await session.delete(recursive: true);
      } on FileSystemException {
        // Non-fatal: OS temp cleanup will collect leftovers.
      }
    }
  }

  // ---------------------------------------------------------------------
  // Source loading
  // ---------------------------------------------------------------------

  Future<_Source> _openSource(String originalPath, Directory dir) async {
    final dbFile = File(p.join(dir.path, 'userData.db'));
    if (!dbFile.existsSync()) {
      throw FormatException(
          'No userData.db found inside $originalPath - not a user data backup.');
    }
    final db = sqlite3.open(dbFile.path, mode: OpenMode.readOnly);

    var schemaVersion = 14;
    var lastModified =
        (await File(originalPath).stat()).modified.toUtc();
    final manifestFile = File(p.join(dir.path, 'manifest.json'));
    if (manifestFile.existsSync()) {
      final manifest =
          BackupManifest.fromJsonString(await manifestFile.readAsString());
      schemaVersion = manifest.schemaVersion;
      lastModified = manifest.parsedLastModified()?.toUtc() ?? lastModified;
    }
    // The database's own LastModified row is the most trustworthy signal.
    final tables = _tableNames(db);
    if (tables.contains('LastModified')) {
      final rows = db.select('SELECT LastModified FROM LastModified LIMIT 1;');
      if (rows.isNotEmpty) {
        final parsed = DateTime.tryParse(rows.first.values.first as String? ?? '');
        if (parsed != null) lastModified = parsed.toUtc();
      }
    }
    return _Source(
      originalPath: originalPath,
      dir: dir,
      db: db,
      tables: tables,
      lastModified: lastModified,
      schemaVersion: schemaVersion,
    );
  }

  static Set<String> _tableNames(Database db) => db
      .select("SELECT name FROM sqlite_master WHERE type = 'table';")
      .map((row) => row['name'] as String)
      .toSet();

  static Set<String> _columnNames(Database db, String table) => db
      .select('PRAGMA table_info($table);')
      .map((row) => row['name'] as String)
      .toSet();

  // ---------------------------------------------------------------------
  // Per-source merge
  // ---------------------------------------------------------------------

  void _mergeSource(_MergeContext ctx, _Source src) {
    final locMap = _mergeLocations(ctx, src);
    final mediaMaps = _mergeIndependentMedia(ctx, src);
    final markMap = _mergeUserMarks(ctx, src, locMap);
    final noteMap = _mergeNotes(ctx, src, locMap, markMap);
    final tagMap = _mergeTags(ctx, src);
    final playlistMap = _mergePlaylists(ctx, src, locMap, mediaMaps);
    _mergeTagMaps(ctx, src, tagMap, noteMap, locMap, playlistMap);
    _mergeBookmarks(ctx, src, locMap);
    _mergeInputFields(ctx, src, locMap);
  }

  // ---- Location ---------------------------------------------------------

  Map<int, int> _mergeLocations(_MergeContext ctx, _Source src) {
    final map = <int, int>{};
    if (!src.tables.contains('Location')) return map;
    final counts = ctx.report.counts('Location');

    for (final row in src.db.select('SELECT * FROM Location;')) {
      final oldId = row['LocationId'] as int;
      final key = _locationKey(row);
      final existing = ctx.locationsByKey[key];
      if (existing != null) {
        map[oldId] = existing;
        counts.skipped++;
        continue;
      }
      final newId = ++ctx.maxLocationId;
      try {
        ctx.execPrepared(
          'insertLocation',
          'INSERT INTO Location (LocationId, BookNumber, ChapterNumber, '
          'DocumentId, Track, IssueTagNumber, KeySymbol, MepsLanguage, Type, '
          'Title) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
          <Object?>[
            newId,
            row['BookNumber'],
            row['ChapterNumber'],
            row['DocumentId'],
            row['Track'],
            row['IssueTagNumber'],
            row['KeySymbol'],
            row['MepsLanguage'],
            row['Type'],
            row['Title'],
          ],
        );
        ctx.locationsByKey[key] = newId;
        map[oldId] = newId;
        counts.added++;
      } on SqliteException {
        // A UNIQUE constraint fired: an equivalent location exists in the
        // base under one of the schema's two natural keys (they can match
        // even when the full column tuple differs, e.g. differing Title).
        final matched = _findLocationByUniqueKeys(ctx.db, row);
        if (matched != null) {
          map[oldId] = matched;
          counts.skipped++;
        } else {
          ctx.report.warnings.add(
              'Location $oldId from ${p.basename(src.originalPath)} could '
              'not be merged (constraint conflict); dependent records were '
              'skipped.');
          counts.skipped++;
        }
      }
    }
    return map;
  }

  static String _locationKey(Row row) => <Object?>[
        row['BookNumber'],
        row['ChapterNumber'],
        row['DocumentId'],
        row['Track'],
        row['IssueTagNumber'],
        row['KeySymbol'],
        row['MepsLanguage'],
        row['Type'],
      ].map((v) => v?.toString() ?? '\u0000').join('\u0001');

  static int? _findLocationByUniqueKeys(Database db, Row row) {
    // UNIQUE(KeySymbol, IssueTagNumber, MepsLanguage, DocumentId, Track, Type)
    var rs = db.select(
      'SELECT LocationId FROM Location WHERE KeySymbol IS ? AND '
      'IssueTagNumber = ? AND MepsLanguage IS ? AND DocumentId IS ? AND '
      'Track IS ? AND Type = ?;',
      <Object?>[
        row['KeySymbol'],
        row['IssueTagNumber'],
        row['MepsLanguage'],
        row['DocumentId'],
        row['Track'],
        row['Type'],
      ],
    );
    if (rs.isNotEmpty) return rs.first['LocationId'] as int;
    // UNIQUE(BookNumber, ChapterNumber, KeySymbol, MepsLanguage, Type)
    rs = db.select(
      'SELECT LocationId FROM Location WHERE BookNumber IS ? AND '
      'ChapterNumber IS ? AND KeySymbol IS ? AND MepsLanguage IS ? AND '
      'Type = ?;',
      <Object?>[
        row['BookNumber'],
        row['ChapterNumber'],
        row['KeySymbol'],
        row['MepsLanguage'],
        row['Type'],
      ],
    );
    if (rs.isNotEmpty) return rs.first['LocationId'] as int;
    return null;
  }

  // ---- IndependentMedia -------------------------------------------------

  _MediaMaps _mergeIndependentMedia(_MergeContext ctx, _Source src) {
    final maps = _MediaMaps();
    if (!src.tables.contains('IndependentMedia')) return maps;
    final counts = ctx.report.counts('IndependentMedia');

    for (final row in src.db.select('SELECT * FROM IndependentMedia;')) {
      final oldId = row['IndependentMediaId'] as int;
      final oldPath = row['FilePath'] as String;
      final hash = row['Hash'] as String;

      final byHash = ctx.mediaByHash[hash];
      if (byHash != null) {
        maps.idMap[oldId] = byHash.id;
        maps.pathMap[oldPath] = byHash.filePath;
        counts.skipped++;
        continue;
      }

      var filePath = oldPath;
      if (ctx.mediaPathsInUse.contains(filePath)) {
        // Same name, different content: rename to keep both files.
        filePath = '${_randomHex(8)}_$oldPath';
        while (ctx.mediaPathsInUse.contains(filePath)) {
          filePath = '${_randomHex(8)}_$oldPath';
        }
      }
      final sourceFile = File(p.join(src.dir.path, oldPath));
      if (sourceFile.existsSync()) {
        sourceFile.copySync(p.join(ctx.outDir.path, filePath));
      } else {
        ctx.report.warnings.add(
            'Media file "$oldPath" listed in ${p.basename(src.originalPath)} '
            'was missing from the archive; its database entry was merged '
            'anyway.');
      }

      final newId = ++ctx.maxMediaId;
      ctx.execPrepared(
        'insertMedia',
        'INSERT INTO IndependentMedia (IndependentMediaId, OriginalFilename, '
        'FilePath, MimeType, Hash) VALUES (?, ?, ?, ?, ?);',
        <Object?>[
          newId,
          row['OriginalFilename'],
          filePath,
          row['MimeType'],
          hash,
        ],
      );
      ctx.mediaByHash[hash] = _MediaRef(newId, filePath);
      ctx.mediaPathsInUse.add(filePath);
      maps.idMap[oldId] = newId;
      maps.pathMap[oldPath] = filePath;
      counts.added++;
    }
    return maps;
  }

  // ---- UserMark + BlockRange ---------------------------------------------

  Map<int, int> _mergeUserMarks(
      _MergeContext ctx, _Source src, Map<int, int> locMap) {
    final map = <int, int>{};
    if (!src.tables.contains('UserMark')) return map;
    final counts = ctx.report.counts('UserMark');
    final rangeCounts = ctx.report.counts('BlockRange');

    // UserMark ids (already remapped) whose BlockRanges must be (re)written.
    final needRanges = <int, int>{}; // new UserMarkId -> old UserMarkId

    for (final row in src.db.select('SELECT * FROM UserMark;')) {
      final oldId = row['UserMarkId'] as int;
      final guid = row['UserMarkGuid'] as String;
      final mappedLoc = locMap[row['LocationId'] as int];
      final existing = ctx.userMarksByGuid[guid];

      if (existing != null) {
        map[oldId] = existing.id;
        final incomingVersion = row['Version'] as int;
        if (incomingVersion > existing.version) {
          // Latest version wins: replace the highlight and its ranges.
          if (mappedLoc == null) {
            counts.skipped++;
            continue;
          }
          ctx.execPrepared(
            'updateUserMark',
            'UPDATE UserMark SET ColorIndex = ?, LocationId = ?, '
            'StyleIndex = ?, Version = ? WHERE UserMarkId = ?;',
            <Object?>[
              row['ColorIndex'],
              mappedLoc,
              row['StyleIndex'],
              incomingVersion,
              existing.id,
            ],
          );
          ctx.execPrepared(
              'deleteBlockRangesForMark',
              'DELETE FROM BlockRange WHERE UserMarkId = ?;',
              <Object?>[existing.id]);
          ctx.userMarksByGuid[guid] = _UserMarkRef(existing.id, incomingVersion);
          needRanges[existing.id] = oldId;
          counts.updated++;
        } else {
          counts.skipped++;
        }
        continue;
      }

      if (mappedLoc == null) {
        ctx.report.warnings.add(
            'Highlight $guid skipped: its location could not be merged.');
        counts.skipped++;
        continue;
      }
      final newId = ++ctx.maxUserMarkId;
      ctx.execPrepared(
        'insertUserMark',
        'INSERT INTO UserMark (UserMarkId, ColorIndex, LocationId, '
        'StyleIndex, UserMarkGuid, Version) VALUES (?, ?, ?, ?, ?, ?);',
        <Object?>[
          newId,
          row['ColorIndex'],
          mappedLoc,
          row['StyleIndex'],
          guid,
          row['Version'],
        ],
      );
      ctx.userMarksByGuid[guid] = _UserMarkRef(newId, row['Version'] as int);
      map[oldId] = newId;
      needRanges[newId] = oldId;
      counts.added++;
    }

    if (needRanges.isNotEmpty && src.tables.contains('BlockRange')) {
      final byOldMark = <int, List<Row>>{};
      for (final row in src.db.select('SELECT * FROM BlockRange;')) {
        byOldMark
            .putIfAbsent(row['UserMarkId'] as int, () => <Row>[])
            .add(row);
      }
      needRanges.forEach((newMarkId, oldMarkId) {
        for (final row in byOldMark[oldMarkId] ?? const <Row>[]) {
          ctx.execPrepared(
            'insertBlockRange',
            'INSERT INTO BlockRange (BlockRangeId, BlockType, Identifier, '
            'StartToken, EndToken, UserMarkId) VALUES (?, ?, ?, ?, ?, ?);',
            <Object?>[
              ++ctx.maxBlockRangeId,
              row['BlockType'],
              row['Identifier'],
              row['StartToken'],
              row['EndToken'],
              newMarkId,
            ],
          );
          rangeCounts.added++;
        }
      });
    }
    return map;
  }

  // ---- Note ---------------------------------------------------------------

  Map<int, int> _mergeNotes(_MergeContext ctx, _Source src,
      Map<int, int> locMap, Map<int, int> markMap) {
    final map = <int, int>{};
    if (!src.tables.contains('Note')) return map;
    final counts = ctx.report.counts('Note');
    // Old schemas (v8) have no Created column; fall back to LastModified.
    final hasCreated = _columnNames(src.db, 'Note').contains('Created');

    for (final row in src.db.select('SELECT * FROM Note;')) {
      final oldId = row['NoteId'] as int;
      final guid = row['Guid'] as String;
      final mappedLoc = _mapNullable(row['LocationId'] as int?, locMap);
      final mappedMark = _mapNullable(row['UserMarkId'] as int?, markMap);
      final existing = ctx.notesByGuid[guid];

      if (existing != null) {
        map[oldId] = existing.id;
        final incoming = _parseTs(row['LastModified'] as String?);
        if (incoming != null &&
            (existing.lastModified == null ||
                incoming.isAfter(existing.lastModified!))) {
          // Latest timestamp wins.
          ctx.execPrepared(
            'updateNote',
            'UPDATE Note SET UserMarkId = ?, LocationId = ?, Title = ?, '
            'Content = ?, LastModified = ?, BlockType = ?, '
            'BlockIdentifier = ? WHERE NoteId = ?;',
            <Object?>[
              mappedMark,
              mappedLoc,
              row['Title'],
              row['Content'],
              row['LastModified'],
              row['BlockType'],
              row['BlockIdentifier'],
              existing.id,
            ],
          );
          ctx.notesByGuid[guid] = _NoteRef(existing.id, incoming);
          counts.updated++;
        } else {
          counts.skipped++;
        }
        continue;
      }

      final newId = ++ctx.maxNoteId;
      ctx.execPrepared(
        'insertNote',
        'INSERT INTO Note (NoteId, Guid, UserMarkId, LocationId, Title, '
        'Content, LastModified, Created, BlockType, BlockIdentifier) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);',
        <Object?>[
          newId,
          guid,
          mappedMark,
          mappedLoc,
          row['Title'],
          row['Content'],
          row['LastModified'],
          hasCreated ? row['Created'] : row['LastModified'],
          row['BlockType'],
          row['BlockIdentifier'],
        ],
      );
      ctx.notesByGuid[guid] =
          _NoteRef(newId, _parseTs(row['LastModified'] as String?));
      map[oldId] = newId;
      counts.added++;
    }
    return map;
  }

  // ---- Tag ----------------------------------------------------------------

  Map<int, int> _mergeTags(_MergeContext ctx, _Source src) {
    final map = <int, int>{};
    if (!src.tables.contains('Tag')) return map;
    final counts = ctx.report.counts('Tag');

    for (final row in src.db.select('SELECT * FROM Tag;')) {
      final oldId = row['TagId'] as int;
      final key = '${row['Type']}\u0001${row['Name']}';
      final existing = ctx.tagsByKey[key];
      if (existing != null) {
        map[oldId] = existing;
        counts.skipped++;
        continue;
      }
      final newId = ++ctx.maxTagId;
      ctx.execPrepared(
        'insertTag',
        'INSERT INTO Tag (TagId, Type, Name) VALUES (?, ?, ?);',
        <Object?>[newId, row['Type'], row['Name']],
      );
      ctx.tagsByKey[key] = newId;
      map[oldId] = newId;
      counts.added++;
    }
    return map;
  }

  // ---- Playlists ------------------------------------------------------------

  Map<int, int> _mergePlaylists(_MergeContext ctx, _Source src,
      Map<int, int> locMap, _MediaMaps mediaMaps) {
    final map = <int, int>{};
    if (!_playlistTables.every(src.tables.contains) ||
        !_playlistTables.every(ctx.tables.contains)) {
      if (src.tables.contains('PlaylistItem') ||
          src.tables.contains('PlaylistMedia')) {
        ctx.report.warnings.add(
            'Playlists in ${p.basename(src.originalPath)} use an older '
            'database schema and were skipped; notes, highlights, tags and '
            'bookmarks were merged normally.');
      }
      return map;
    }
    final expected = _columnNames(src.db, 'PlaylistItem');
    if (!expected.contains('ThumbnailFilePath') ||
        !expected.contains('Accuracy')) {
      ctx.report.warnings.add(
          'Playlists in ${p.basename(src.originalPath)} use an unsupported '
          'PlaylistItem layout and were skipped.');
      return map;
    }
    final counts = ctx.report.counts('PlaylistItem');

    // Accuracy lookup table.
    final accuracyMap = <int, int>{};
    for (final row in src.db.select('SELECT * FROM PlaylistItemAccuracy;')) {
      final desc = row['Description'] as String;
      final oldId = row['PlaylistItemAccuracyId'] as int;
      final existing = ctx.accuracyByDesc[desc];
      if (existing != null) {
        accuracyMap[oldId] = existing;
      } else {
        final newId = ++ctx.maxAccuracyId;
        ctx.execPrepared(
          'insertAccuracy',
          'INSERT INTO PlaylistItemAccuracy (PlaylistItemAccuracyId, '
          'Description) VALUES (?, ?);',
          <Object?>[newId, desc],
        );
        ctx.accuracyByDesc[desc] = newId;
        accuracyMap[oldId] = newId;
      }
    }

    final srcSignatures = _playlistSignatures(src.db);
    for (final row in src.db.select('SELECT * FROM PlaylistItem;')) {
      final oldId = row['PlaylistItemId'] as int;
      final signature = srcSignatures[oldId] ?? 'item:$oldId';
      final existing = ctx.playlistBySignature[signature];
      if (existing != null) {
        map[oldId] = existing;
        counts.skipped++;
        continue;
      }

      final newId = ++ctx.maxPlaylistItemId;
      final thumb = row['ThumbnailFilePath'] as String?;
      ctx.execPrepared(
        'insertPlaylistItem',
        'INSERT INTO PlaylistItem (PlaylistItemId, Label, '
        'StartTrimOffsetTicks, EndTrimOffsetTicks, Accuracy, EndAction, '
        'ThumbnailFilePath) VALUES (?, ?, ?, ?, ?, ?, ?);',
        <Object?>[
          newId,
          row['Label'],
          row['StartTrimOffsetTicks'],
          row['EndTrimOffsetTicks'],
          accuracyMap[row['Accuracy'] as int] ?? row['Accuracy'],
          row['EndAction'],
          thumb == null ? null : (mediaMaps.pathMap[thumb] ?? thumb),
        ],
      );
      ctx.playlistBySignature[signature] = newId;
      map[oldId] = newId;
      counts.added++;

      for (final m in src.db.select(
          'SELECT * FROM PlaylistItemIndependentMediaMap WHERE '
          'PlaylistItemId = ?;',
          <Object?>[oldId])) {
        final mediaId = mediaMaps.idMap[m['IndependentMediaId'] as int];
        if (mediaId == null) continue;
        ctx.execPrepared(
          'insertPlaylistMediaMap',
          'INSERT OR IGNORE INTO PlaylistItemIndependentMediaMap '
          '(PlaylistItemId, IndependentMediaId, DurationTicks) '
          'VALUES (?, ?, ?);',
          <Object?>[newId, mediaId, m['DurationTicks']],
        );
      }
      for (final m in src.db.select(
          'SELECT * FROM PlaylistItemLocationMap WHERE PlaylistItemId = ?;',
          <Object?>[oldId])) {
        final mappedLoc = locMap[m['LocationId'] as int];
        if (mappedLoc == null) continue;
        ctx.execPrepared(
          'insertPlaylistLocationMap',
          'INSERT OR IGNORE INTO PlaylistItemLocationMap (PlaylistItemId, '
          'LocationId, MajorMultimediaType, BaseDurationTicks) '
          'VALUES (?, ?, ?, ?);',
          <Object?>[
            newId,
            mappedLoc,
            m['MajorMultimediaType'],
            m['BaseDurationTicks'],
          ],
        );
      }
      for (final marker in src.db.select(
          'SELECT * FROM PlaylistItemMarker WHERE PlaylistItemId = ?;',
          <Object?>[oldId])) {
        final oldMarkerId = marker['PlaylistItemMarkerId'] as int;
        final newMarkerId = ++ctx.maxPlaylistMarkerId;
        ctx.execPrepared(
          'insertPlaylistMarker',
          'INSERT INTO PlaylistItemMarker (PlaylistItemMarkerId, '
          'PlaylistItemId, Label, StartTimeTicks, DurationTicks, '
          'EndTransitionDurationTicks) VALUES (?, ?, ?, ?, ?, ?);',
          <Object?>[
            newMarkerId,
            newId,
            marker['Label'],
            marker['StartTimeTicks'],
            marker['DurationTicks'],
            marker['EndTransitionDurationTicks'],
          ],
        );
        if (src.tables.contains('PlaylistItemMarkerBibleVerseMap')) {
          for (final v in src.db.select(
              'SELECT * FROM PlaylistItemMarkerBibleVerseMap WHERE '
              'PlaylistItemMarkerId = ?;',
              <Object?>[oldMarkerId])) {
            ctx.execPrepared(
              'insertMarkerVerseMap',
              'INSERT OR IGNORE INTO PlaylistItemMarkerBibleVerseMap '
              '(PlaylistItemMarkerId, VerseId) VALUES (?, ?);',
              <Object?>[newMarkerId, v['VerseId']],
            );
          }
        }
        if (src.tables.contains('PlaylistItemMarkerParagraphMap')) {
          for (final v in src.db.select(
              'SELECT * FROM PlaylistItemMarkerParagraphMap WHERE '
              'PlaylistItemMarkerId = ?;',
              <Object?>[oldMarkerId])) {
            ctx.execPrepared(
              'insertMarkerParagraphMap',
              'INSERT OR IGNORE INTO PlaylistItemMarkerParagraphMap '
              '(PlaylistItemMarkerId, MepsDocumentId, ParagraphIndex, '
              'MarkerIndexWithinParagraph) VALUES (?, ?, ?, ?);',
              <Object?>[
                newMarkerId,
                v['MepsDocumentId'],
                v['ParagraphIndex'],
                v['MarkerIndexWithinParagraph'],
              ],
            );
          }
        }
      }
    }
    return map;
  }

  /// Content signature per PlaylistItem so identical items merged from two
  /// backups are recognised even though their integer ids differ.
  static Map<int, String> _playlistSignatures(Database db) {
    final mediaHashes = <int, List<String>>{};
    for (final row in db.select(
        'SELECT m.PlaylistItemId, i.Hash FROM '
        'PlaylistItemIndependentMediaMap m '
        'JOIN IndependentMedia i ON i.IndependentMediaId = '
        'm.IndependentMediaId;')) {
      mediaHashes
          .putIfAbsent(row['PlaylistItemId'] as int, () => <String>[])
          .add(row['Hash'] as String);
    }
    final locKeys = <int, List<String>>{};
    for (final row in db.select(
        'SELECT m.PlaylistItemId, l.* FROM PlaylistItemLocationMap m '
        'JOIN Location l ON l.LocationId = m.LocationId;')) {
      locKeys
          .putIfAbsent(row['PlaylistItemId'] as int, () => <String>[])
          .add(_locationKey(row));
    }
    final markerKeys = <int, List<String>>{};
    for (final row in db.select('SELECT * FROM PlaylistItemMarker;')) {
      markerKeys
          .putIfAbsent(row['PlaylistItemId'] as int, () => <String>[])
          .add('${row['Label']}|${row['StartTimeTicks']}|'
              '${row['DurationTicks']}');
    }

    final signatures = <int, String>{};
    for (final row in db.select('SELECT * FROM PlaylistItem;')) {
      final id = row['PlaylistItemId'] as int;
      final media = (mediaHashes[id] ?? <String>[])..sort();
      final locs = (locKeys[id] ?? <String>[])..sort();
      final markers = (markerKeys[id] ?? <String>[])..sort();
      signatures[id] = <String>[
        row['Label'] as String,
        '${row['StartTrimOffsetTicks']}',
        '${row['EndTrimOffsetTicks']}',
        '${row['EndAction']}',
        media.join(','),
        locs.join(','),
        markers.join(','),
      ].join('\u0002');
    }
    return signatures;
  }

  // ---- TagMap ---------------------------------------------------------------

  void _mergeTagMaps(
    _MergeContext ctx,
    _Source src,
    Map<int, int> tagMap,
    Map<int, int> noteMap,
    Map<int, int> locMap,
    Map<int, int> playlistMap,
  ) {
    if (!src.tables.contains('TagMap')) return;
    final columns = _columnNames(src.db, 'TagMap');
    if (!columns.contains('NoteId')) {
      ctx.report.warnings.add(
          'Tag assignments in ${p.basename(src.originalPath)} use a legacy '
          'TagMap layout and were skipped (tags and notes themselves were '
          'merged).');
      return;
    }
    final counts = ctx.report.counts('TagMap');

    for (final row in src.db.select(
        'SELECT * FROM TagMap ORDER BY TagId, Position;')) {
      final mappedTag = tagMap[row['TagId'] as int];
      if (mappedTag == null) {
        counts.skipped++;
        continue;
      }
      int? noteId;
      int? locationId;
      int? playlistItemId;
      String targetKey;
      if (row['NoteId'] != null) {
        noteId = noteMap[row['NoteId'] as int];
        if (noteId == null) {
          counts.skipped++;
          continue;
        }
        targetKey = 'n$noteId';
      } else if (row['LocationId'] != null) {
        locationId = locMap[row['LocationId'] as int];
        if (locationId == null) {
          counts.skipped++;
          continue;
        }
        targetKey = 'l$locationId';
      } else if (row['PlaylistItemId'] != null) {
        playlistItemId = playlistMap[row['PlaylistItemId'] as int];
        if (playlistItemId == null) {
          counts.skipped++;
          continue;
        }
        targetKey = 'p$playlistItemId';
      } else {
        counts.skipped++;
        continue;
      }

      final dedupeKey = '$mappedTag\u0001$targetKey';
      if (ctx.tagMapTargets.contains(dedupeKey)) {
        counts.skipped++;
        continue;
      }
      final position = ctx.nextTagPosition(mappedTag);
      ctx.execPrepared(
        'insertTagMap',
        'INSERT INTO TagMap (TagMapId, PlaylistItemId, LocationId, NoteId, '
        'TagId, Position) VALUES (?, ?, ?, ?, ?, ?);',
        <Object?>[
          ++ctx.maxTagMapId,
          playlistItemId,
          locationId,
          noteId,
          mappedTag,
          position,
        ],
      );
      ctx.tagMapTargets.add(dedupeKey);
      counts.added++;
    }
  }

  // ---- Bookmark ---------------------------------------------------------------

  void _mergeBookmarks(_MergeContext ctx, _Source src, Map<int, int> locMap) {
    if (!src.tables.contains('Bookmark')) return;
    final counts = ctx.report.counts('Bookmark');

    for (final row in src.db.select('SELECT * FROM Bookmark;')) {
      final mappedLoc = locMap[row['LocationId'] as int];
      final mappedPubLoc = locMap[row['PublicationLocationId'] as int];
      if (mappedLoc == null || mappedPubLoc == null) {
        counts.skipped++;
        continue;
      }
      var slot = row['Slot'] as int;
      final occupant = ctx.bookmarkSlots['$mappedPubLoc:$slot'];
      if (occupant != null) {
        if (occupant == mappedLoc) {
          counts.skipped++; // same bookmark already present
          continue;
        }
        // Slot conflict with a different target: JW Library shows 10 slots
        // per publication (0-9). Move the older bookmark to a free slot;
        // if none is free the newer backup's bookmark (already in the base)
        // wins.
        int? freeSlot;
        for (var s = 0; s < 10; s++) {
          if (!ctx.bookmarkSlots.containsKey('$mappedPubLoc:$s')) {
            freeSlot = s;
            break;
          }
        }
        if (freeSlot == null) {
          counts.skipped++;
          continue;
        }
        slot = freeSlot;
      }
      ctx.execPrepared(
        'insertBookmark',
        'INSERT INTO Bookmark (BookmarkId, LocationId, '
        'PublicationLocationId, Slot, Title, Snippet, BlockType, '
        'BlockIdentifier) VALUES (?, ?, ?, ?, ?, ?, ?, ?);',
        <Object?>[
          ++ctx.maxBookmarkId,
          mappedLoc,
          mappedPubLoc,
          slot,
          row['Title'],
          row['Snippet'],
          row['BlockType'],
          row['BlockIdentifier'],
        ],
      );
      ctx.bookmarkSlots['$mappedPubLoc:$slot'] = mappedLoc;
      counts.added++;
    }
  }

  // ---- InputField ---------------------------------------------------------------

  void _mergeInputFields(_MergeContext ctx, _Source src, Map<int, int> locMap) {
    if (!src.tables.contains('InputField') ||
        !ctx.tables.contains('InputField')) {
      return;
    }
    final counts = ctx.report.counts('InputField');

    for (final row in src.db.select('SELECT * FROM InputField;')) {
      final mappedLoc = locMap[row['LocationId'] as int];
      if (mappedLoc == null) {
        counts.skipped++;
        continue;
      }
      final key = '$mappedLoc\u0001${row['TextTag']}';
      if (ctx.inputFieldKeys.contains(key)) {
        counts.skipped++; // newer backup's value already present
        continue;
      }
      ctx.execPrepared(
        'insertInputField',
        'INSERT INTO InputField (LocationId, TextTag, Value) '
        'VALUES (?, ?, ?);',
        <Object?>[mappedLoc, row['TextTag'], row['Value']],
      );
      ctx.inputFieldKeys.add(key);
      counts.added++;
    }
  }

  // ---------------------------------------------------------------------
  // Orphan repair
  // ---------------------------------------------------------------------

  /// Deletes or detaches rows whose foreign keys point at records that do
  /// not exist. These orphans are found in real-world backups produced by
  /// JW Library itself; removing them makes `foreign_key_check` pass.
  /// Returns the number of rows repaired.
  int _cleanOrphans(_MergeContext ctx) {
    var repaired = 0;
    int changes() =>
        ctx.db.select('SELECT changes() AS c;').first['c'] as int;

    void run(String table, String sql) {
      if (!ctx.tableExists(table)) return;
      ctx.db.execute(sql);
      repaired += changes();
    }

    // Highlights pointing at missing locations (and everything under them).
    run('UserMark',
        'DELETE FROM UserMark WHERE LocationId NOT IN '
        '(SELECT LocationId FROM Location);');
    run('BlockRange',
        'DELETE FROM BlockRange WHERE UserMarkId NOT IN '
        '(SELECT UserMarkId FROM UserMark);');
    // Notes keep their text; broken references are detached, not deleted.
    run('Note',
        'UPDATE Note SET UserMarkId = NULL WHERE UserMarkId IS NOT NULL '
        'AND UserMarkId NOT IN (SELECT UserMarkId FROM UserMark);');
    run('Note',
        'UPDATE Note SET LocationId = NULL WHERE LocationId IS NOT NULL '
        'AND LocationId NOT IN (SELECT LocationId FROM Location);');
    run('TagMap',
        'DELETE FROM TagMap WHERE TagId NOT IN (SELECT TagId FROM Tag);');
    run('TagMap',
        'DELETE FROM TagMap WHERE NoteId IS NOT NULL AND NoteId NOT IN '
        '(SELECT NoteId FROM Note);');
    run('TagMap',
        'DELETE FROM TagMap WHERE LocationId IS NOT NULL AND LocationId '
        'NOT IN (SELECT LocationId FROM Location);');
    if (ctx.tableExists('PlaylistItem')) {
      run('TagMap',
          'DELETE FROM TagMap WHERE PlaylistItemId IS NOT NULL AND '
          'PlaylistItemId NOT IN (SELECT PlaylistItemId FROM PlaylistItem);');
      run('PlaylistItemIndependentMediaMap',
          'DELETE FROM PlaylistItemIndependentMediaMap WHERE PlaylistItemId '
          'NOT IN (SELECT PlaylistItemId FROM PlaylistItem) OR '
          'IndependentMediaId NOT IN '
          '(SELECT IndependentMediaId FROM IndependentMedia);');
      run('PlaylistItemLocationMap',
          'DELETE FROM PlaylistItemLocationMap WHERE PlaylistItemId NOT IN '
          '(SELECT PlaylistItemId FROM PlaylistItem) OR LocationId NOT IN '
          '(SELECT LocationId FROM Location);');
      run('PlaylistItemMarker',
          'DELETE FROM PlaylistItemMarker WHERE PlaylistItemId NOT IN '
          '(SELECT PlaylistItemId FROM PlaylistItem);');
      run('PlaylistItemMarkerBibleVerseMap',
          'DELETE FROM PlaylistItemMarkerBibleVerseMap WHERE '
          'PlaylistItemMarkerId NOT IN '
          '(SELECT PlaylistItemMarkerId FROM PlaylistItemMarker);');
      run('PlaylistItemMarkerParagraphMap',
          'DELETE FROM PlaylistItemMarkerParagraphMap WHERE '
          'PlaylistItemMarkerId NOT IN '
          '(SELECT PlaylistItemMarkerId FROM PlaylistItemMarker);');
    }
    run('Bookmark',
        'DELETE FROM Bookmark WHERE LocationId NOT IN '
        '(SELECT LocationId FROM Location) OR PublicationLocationId NOT IN '
        '(SELECT LocationId FROM Location);');
    run('InputField',
        'DELETE FROM InputField WHERE LocationId NOT IN '
        '(SELECT LocationId FROM Location);');
    return repaired;
  }

  // ---------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------

  static int? _mapNullable(int? id, Map<int, int> map) =>
      id == null ? null : map[id];

  static DateTime? _parseTs(String? value) =>
      value == null ? null : DateTime.tryParse(value)?.toUtc();

  static String _isoNow() {
    final ts = DateTime.now().toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${ts.year}-${two(ts.month)}-${two(ts.day)}T'
        '${two(ts.hour)}:${two(ts.minute)}:${two(ts.second)}Z';
  }

  String _randomHex(int length) {
    const chars = '0123456789abcdef';
    return List<String>.generate(
        length, (_) => chars[_random.nextInt(chars.length)]).join();
  }

  void _progress(double value, String message) =>
      onProgress?.call(value.clamp(0.0, 1.0), message);
}

// ---------------------------------------------------------------------------
// Internal types
// ---------------------------------------------------------------------------

class _Source {
  _Source({
    required this.originalPath,
    required this.dir,
    required this.db,
    required this.tables,
    required this.lastModified,
    required this.schemaVersion,
  });

  final String originalPath;
  final Directory dir;
  final Database db;
  final Set<String> tables;
  final DateTime lastModified;
  final int schemaVersion;
  bool disposed = false;
}

class _UserMarkRef {
  const _UserMarkRef(this.id, this.version);
  final int id;
  final int version;
}

class _NoteRef {
  const _NoteRef(this.id, this.lastModified);
  final int id;
  final DateTime? lastModified;
}

class _MediaRef {
  const _MediaRef(this.id, this.filePath);
  final int id;
  final String filePath;
}

class _MediaMaps {
  final Map<int, int> idMap = <int, int>{};
  final Map<String, String> pathMap = <String, String>{};
}

/// Mutable indexes over the base (output) database. Loaded once and updated
/// incrementally as rows are inserted, so merging N backups stays fast.
class _MergeContext {
  _MergeContext(this.db, this.outDir, this.report);

  final Database db;
  final Directory outDir;
  final MergeReport report;

  // Prepared statements are keyed by a short label and reused across every
  // source backup in the merge, instead of re-parsing the same INSERT/UPDATE
  // SQL text on every single row. Disposed once at the end of the merge.
  final Map<String, PreparedStatement> _statements = <String, PreparedStatement>{};

  /// Runs [sql] (cached under [key] the first time it's seen) with
  /// [params], reusing the same prepared statement on subsequent calls.
  void execPrepared(String key, String sql, List<Object?> params) {
    final stmt = _statements.putIfAbsent(key, () => db.prepare(sql));
    stmt.execute(params);
  }

  void disposeStatements() {
    for (final stmt in _statements.values) {
      stmt.dispose();
    }
    _statements.clear();
  }

  late final Set<String> tables = db
      .select("SELECT name FROM sqlite_master WHERE type = 'table';")
      .map((row) => row['name'] as String)
      .toSet();

  final Map<String, int> locationsByKey = <String, int>{};
  final Map<String, _UserMarkRef> userMarksByGuid = <String, _UserMarkRef>{};
  final Map<String, _NoteRef> notesByGuid = <String, _NoteRef>{};
  final Map<String, int> tagsByKey = <String, int>{};
  final Map<String, _MediaRef> mediaByHash = <String, _MediaRef>{};
  final Set<String> mediaPathsInUse = <String>{};
  final Map<String, int> accuracyByDesc = <String, int>{};
  final Map<String, int> playlistBySignature = <String, int>{};
  final Set<String> tagMapTargets = <String>{};
  final Map<String, int> bookmarkSlots = <String, int>{}; // pubLoc:slot -> loc
  final Set<String> inputFieldKeys = <String>{};
  final Map<int, int> _tagPositions = <int, int>{};

  int maxLocationId = 0;
  int maxUserMarkId = 0;
  int maxBlockRangeId = 0;
  int maxNoteId = 0;
  int maxTagId = 0;
  int maxTagMapId = 0;
  int maxBookmarkId = 0;
  int maxMediaId = 0;
  int maxPlaylistItemId = 0;
  int maxPlaylistMarkerId = 0;
  int maxAccuracyId = 0;

  bool tableExists(String name) => tables.contains(name);

  int _maxId(String table, String column) {
    if (!tableExists(table)) return 0;
    final rs = db.select('SELECT COALESCE(MAX($column), 0) AS m FROM $table;');
    return rs.first['m'] as int;
  }

  int nextTagPosition(int tagId) {
    final next = _tagPositions.putIfAbsent(tagId, () {
      final rs = db.select(
          'SELECT COALESCE(MAX(Position), -1) AS m FROM TagMap WHERE '
          'TagId = ?;',
          <Object?>[tagId]);
      return (rs.first['m'] as int) + 1;
    });
    _tagPositions[tagId] = next + 1;
    return next;
  }

  void loadBaseIndexes() {
    maxLocationId = _maxId('Location', 'LocationId');
    maxUserMarkId = _maxId('UserMark', 'UserMarkId');
    maxBlockRangeId = _maxId('BlockRange', 'BlockRangeId');
    maxNoteId = _maxId('Note', 'NoteId');
    maxTagId = _maxId('Tag', 'TagId');
    maxTagMapId = _maxId('TagMap', 'TagMapId');
    maxBookmarkId = _maxId('Bookmark', 'BookmarkId');
    maxMediaId = _maxId('IndependentMedia', 'IndependentMediaId');
    maxPlaylistItemId = _maxId('PlaylistItem', 'PlaylistItemId');
    maxPlaylistMarkerId = _maxId('PlaylistItemMarker', 'PlaylistItemMarkerId');
    maxAccuracyId = _maxId('PlaylistItemAccuracy', 'PlaylistItemAccuracyId');

    if (tableExists('Location')) {
      for (final row in db.select('SELECT * FROM Location;')) {
        locationsByKey[JwMergeEngine._locationKey(row)] =
            row['LocationId'] as int;
      }
    }
    if (tableExists('UserMark')) {
      for (final row in db.select(
          'SELECT UserMarkId, UserMarkGuid, Version FROM UserMark;')) {
        userMarksByGuid[row['UserMarkGuid'] as String] = _UserMarkRef(
            row['UserMarkId'] as int, row['Version'] as int);
      }
    }
    if (tableExists('Note')) {
      for (final row
          in db.select('SELECT NoteId, Guid, LastModified FROM Note;')) {
        notesByGuid[row['Guid'] as String] = _NoteRef(
            row['NoteId'] as int,
            JwMergeEngine._parseTs(row['LastModified'] as String?));
      }
    }
    if (tableExists('Tag')) {
      for (final row in db.select('SELECT TagId, Type, Name FROM Tag;')) {
        tagsByKey['${row['Type']}\u0001${row['Name']}'] = row['TagId'] as int;
      }
    }
    if (tableExists('IndependentMedia')) {
      for (final row in db.select(
          'SELECT IndependentMediaId, FilePath, Hash FROM '
          'IndependentMedia;')) {
        mediaByHash[row['Hash'] as String] = _MediaRef(
            row['IndependentMediaId'] as int, row['FilePath'] as String);
        mediaPathsInUse.add(row['FilePath'] as String);
      }
    }
    if (tableExists('PlaylistItemAccuracy')) {
      for (final row in db.select('SELECT * FROM PlaylistItemAccuracy;')) {
        accuracyByDesc[row['Description'] as String] =
            row['PlaylistItemAccuracyId'] as int;
      }
    }
    if (JwMergeEngine._playlistTables.every(tableExists)) {
      JwMergeEngine._playlistSignatures(db)
          .forEach((id, sig) => playlistBySignature[sig] = id);
    }
    if (tableExists('TagMap')) {
      for (final row in db.select('SELECT * FROM TagMap;')) {
        final tagId = row['TagId'] as int;
        String? targetKey;
        if (row['NoteId'] != null) targetKey = 'n${row['NoteId']}';
        if (row['LocationId'] != null) targetKey = 'l${row['LocationId']}';
        if (row['PlaylistItemId'] != null) {
          targetKey = 'p${row['PlaylistItemId']}';
        }
        if (targetKey != null) tagMapTargets.add('$tagId\u0001$targetKey');
      }
    }
    if (tableExists('Bookmark')) {
      for (final row in db.select(
          'SELECT LocationId, PublicationLocationId, Slot FROM Bookmark;')) {
        bookmarkSlots['${row['PublicationLocationId']}:${row['Slot']}'] =
            row['LocationId'] as int;
      }
    }
    if (tableExists('InputField')) {
      for (final row
          in db.select('SELECT LocationId, TextTag FROM InputField;')) {
        inputFieldKeys.add('${row['LocationId']}\u0001${row['TextTag']}');
      }
    }
  }
}
