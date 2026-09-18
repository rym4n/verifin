import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../backup/webdav_config.dart';
import 'sync_models.dart';
import 'sync_snapshot.dart';
import 'sync_wire.dart';
import 'webdav_snapshot_transport.dart';
import 'webdav_sync_transport.dart';

// Re-export for test convenience
export 'webdav_sync_transport.dart' show WebdavSyncFileKind;

/// Alias for test convenience
typedef SyncFileKind = WebdavSyncFileKind;

/// Stub WebDAV sync transport for testing (platform-independent).
class StubWebdavSyncTransport implements WebdavSyncTransport {
  StubWebdavSyncTransport({Map<String, Uint8List>? initialFiles})
    : _files = Map<String, Uint8List>.from(initialFiles ?? {});

  final Map<String, Uint8List> _files;
  final Set<String> _createdDirectories = {};
  final Map<String, int> _v1RequestCounts = {};
  final Map<String, int> _snapshotRequestCounts = {};

  Map<String, int> get v1RequestCounts => Map.unmodifiable(_v1RequestCounts);
  Map<String, int> get snapshotRequestCounts =>
      Map.unmodifiable(_snapshotRequestCounts);

  void _countV1(String method) =>
      _v1RequestCounts.update(method, (value) => value + 1, ifAbsent: () => 1);
  void _countSnapshot(String method) => _snapshotRequestCounts.update(
    method,
    (value) => value + 1,
    ifAbsent: () => 1,
  );

  /// Get all created directories for testing.
  Set<String> get createdDirectories => Set.unmodifiable(_createdDirectories);

  /// Get all files for testing (mutable for test setup).
  Map<String, Uint8List> get files => _files;

  /// Test control: fail commit uploads.
  bool failCommitUploads = false;

  /// Test control: fail the read-only v1 bridge listing.
  bool failV1ListRequests = false;

  /// Test control: fail immutable snapshot uploads.
  bool failSnapshotUploads = false;

  /// Test control: store one snapshot, then fail before local confirmation.
  bool failAfterSnapshotStore = false;

  @override
  Future<void> ensureSyncTree(WebdavConfig config) async {
    _countV1('MKCOL');
    _createdDirectories.addAll([
      'verifin-sync',
      'verifin-sync/v1',
      'verifin-sync/v1/events',
      'verifin-sync/v1/blobs',
      'verifin-sync/v1/batches',
    ]);
  }

  @override
  Future<void> putImmutable(
    WebdavConfig config,
    String relativePath,
    Stream<List<int>> bytes,
    int length,
    String expectedHash,
  ) async {
    _countV1('PUT');
    // Test control: fail commit uploads
    if (failCommitUploads && relativePath.endsWith('.commit')) {
      throw const WebdavException('Test: commit upload failure');
    }

    // Check if file exists
    if (_files.containsKey(relativePath)) {
      final existing = _files[relativePath]!;
      final existingHash = sha256.convert(existing).toString();
      if (existingHash == expectedHash) {
        // Same hash, idempotent success
        return;
      } else {
        throw WebdavFileCollision(
          'File exists with different hash: $relativePath',
        );
      }
    }

    // Collect bytes from stream
    final builder = BytesBuilder(copy: false);
    await for (final chunk in bytes) {
      builder.add(chunk);
    }
    final fileBytes = builder.toBytes();

    // Verify hash
    final actualHash = sha256.convert(fileBytes).toString();
    if (actualHash != expectedHash) {
      throw const WebdavException('Hash mismatch');
    }

    // Store file
    _files[relativePath] = fileBytes;
  }

  /// Simulate a remote batch upload for testing.
  Future<void> simulateRemoteBatch(
    String deviceId,
    int sequence,
    List<SyncEvent> events, {
    bool includeCommit = true,
  }) async {
    final batchId = events.first.batchId;

    // Upload event files: serialize the full SyncEvent as the file content
    // so the engine can decode it with SyncEvent.fromJson.
    for (var i = 0; i < events.length; i++) {
      final event = events[i];
      final eventSequence = (sequence + i).toString().padLeft(20, '0');
      final eventPath =
          'verifin-sync/v1/events/$deviceId/'
          '$eventSequence-${event.operationId}.vfsync';
      final eventBytes = utf8.encode(
        jsonEncode(syncEventForWire(event).toJson()),
      );
      _files[eventPath] = Uint8List.fromList(eventBytes);
    }

    // Upload manifest
    final manifestPath = 'verifin-sync/v1/batches/$deviceId/$batchId.manifest';
    final manifest = syncManifest(batchId, events);
    final manifestBytes = utf8.encode(jsonEncode(manifest));
    _files[manifestPath] = Uint8List.fromList(manifestBytes);
    for (final blob in syncAttachmentBlobs(events).entries) {
      _files['verifin-sync/v1/blobs/${blob.key}.blob'] = syncJsonBytes({
        'protocolVersion': syncProtocolVersion,
        'hash': blob.key,
        'data': base64Encode(blob.value),
      });
    }

    // Upload commit marker
    if (includeCommit) {
      final commitPath = 'verifin-sync/v1/batches/$deviceId/$batchId.commit';
      _files[commitPath] = syncJsonBytes(syncCommit(manifest, manifestBytes));
    }
  }

