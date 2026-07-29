import 'dart:convert';

/// Parses and generates the `manifest.json` found inside `.jwlibrary` files.
///
/// Observed real-world shape (schema version 14):
/// ```json
/// {
///   "name": "UserdataBackup_2025-11-25_DEVICE",
///   "creationDate": "2025-11-25",
///   "version": 1,
///   "type": 0,
///   "userDataBackup": {
///     "lastModifiedDate": "2025-03-18T18:13:44+00:00",
///     "deviceName": "DEVICE",
///     "databaseName": "userData.db",
///     "hash": "<sha256 of userData.db>",
///     "schemaVersion": 14
///   }
/// }
/// ```
class BackupManifest {
  BackupManifest({
    required this.name,
    required this.creationDate,
    required this.version,
    required this.type,
    required this.lastModifiedDate,
    required this.deviceName,
    required this.databaseName,
    required this.hash,
    required this.schemaVersion,
  });

  factory BackupManifest.fromJsonString(String source) {
    final root = json.decode(source) as Map<String, dynamic>;
    final backup =
        (root['userDataBackup'] as Map<String, dynamic>?) ?? <String, dynamic>{};
    return BackupManifest(
      name: (root['name'] as String?) ?? 'Unknown backup',
      creationDate: (root['creationDate'] as String?) ?? '',
      version: (root['version'] as num?)?.toInt() ?? 1,
      type: (root['type'] as num?)?.toInt() ?? 0,
      lastModifiedDate: (backup['lastModifiedDate'] as String?) ?? '',
      deviceName: (backup['deviceName'] as String?) ?? 'Unknown device',
      databaseName: (backup['databaseName'] as String?) ?? 'userData.db',
      hash: (backup['hash'] as String?) ?? '',
      schemaVersion: (backup['schemaVersion'] as num?)?.toInt() ?? 14,
    );
  }

  final String name;
  final String creationDate;
  final int version;
  final int type;
  final String lastModifiedDate;
  final String deviceName;
  final String databaseName;
  final String hash;
  final int schemaVersion;

  /// Builds a fresh manifest for a merged backup.
  factory BackupManifest.forMergedBackup({
    required String name,
    required String databaseHash,
    required int schemaVersion,
    required String deviceName,
    DateTime? now,
  }) {
    final ts = (now ?? DateTime.now()).toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    final date = '${ts.year}-${two(ts.month)}-${two(ts.day)}';
    final iso =
        '${date}T${two(ts.hour)}:${two(ts.minute)}:${two(ts.second)}Z';
    return BackupManifest(
      name: name,
      creationDate: date,
      version: 1,
      type: 0,
      lastModifiedDate: iso,
      deviceName: deviceName,
      databaseName: 'userData.db',
      hash: databaseHash,
      schemaVersion: schemaVersion,
    );
  }

  String toJsonString() {
    const encoder = JsonEncoder.withIndent('  ');
    return encoder.convert(<String, dynamic>{
      'name': name,
      'creationDate': creationDate,
      'version': version,
      'type': type,
      'userDataBackup': <String, dynamic>{
        'lastModifiedDate': lastModifiedDate,
        'deviceName': deviceName,
        'databaseName': databaseName,
        'hash': hash,
        'schemaVersion': schemaVersion,
      },
    });
  }

  DateTime? parsedLastModified() => DateTime.tryParse(lastModifiedDate);
}
