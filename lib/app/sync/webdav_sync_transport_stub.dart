import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../backup/webdav_config.dart';
import 'webdav_sync_transport.dart';

/// Stub WebDAV sync transport for testing (platform-independent).
class WebdavSyncTransportStub implements WebdavSyncTransport {
  WebdavSyncTransportStub({Map<String, Uint8List>? initialFiles})
    : _files = Map<String, Uint8List>.from(initialFiles ?? {});

  final Map<String, Uint8List> _files;
  final Set<String> _createdDirectories = {};

  /// Get all created directories for testing.
  Set<String> get createdDirectories => Set.unmodifiable(_createdDirectories);

  /// Get all files for testing (mutable for test setup).
  Map<String, Uint8List> get files => _files;

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