  @override
  Future<List<WebdavSyncFile>> listSyncFiles(WebdavConfig config) async {
    _countV1('PROPFIND');
    if (failV1ListRequests) {
      throw const WebdavException('Test: v1 bridge listing failure');
    }
    final files = <WebdavSyncFile>[];

    for (final entry in _files.entries) {
      final relativePath = entry.key;
      final bytes = entry.value;

      final kind = _parseSyncFileKind(relativePath);
      if (kind == null) continue;

      final (deviceId, sequence) = kind == WebdavSyncFileKind.event
          ? _parseEventPath(relativePath)
          : (null, null);

      files.add(
        WebdavSyncFile(
          relativePath: relativePath,
          kind: kind,
          deviceId: deviceId,
          sequence: sequence,
          sizeBytes: bytes.length,
          modifiedAt: DateTime.utc(2026, 1, 1),
        ),
      );
    }

    return files;
  }

  @override
  Future<Uint8List> downloadSyncFile(
    WebdavConfig config,
    String relativePath, {
    required int maxBytes,
  }) async {
    _countV1('GET');
    if (!_files.containsKey(relativePath)) {
      throw const WebdavException('File not found');
    }

    final bytes = _files[relativePath]!;
    if (bytes.length > maxBytes) {
      throw WebdavException(
        'File exceeds maxBytes limit: ${bytes.length} > $maxBytes',
      );
    }

    return bytes;
  }

  @override
  Future<WebdavRootListing> listRoot(WebdavConfig config) async {
    _countSnapshot('PROPFIND');
    final result = <WebdavRootFile>[];
    for (final entry in _files.entries) {
      try {
        final name = SnapshotFileName.parse(entry.key);
        result.add(
          WebdavRootFile(
            name: name,
            sizeBytes: entry.value.length,
            modifiedAt: DateTime.utc(2026, 1, 1),
          ),
        );
      } on FormatException {
        // Ordinary backups, the v1 tree, and unknown root files are ignored.
      }
    }
    return WebdavRootListing(
      files: result,
      legacyTreePresent: _files.keys.any(
        (path) => path.startsWith('verifin-sync/v1/'),
      ),
    );
  }

  @override
  Future<void> putSnapshot(
    WebdavConfig config,
    SnapshotFileName name,
    Stream<List<int>> bytes,
    int length,
  ) async {
    if (name.isBlob) throw const WebdavException('Expected snapshot name');
    await _putRoot(name, bytes, length);
  }

  @override
  Future<void> putBlob(
    WebdavConfig config,
    SnapshotFileName name,
    Stream<List<int>> bytes,
    int length,
  ) async {
    if (!name.isBlob) throw const WebdavException('Expected blob name');
    await _putRoot(name, bytes, length);
  }

  Future<void> _putRoot(
    SnapshotFileName name,
    Stream<List<int>> bytes,
    int length,
  ) async {
    _countSnapshot('PUT');
    if (failSnapshotUploads) {
      throw const WebdavException('Test: snapshot upload failure');
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in bytes) {
      builder.add(chunk);
    }
    final uploaded = builder.takeBytes();
    if (uploaded.length != length ||
        sha256.convert(uploaded).toString() != name.fileHash) {
      throw const WebdavException('Hash mismatch');
    }
    final path = name.toString();
    final existing = _files[path];
    if (existing != null) {
      if (sha256.convert(existing).toString() == name.fileHash) return;
      throw WebdavFileCollision('File exists with different hash: $path');
    }
    _files[path] = uploaded;
    if (failAfterSnapshotStore && !name.isBlob) {
      failAfterSnapshotStore = false;
      throw const WebdavException('Test: crash after snapshot store');
    }
  }

  @override
  Future<DownloadedWebdavRootFile> downloadRootFile(
    WebdavConfig config,
    SnapshotFileName name, {
    required int maxBytes,
  }) async {
    _countSnapshot('GET');
    final bytes = _files[name.toString()];
    if (bytes == null) throw const WebdavException('File not found');
    if (bytes.length > maxBytes) {
      throw const WebdavException('File exceeds maxBytes limit');
    }
    if (sha256.convert(bytes).toString() != name.fileHash) {
      throw const WebdavException('Snapshot file hash mismatch');
    }
    return DownloadedWebdavRootFile(name: name, bytes: bytes);
  }

  @override
  Future<void> deleteSnapshot(
    WebdavConfig config,
    SnapshotFileName name,
  ) async {
    if (name.isBlob) throw const WebdavException('Expected snapshot name');
    _countSnapshot('DELETE');
    _files.remove(name.toString());
  }

  WebdavSyncFileKind? _parseSyncFileKind(String name) {
    if (name.endsWith('.vfsync')) return WebdavSyncFileKind.event;
    if (name.endsWith('.manifest')) return WebdavSyncFileKind.manifest;
    if (name.endsWith('.commit')) return WebdavSyncFileKind.commit;
    if (name.endsWith('.blob')) return WebdavSyncFileKind.blob;
    return null;
  }

  (String?, int?) _parseEventPath(String relativePath) {
    final parts = relativePath.split('/');
    if (parts.length >= 5 &&
        parts[0] == 'verifin-sync' &&
        parts[1] == 'v1' &&
        parts[2] == 'events') {
      final deviceId = parts[3];
      final filename = parts[4];
      // Production event paths carry the immutable operation id after the
      // sequence. Keep accepting the legacy numeric form for old fixtures.
      final match = RegExp(
        r'^(\d+)(?:-[A-Za-z0-9._~-]+)?\.vfsync$',
      ).firstMatch(filename);
      if (match != null) {
        final sequence = int.tryParse(match.group(1)!);
        return (deviceId, sequence);
      }
    }
    return (null, null);
  }
}
