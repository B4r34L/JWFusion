import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

/// Platform adapter for picking backup files, providing scratch space, and
/// saving the merged result. Keeps every platform difference out of the
/// domain layer and the UI.
class BackupIo {
  const BackupIo();

  /// Lets the user pick one or more `.jwlibrary` files.
  /// Returns absolute paths (empty list if the user cancelled).
  Future<List<String>> pickBackupFiles() async {
    // file_picker 12.x: static API, multi-selection is the default.
    FilePickerResult? result;
    if (Platform.isAndroid || Platform.isIOS) {
      // Mobile pickers filter by MIME type; the .jwlibrary extension has no
      // registered MIME type, so show all files rather than none.
      result = await FilePicker.pickFiles(
        type: FileType.any,
        dialogTitle: 'Choose your backup files',
      );
    } else {
      result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jwlibrary'],
        dialogTitle: 'Choose your backup files',
      );
    }
    if (result == null) return const [];
    return result.paths
        .whereType<String>()
        .where((path) => path.toLowerCase().endsWith('.jwlibrary'))
        .toList();
  }

  /// Temp directory for extraction and the intermediate merged file.
  /// Uses the app cache directory, which maps to the internal app cache on
  /// Android and the user temp directory on desktop.
  Future<Directory> workDirectory() => getTemporaryDirectory();

  /// Asks the user where to save [mergedTempPath] and writes it there.
  /// Returns the destination the user chose, or null if they cancelled.
  Future<String?> saveMergedFile(
      String mergedTempPath, String suggestedName) async {
    // file_picker 12.x requires `bytes` on every platform and writes the
    // file itself (SAF on mobile, direct write on desktop).
    final bytes = await File(mergedTempPath).readAsBytes();
    if (Platform.isAndroid || Platform.isIOS) {
      return FilePicker.saveFile(
        fileName: suggestedName,
        type: FileType.any,
        bytes: bytes,
        dialogTitle: 'Save your merged backup',
      );
    }
    final target = await FilePicker.saveFile(
      fileName: suggestedName,
      type: FileType.custom,
      allowedExtensions: ['jwlibrary'],
      bytes: bytes,
      dialogTitle: 'Save your merged backup',
    );
    if (target == null) return null;
    final destination =
        target.toLowerCase().endsWith('.jwlibrary') ? target : '$target.jwlibrary';
    // Belt and braces: if the plugin did not (fully) write the file at the
    // chosen location, copy the merged archive there ourselves.
    final destFile = File(destination);
    if (!destFile.existsSync() || destFile.lengthSync() != bytes.length) {
      await File(mergedTempPath).copy(destination);
    }
    return destination;
  }
}
