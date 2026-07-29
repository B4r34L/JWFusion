import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

/// Reads and writes `.jwlibrary` files, which are plain ZIP archives
/// containing `userData.db`, `manifest.json` and any playlist media files.
///
/// Implemented directly on top of `ZipDecoder`/`ZipEncoder` (rather than the
/// `archive_io` convenience helpers) so behaviour is identical across
/// Windows, Android, iOS and macOS and stable across `archive` versions.
class JwLibraryArchive {
  const JwLibraryArchive();

  /// Extracts [archiveFile] into [targetDir]. Returns the list of
  /// extracted file paths. Protects against zip-slip path traversal.
  Future<List<String>> extract(File archiveFile, Directory targetDir) async {
    final bytes = await archiveFile.readAsBytes();
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } on Object catch (e) {
      throw FormatException(
          'Not a valid .jwlibrary (ZIP) file: ${archiveFile.path} ($e)');
    }

    await targetDir.create(recursive: true);
    final extracted = <String>[];
    final rootPath = p.canonicalize(targetDir.path);

    for (final entry in archive) {
      if (!entry.isFile) continue;
      // Flatten any directory components and forbid traversal.
      final safeName = p.basename(entry.name.replaceAll('\\', '/'));
      if (safeName.isEmpty || safeName == '..') continue;
      final outPath = p.join(rootPath, safeName);
      if (!p.isWithin(rootPath, outPath)) continue;
      final outFile = File(outPath);
      await outFile.writeAsBytes(entry.content as List<int>, flush: true);
      extracted.add(outPath);
    }

    if (extracted.isEmpty) {
      throw FormatException(
          'Archive contained no files: ${archiveFile.path}');
    }
    return extracted;
  }

  /// Compresses every file directly inside [sourceDir] (flat, no
  /// subdirectories - matching the official .jwlibrary layout) into
  /// [outputFile].
  Future<void> compressDirectory(Directory sourceDir, File outputFile) async {
    final archive = Archive();
    final entries = sourceDir
        .listSync(followLinks: false)
        .whereType<File>()
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    for (final file in entries) {
      final Uint8List data = await file.readAsBytes();
      archive.addFile(ArchiveFile(p.basename(file.path), data.length, data));
    }

    final encoded = ZipEncoder().encode(archive);
    if (encoded == null) {
      throw StateError('ZIP encoding produced no output.');
    }
    await outputFile.parent.create(recursive: true);
    await outputFile.writeAsBytes(encoded, flush: true);
  }
}
