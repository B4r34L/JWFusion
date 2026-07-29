import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../domain/merge/jw_merge_engine.dart';
import '../../domain/merge/merge_report.dart';
import '../../infrastructure/platform/backup_io.dart';

/// UI states of the dashboard.
enum MergePhase { idle, processing, success, failure }

/// Drives the dashboard: holds the selected files, runs the merge engine in
/// a background isolate (so the window never freezes), and exposes progress
/// and results for the UI to render.
class MergeController extends ChangeNotifier {
  MergeController({BackupIo? io}) : _io = io ?? const BackupIo();

  final BackupIo _io;

  MergePhase phase = MergePhase.idle;
  final List<String> selectedFiles = <String>[];
  double progress = 0;
  String progressMessage = '';
  MergeReport? report;
  String? errorMessage;
  String? savedPath;
  String? dropRejectionMessage;
  String? _mergedTempPath;
  Isolate? _isolate;
  ReceivePort? _receivePort;
  String? _pendingOutputPath;

  bool get canMerge =>
      selectedFiles.length >= 2 && phase != MergePhase.processing;

  bool get canCancel => phase == MergePhase.processing;

  Future<void> addFiles() async {
    final picked = await _io.pickBackupFiles();
    _addPaths(picked);
  }

  /// Adds files dropped directly onto the window. Non-`.jwlibrary` files are
  /// rejected with [dropRejectionMessage] set for the UI to surface, rather
  /// than being silently ignored.
  void addDroppedPaths(List<String> paths) {
    final valid = <String>[];
    var rejected = 0;
    for (final path in paths) {
      if (path.toLowerCase().endsWith('.jwlibrary')) {
        valid.add(path);
      } else {
        rejected++;
      }
    }
    dropRejectionMessage = rejected == 0
        ? null
        : (rejected == 1
            ? '1 file was skipped - only .jwlibrary backups are supported.'
            : '$rejected files were skipped - only .jwlibrary backups are '
                'supported.');
    _addPaths(valid);
  }

  void _addPaths(List<String> paths) {
    var added = false;
    for (final path in paths) {
      if (!selectedFiles.contains(path)) {
        selectedFiles.add(path);
        added = true;
      }
    }
    if (added || dropRejectionMessage != null) notifyListeners();
  }

  void clearDropRejection() {
    if (dropRejectionMessage == null) return;
    dropRejectionMessage = null;
    notifyListeners();
  }

  void removeFile(String path) {
    selectedFiles.remove(path);
    notifyListeners();
  }

  Future<void> startMerge() async {
    if (!canMerge) return;
    phase = MergePhase.processing;
    progress = 0;
    progressMessage = 'Starting...';
    errorMessage = null;
    savedPath = null;
    report = null;
    notifyListeners();

    final workDir = await _io.workDirectory();
    final outputName = 'JWFusion_merged_${_dateStamp()}.jwlibrary';
    final outputPath = p.join(workDir.path, outputName);
    _pendingOutputPath = outputPath;

    final receivePort = ReceivePort();
    _receivePort = receivePort;
    try {
      _isolate = await Isolate.spawn(
        _mergeIsolateEntry,
        _MergeRequest(
          sendPort: receivePort.sendPort,
          inputPaths: List<String>.of(selectedFiles),
          outputPath: outputPath,
          workDirPath: workDir.path,
        ),
        errorsAreFatal: true,
        onError: receivePort.sendPort,
      );
    } on Object catch (e) {
      receivePort.close();
      _receivePort = null;
      _fail('Could not start the merge: $e');
      return;
    }

    await for (final message in receivePort) {
      if (message is _MergeProgressMsg) {
        progress = message.progress;
        progressMessage = message.message;
        notifyListeners();
      } else if (message is _MergeDoneMsg) {
        receivePort.close();
        _receivePort = null;
        _isolate = null;
        _pendingOutputPath = null;
        _mergedTempPath = outputPath;
        report = message.report;
        phase = MergePhase.success;
        notifyListeners();
        return;
      } else if (message is _MergeErrorMsg) {
        receivePort.close();
        _receivePort = null;
        _isolate = null;
        _pendingOutputPath = null;
        _fail(message.message);
        return;
      } else if (message is List) {
        // Uncaught isolate error delivered via onError port.
        receivePort.close();
        _receivePort = null;
        _isolate = null;
        _pendingOutputPath = null;
        _fail('${message.isNotEmpty ? message.first : 'Unknown error'}');
        return;
      }
    }
  }

  /// Cancels an in-progress merge: stops the background isolate immediately,
  /// deletes any partial output file, and returns to the idle screen with
  /// the selected file list untouched. Original backup files are never
  /// touched either way.
  void cancelMerge() {
    if (phase != MergePhase.processing) return;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort?.close();
    _receivePort = null;

    final outputPath = _pendingOutputPath;
    _pendingOutputPath = null;
    if (outputPath != null) {
      final file = File(outputPath);
      if (file.existsSync()) {
        try {
          file.deleteSync();
        } on FileSystemException {
          // Best-effort; OS temp cleanup will collect it eventually.
        }
      }
    }

    phase = MergePhase.idle;
    progress = 0;
    progressMessage = '';
    errorMessage = null;
    report = null;
    _mergedTempPath = null;
    notifyListeners();
  }

  Future<void> saveResult() async {
    final tempPath = _mergedTempPath;
    if (tempPath == null || !File(tempPath).existsSync()) {
      _fail('The merged file is no longer available. Please merge again.');
      return;
    }
    final destination =
        await _io.saveMergedFile(tempPath, p.basename(tempPath));
    if (destination != null) {
      savedPath = destination;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _receivePort?.close();
    super.dispose();
  }

  void reset() {
    phase = MergePhase.idle;
    selectedFiles.clear();
    progress = 0;
    progressMessage = '';
    report = null;
    errorMessage = null;
    savedPath = null;
    _mergedTempPath = null;
    notifyListeners();
  }

  void _fail(String message) {
    errorMessage = message;
    phase = MergePhase.failure;
    notifyListeners();
  }

  static String _dateStamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}-${two(now.month)}-${two(now.day)}';
  }
}

// ---------------------------------------------------------------------------
// Background isolate plumbing
// ---------------------------------------------------------------------------

class _MergeRequest {
  const _MergeRequest({
    required this.sendPort,
    required this.inputPaths,
    required this.outputPath,
    required this.workDirPath,
  });

  final SendPort sendPort;
  final List<String> inputPaths;
  final String outputPath;
  final String workDirPath;
}

class _MergeProgressMsg {
  const _MergeProgressMsg(this.progress, this.message);
  final double progress;
  final String message;
}

class _MergeDoneMsg {
  const _MergeDoneMsg(this.report);
  final MergeReport report;
}

class _MergeErrorMsg {
  const _MergeErrorMsg(this.message);
  final String message;
}

Future<void> _mergeIsolateEntry(_MergeRequest request) async {
  try {
    final engine = JwMergeEngine(
      onProgress: (progress, message) =>
          request.sendPort.send(_MergeProgressMsg(progress, message)),
    );
    final report = await engine.merge(
      inputPaths: request.inputPaths,
      outputPath: request.outputPath,
      workDir: Directory(request.workDirPath),
    );
    request.sendPort.send(_MergeDoneMsg(report));
  } on Object catch (e) {
    request.sendPort.send(_MergeErrorMsg(e.toString()));
  }
}
