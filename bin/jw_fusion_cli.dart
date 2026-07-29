// JW Fusion - Phase 2 console test harness.
//
// Usage (from the jw_fusion project folder, after `flutter pub get`):
//
//   dart run bin/jw_fusion_cli.dart -o merged.jwlibrary backup1.jwlibrary backup2.jwlibrary [...]
//
// On Windows, place a 64-bit sqlite3.dll in the project folder (or PATH)
// before running. The Flutter app itself does not need this - it bundles
// sqlite via sqlite3_flutter_libs.

import 'dart:io';

import 'package:jw_fusion/domain/merge/jw_merge_engine.dart';
import 'package:jw_fusion/infrastructure/database/sqlite_bootstrap.dart';

Future<void> main(List<String> args) async {
  final inputs = <String>[];
  String? output;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '-o' || arg == '--output') {
      if (i + 1 >= args.length) {
        _fail('Missing value after $arg.');
      }
      output = args[++i];
    } else if (arg == '-h' || arg == '--help') {
      _printUsage();
      return;
    } else {
      inputs.add(arg);
    }
  }

  if (inputs.length < 2) {
    _printUsage();
    _fail('Provide at least two .jwlibrary files to merge.');
  }
  for (final path in inputs) {
    if (!File(path).existsSync()) {
      _fail('File not found: $path');
    }
  }
  output ??= 'JWFusion_merged_${_dateStamp()}.jwlibrary';
  if (!output.toLowerCase().endsWith('.jwlibrary')) {
    output = '$output.jwlibrary';
  }

  ensureSqliteLoaded();

  stdout.writeln('JW Fusion - merging ${inputs.length} backups...');
  final engine = JwMergeEngine(
    onProgress: (progress, message) {
      final pct = (progress * 100).toStringAsFixed(0).padLeft(3);
      stdout.writeln('[$pct%] $message');
    },
  );

  try {
    final report = await engine.merge(
      inputPaths: inputs,
      outputPath: output,
      workDir: Directory.systemTemp,
    );
    stdout.writeln();
    stdout.write(report.toConsoleString());
    exitCode = report.integrityOk ? 0 : 2;
  } on Object catch (e) {
    _fail('Merge failed: $e');
  }
}

String _dateStamp() {
  final now = DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${now.year}-${two(now.month)}-${two(now.day)}';
}

void _printUsage() {
  stdout.writeln('''
JW Fusion CLI - merge .jwlibrary backups without losing data.

Usage:
  dart run bin/jw_fusion_cli.dart [-o output.jwlibrary] <backup1> <backup2> [...]

Options:
  -o, --output   Output file path (default: JWFusion_merged_<date>.jwlibrary)
  -h, --help     Show this help.
''');
}

Never _fail(String message) {
  stderr.writeln(message);
  exit(1);
}
