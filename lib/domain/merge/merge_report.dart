/// A friendly, user-facing rollup of one or more raw table results - e.g.
/// "Highlights" covers both the `UserMark` and `BlockRange` tables.
class CategorySummary {
  const CategorySummary(this.label, this.added, this.updated);

  final String label;
  final int added;
  final int updated;

  int get total => added + updated;
}

/// Raw table names grouped into the categories a JW Library user would
/// actually recognise. Order here is the display order.
const Map<String, List<String>> _categoryTables = <String, List<String>>{
  'Notes': ['Note'],
  'Highlights': ['UserMark', 'BlockRange'],
  'Bookmarks': ['Bookmark'],
  'Tags': ['Tag', 'TagMap'],
  'Playlists': [
    'PlaylistItem',
    'PlaylistItemAccuracy',
    'PlaylistItemIndependentMediaMap',
    'PlaylistItemLocationMap',
    'PlaylistItemMarker',
    'PlaylistItemMarkerBibleVerseMap',
    'PlaylistItemMarkerParagraphMap',
  ],
};

/// Per-table merge counters.
class TableCounts {
  int added = 0;
  int updated = 0;
  int skipped = 0;

  @override
  String toString() => 'added: $added, updated: $updated, skipped: $skipped';
}

/// Summary of one source backup that participated in the merge.
class SourceSummary {
  SourceSummary({
    required this.path,
    required this.lastModified,
    required this.schemaVersion,
    required this.isBase,
  });

  final String path;
  final DateTime lastModified;
  final int schemaVersion;

  /// True for the newest backup, which is used as the merge base.
  final bool isBase;
}

/// Result of a completed merge, suitable for console output (Phase 2)
/// and for rendering in the UI (Phase 3).
class MergeReport {
  MergeReport();

  final Map<String, TableCounts> tables = <String, TableCounts>{};
  final List<String> warnings = <String>[];
  final List<SourceSummary> sources = <SourceSummary>[];

  String outputPath = '';
  Duration elapsed = Duration.zero;
  bool integrityOk = false;

  TableCounts counts(String table) =>
      tables.putIfAbsent(table, TableCounts.new);

  /// Rolls the raw per-table counts up into a handful of categories a user
  /// would recognise from JW Library (Notes, Highlights, Bookmarks, Tags,
  /// Playlists), in a fixed display order. Categories with no activity are
  /// left out. Anything not covered by a named category (Location,
  /// IndependentMedia, InputField, ...) is folded into "Other data".
  List<CategorySummary> categorySummaries() {
    final claimed = <String>{};
    final result = <CategorySummary>[];

    _categoryTables.forEach((label, tableNames) {
      var added = 0;
      var updated = 0;
      for (final name in tableNames) {
        final counts = tables[name];
        if (counts == null) continue;
        added += counts.added;
        updated += counts.updated;
        claimed.add(name);
      }
      if (added > 0 || updated > 0) {
        result.add(CategorySummary(label, added, updated));
      }
    });

    var otherAdded = 0;
    var otherUpdated = 0;
    tables.forEach((name, counts) {
      if (claimed.contains(name)) return;
      otherAdded += counts.added;
      otherUpdated += counts.updated;
    });
    if (otherAdded > 0 || otherUpdated > 0) {
      result.add(CategorySummary('Other data', otherAdded, otherUpdated));
    }
    return result;
  }

  String toConsoleString() {
    final buffer = StringBuffer();
    buffer.writeln('=== JW Fusion merge report ===');
    buffer.writeln('Sources (newest is used as base):');
    for (final s in sources) {
      final tag = s.isBase ? ' [BASE]' : '';
      buffer.writeln(
          '  - ${s.path}$tag  (lastModified: ${s.lastModified.toIso8601String()}, schema v${s.schemaVersion})');
    }
    buffer.writeln('Table results (records merged INTO the base):');
    final names = tables.keys.toList()..sort();
    for (final name in names) {
      buffer.writeln('  ${name.padRight(28)} ${tables[name]}');
    }
    if (warnings.isEmpty) {
      buffer.writeln('Warnings: none');
    } else {
      buffer.writeln('Warnings:');
      for (final w in warnings) {
        buffer.writeln('  ! $w');
      }
    }
    buffer.writeln('Database integrity check: ${integrityOk ? 'OK' : 'FAILED'}');
    buffer.writeln('Output: $outputPath');
    buffer.writeln('Elapsed: ${elapsed.inMilliseconds} ms');
    return buffer.toString();
  }
}
