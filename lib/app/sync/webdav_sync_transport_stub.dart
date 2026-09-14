import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../backup/webdav_config.dart';
import 'sync_codec.dart';
import 'sync_models.dart';
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

  /// Get all created directories for testing.
  Set<String> get createdDirectories => Set.unmodifiable(_createdDirectories);

  /// Get all files for testing (mutable for test setup).
  Map<String, Uint8List> get files => _files;

  /// Test control: fail commit uploads.
  bool failCommitUploads = false;

  @override
  Future<void> ensureSyncTree(WebdavConfig config) async {
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
    final codec = SyncCodec(passphrase: '');

    // Upload event files: serialize the full SyncEvent as the file content
    // so the engine can decode it with SyncEvent.fromJson.
    for (var i = 0; i < events.length; i++) {
      final event = events[i];
      final eventPath =
          'verifin-sync/v1/events/$deviceId/${sequence + i}.vfsync';
      final eventBytes = utf8.encode(jsonEncode(event.toJson()));
      _files[eventPath] = Uint8List.fromList(eventBytes);
    }

    // Upload manifest
    final manifestPath = 'verifin-sync/v1/batches/$deviceId/$batchId.manifest';
    final manifest = {
      'batchId': batchId,
      'operationIds': events.map((e) => e.operationId).toList(),
      'blobHashes': <String>[],
      'manifestHash': 'stub-manifest-hash',
    };
    final manifestBytes = utf8.encode(jsonEncode(manifest));
    _files[manifestPath] = Uint8List.fromList(manifestBytes);

    // Upload commit marker
    if (includeCommit) {
      final commitPath = 'verifin-sync/v1/batches/$deviceId/$batchId.commit';
      _files[commitPath] = Uint8List.fromList(utf8.encode('committed'));
    }
  }

  @override
  Future<List<WebdavSyncFile>> listSyncFiles(WebdavConfig config) async {
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
      final match = RegExp(r'^(\d+)\.vfsync$').firstMatch(filename);
      if (match != null) {
        final sequence = int.tryParse(match.group(1)!);
        return (deviceId, sequence);
      }
    }
    return (null, null);
  }
}
