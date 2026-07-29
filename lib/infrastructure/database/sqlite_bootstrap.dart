import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/open.dart';

/// Makes sure the native sqlite3 library can be loaded.
///
/// * Inside the Flutter app, `sqlite3_flutter_libs` bundles the binary for
///   every platform, so nothing needs to happen here.
/// * When running the pure-Dart CLI on Windows (`dart run bin/jw_fusion_cli.dart`),
///   Windows has no system sqlite3, so we search next to the executable, the
///   project root, and the PATH for `sqlite3.dll`.
void ensureSqliteLoaded() {
  if (!Platform.isWindows) return;
  open.overrideFor(OperatingSystem.windows, () {
    final candidates = <String>[
      p.join(File(Platform.resolvedExecutable).parent.path, 'sqlite3.dll'),
      p.join(Directory.current.path, 'sqlite3.dll'),
      'sqlite3.dll', // resolved via PATH
    ];
    Object? lastError;
    for (final candidate in candidates) {
      try {
        return DynamicLibrary.open(candidate);
      } on Object catch (e) {
        lastError = e;
      }
    }
    throw StateError(
        'Could not load sqlite3.dll. Place sqlite3.dll (64-bit, from '
        'https://www.sqlite.org/download.html) next to this script or in the '
        'project folder, or add it to PATH. Last error: $lastError');
  });
}
