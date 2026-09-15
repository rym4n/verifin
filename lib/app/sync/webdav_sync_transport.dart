import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../backup/webdav_config.dart';

/// Maximum download size for sync files (32 MB).
const int syncMaxDownloadBytes = 32 * 1024 * 1024;

/// WebDAV file collision: same path, different content hash.
class WebdavFileCollision implements Exception {
  const WebdavFileCollision(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Sync file kind based on extension.
enum WebdavSyncFileKind { event, manifest, commit, blob }

/// A sync file discovered on the WebDAV server.
class WebdavSyncFile {
  const WebdavSyncFile({
    required this.relativePath,
    required this.kind,
    this.deviceId,
    this.sequence,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  final String relativePath;
  final WebdavSyncFileKind kind;
  final String? deviceId;
  final int? sequence;
  final int sizeBytes;
  final DateTime modifiedAt;
}

/// WebDAV sync transport interface.
abstract interface class WebdavSyncTransport {
  /// Ensure the sync directory tree exists.
  Future<void> ensureSyncTree(WebdavConfig config);

  /// Upload a file immutably (PUT only if absent or same hash).
  Future<void> putImmutable(
    WebdavConfig config,
    String relativePath,
    Stream<List<int>> bytes,
    int length,
    String expectedHash,
  );

  /// List all sync files.
  Future<List<WebdavSyncFile>> listSyncFiles(WebdavConfig config);

  /// Download a sync file with size limit.
  Future<Uint8List> downloadSyncFile(
    WebdavConfig config,
    String relativePath, {
    required int maxBytes,
  });
}

/// WebDAV operation exception.
class WebdavException implements Exception {
  const WebdavException(this.message);

  final String message;

  @override
  String toString() => message;
}

const Duration _connectTimeout = Duration(seconds: 30);
const Duration _responseTimeout = Duration(seconds: 60);

const String _propfindBody =
    '<?xml version="1.0" encoding="utf-8"?>'
    '<d:propfind xmlns:d="DAV:"><d:prop>'
    '<d:getlastmodified/><d:getcontentlength/><d:resourcetype/>'
    '</d:prop></d:propfind>';

HttpClient _newClient() => HttpClient()..connectionTimeout = _connectTimeout;

String _authHeader(WebdavConfig config) {
  final raw = '${config.username}:${config.password}';
  return 'Basic ${base64Encode(utf8.encode(raw))}';
}

Future<HttpClientRequest> _open(
  HttpClient client,
  String method,
  Uri uri,
  WebdavConfig config,
) async {
  final request = await client.openUrl(method, uri);
  request.headers.set(HttpHeaders.authorizationHeader, _authHeader(config));
  request.followRedirects = true;
  return request;
}

Never _fail(Object error) {
  if (error is WebdavException || error is WebdavFileCollision) {
    throw error;
  }
  if (error is TimeoutException) {
    throw const WebdavException('Connection timeout');
  }
  if (error is SocketException) {
    throw const WebdavException('Cannot connect to server');
  }
  if (error is HandshakeException) {
    throw const WebdavException('HTTPS handshake failed');
  }
  throw WebdavException('WebDAV request failed: $error');
}

Uri _collectionUri(WebdavConfig config) {
  final uri = Uri.tryParse(normalizeCollectionUrl(config.url));
  if (uri == null || !uri.hasScheme) {
    throw const WebdavException('Invalid WebDAV URL');
  }
  return uri;
}

/// Join base collection URL with relative sync path, encoding each segment.
Uri _syncFileUri(WebdavConfig config, String relativePath) {
  final base = _collectionUri(config);
  // Split path, encode each segment individually, then join
  final segments = relativePath.split('/');
  final encodedPath = segments.map((s) => Uri.encodeComponent(s)).join('/');
  return base.resolve(encodedPath);
}

/// Parse sync file kind from extension.
WebdavSyncFileKind? _parseSyncFileKind(String name) {
  if (name.endsWith('.vfsync')) return WebdavSyncFileKind.event;
  if (name.endsWith('.manifest')) return WebdavSyncFileKind.manifest;
  if (name.endsWith('.commit')) return WebdavSyncFileKind.commit;
  if (name.endsWith('.blob')) return WebdavSyncFileKind.blob;
  return null;
}

/// Extract deviceId and sequence from event file path.
/// Format: verifin-sync/v1/events/{deviceId}/{sequence}.vfsync
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

/// Parse PROPFIND response for sync files (without extension filter).
List<WebdavSyncFile> _parseSyncPropfind(String xml, String basePath) {
  final files = <WebdavSyncFile>[];
  final allFiles = parsePropfindResponse(xml);

  for (final file in allFiles) {
    final kind = _parseSyncFileKind(file.name);
    if (kind == null) continue;

    // Build relative path from href
    var relativePath = Uri.decodeFull(file.href);
    if (relativePath.startsWith('/')) {
      relativePath = relativePath.substring(1);
    }

    // Extract base path from href to get relative portion
    final baseNormalized = basePath.endsWith('/') ? basePath : '$basePath/';
    if (relativePath.startsWith(baseNormalized)) {
      relativePath = relativePath.substring(baseNormalized.length);
    }

    final (deviceId, sequence) = kind == WebdavSyncFileKind.event
        ? _parseEventPath(relativePath)
        : (null, null);

    files.add(
      WebdavSyncFile(
        relativePath: relativePath,
        kind: kind,
        deviceId: deviceId,
        sequence: sequence,
        sizeBytes: file.sizeBytes,
        modifiedAt: file.modifiedAt ?? DateTime.now(),
      ),
    );
  }

  return files;
}

/// Real WebDAV sync transport implementation.
class WebdavSyncTransportImpl implements WebdavSyncTransport {
  @override
  Future<void> ensureSyncTree(WebdavConfig config) async {
    final client = _newClient();
    try {
      final base = _collectionUri(config);

      // Create directories level by level
      final paths = [
        'verifin-sync',
        'verifin-sync/v1',
        'verifin-sync/v1/events',
        'verifin-sync/v1/blobs',
        'verifin-sync/v1/batches',
      ];

      for (final path in paths) {
        await _mkcolIfNeeded(client, base.resolve(path), config);
      }
    } catch (error) {
      _fail(error);
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _mkcolIfNeeded(
    HttpClient client,
    Uri uri,
    WebdavConfig config,
  ) async {
    try {
      final request = await _open(client, 'MKCOL', uri, config);
      final response = await request.close().timeout(_responseTimeout);
      await response.drain<void>();
      // 201: created, 405/301: already exists (ignore)
    } catch (_) {
      // Directory creation failure is non-fatal
    }
  }

  @override
  Future<void> putImmutable(
    WebdavConfig config,
    String relativePath,
    Stream<List<int>> bytes,
    int length,
    String expectedHash,
  ) async {
    final client = _newClient();
    try {
      final uri = _syncFileUri(config, relativePath);

      // Check if file exists
      final existing = await _getFileHash(client, uri, config);
      if (existing != null) {
        if (existing == expectedHash) {
          // Same hash, idempotent success
          return;
        } else {
          throw WebdavFileCollision(
            'File exists with different hash: $relativePath',
          );
        }
      }

      // Upload new file
      final request = await _open(client, 'PUT', uri, config);
      request.headers.contentType = ContentType('application', 'octet-stream');
      request.headers.contentLength = length;

      await for (final chunk in bytes) {
        request.add(chunk);
      }

      final response = await request.close();
      await response.drain<void>();

      if (response.statusCode >= 400) {
        throw WebdavException('Upload failed: ${response.statusCode}');
      }
    } catch (error) {
      _fail(error);
    } finally {
      client.close(force: true);
    }
  }

  Future<String?> _getFileHash(
    HttpClient client,
    Uri uri,
    WebdavConfig config,
  ) async {
    try {
      final request = await _open(client, 'GET', uri, config);
      final response = await request.close().timeout(_responseTimeout);

      if (response.statusCode == 404) {
        return null;
      }

      if (response.statusCode >= 400) {
        throw WebdavException('HEAD failed: ${response.statusCode}');
      }

      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
      }

      final bytes = builder.toBytes();
      final hash = sha256.convert(bytes);
      return hash.toString();
    } catch (_) {
      return null;
    }
  }

  @override
  Future<List<WebdavSyncFile>> listSyncFiles(WebdavConfig config) async {
    final client = _newClient();
    try {
      final base = _collectionUri(config);
      final files = <WebdavSyncFile>[];

      // List events/*/
      files.addAll(await _listEventsRecursive(client, base, config));

      // List blobs/
      files.addAll(
        await _listDirectory(
          client,
          base.resolve('verifin-sync/v1/blobs'),
          'verifin-sync/v1/blobs',
          config,
        ),
      );

      // List batches/*/
      files.addAll(await _listBatchesRecursive(client, base, config));

      return files;
    } catch (error) {
      _fail(error);
    } finally {
      client.close(force: true);
    }
  }

  Future<List<WebdavSyncFile>> _listEventsRecursive(
    HttpClient client,
    Uri base,
    WebdavConfig config,
  ) async {
    final files = <WebdavSyncFile>[];
    final eventsUri = base.resolve('verifin-sync/v1/events');

    // List device directories
    final deviceDirs = await _listDirectories(client, eventsUri, config);

    for (final deviceDir in deviceDirs) {
      final deviceUri = base.resolve('verifin-sync/v1/events/$deviceDir');
      files.addAll(
        await _listDirectory(
          client,
          deviceUri,
          'verifin-sync/v1/events/$deviceDir',
          config,
        ),
      );
    }

    return files;
  }

  Future<List<WebdavSyncFile>> _listBatchesRecursive(
    HttpClient client,
    Uri base,
    WebdavConfig config,
  ) async {
    final files = <WebdavSyncFile>[];
    final batchesUri = base.resolve('verifin-sync/v1/batches');

    // List device directories
    final deviceDirs = await _listDirectories(client, batchesUri, config);

    for (final deviceDir in deviceDirs) {
      final deviceUri = base.resolve('verifin-sync/v1/batches/$deviceDir');
      files.addAll(
        await _listDirectory(
          client,
          deviceUri,
          'verifin-sync/v1/batches/$deviceDir',
          config,
        ),
      );
    }

    return files;
  }

  Future<List<String>> _listDirectories(
    HttpClient client,
    Uri uri,
    WebdavConfig config,
  ) async {
    try {
      final request = await _open(client, 'PROPFIND', uri, config);
      request.headers.set('Depth', '1');
      request.headers.contentType = ContentType(
        'application',
        'xml',
        charset: 'utf-8',
      );
      request.write(_propfindBody);

      final response = await request.close().timeout(_responseTimeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_responseTimeout);

      if (response.statusCode == 404) {
        return [];
      }

      if (response.statusCode >= 400) {
        throw WebdavException('PROPFIND failed: ${response.statusCode}');
      }

      // Parse for collections only
      final dirs = <String>[];
      final responses = RegExp(
        r'<[^>]*?response[^>]*?>(.*?)</[^>]*?response[^>]*?>',
        dotAll: true,
        caseSensitive: false,
      ).allMatches(body);

      for (final response in responses) {
        final inner = response.group(1) ?? '';
        final href = _stripTag(inner, 'href');
        if (href.isEmpty) continue;

        final isCollection = RegExp(
          r'<[^>]*?collection[^>]*?/?>',
          caseSensitive: false,
        ).hasMatch(inner);

        if (isCollection) {
          final decodedHref = Uri.decodeFull(href);
          var name = decodedHref;
          if (name.endsWith('/')) {
            name = name.substring(0, name.length - 1);
          }
          final slash = name.lastIndexOf('/');
          if (slash >= 0) {
            name = name.substring(slash + 1);
          }
          if (name.isNotEmpty &&
              !name.contains('v1') &&
              !name.contains('events') &&
              !name.contains('blobs') &&
              !name.contains('batches')) {
            dirs.add(name);
          }
        }
      }

      return dirs;
    } catch (_) {
      return [];
    }
  }

  Future<List<WebdavSyncFile>> _listDirectory(
    HttpClient client,
    Uri uri,
    String basePath,
    WebdavConfig config,
  ) async {
    try {
      final request = await _open(client, 'PROPFIND', uri, config);
      request.headers.set('Depth', '1');
      request.headers.contentType = ContentType(
        'application',
        'xml',
        charset: 'utf-8',
      );
      request.write(_propfindBody);

      final response = await request.close().timeout(_responseTimeout);
      final body = await response
          .transform(utf8.decoder)
          .join()
          .timeout(_responseTimeout);

      if (response.statusCode == 404) {
        return [];
      }

      if (response.statusCode >= 400) {
        throw WebdavException('PROPFIND failed: ${response.statusCode}');
      }

      return _parseSyncPropfind(body, basePath);
    } catch (_) {
      return [];
    }
  }

  @override
  Future<Uint8List> downloadSyncFile(
    WebdavConfig config,
    String relativePath, {
    required int maxBytes,
  }) async {
    final client = _newClient();
    try {
      final uri = _syncFileUri(config, relativePath);
      final request = await _open(client, 'GET', uri, config);
      final response = await request.close().timeout(_responseTimeout);

      if (response.statusCode >= 400) {
        throw WebdavException('Download failed: ${response.statusCode}');
      }

      final builder = BytesBuilder(copy: false);
      var totalBytes = 0;

      await for (final chunk in response) {
        totalBytes += chunk.length;
        if (totalBytes > maxBytes) {
          throw WebdavException(
            'File exceeds maxBytes limit: $totalBytes > $maxBytes',
          );
        }
        builder.add(chunk);
      }

      final bytes = builder.toBytes();
      return bytes;
    } catch (error) {
      _fail(error);
    } finally {
      client.close(force: true);
    }
  }
}

String _stripTag(String inner, String localName) {
  final match = RegExp(
    '<[^>]*?$localName[^>]*?>(.*?)</[^>]*?$localName[^>]*?>',
    dotAll: true,
    caseSensitive: false,
  ).firstMatch(inner);
  return match?.group(1)?.trim() ?? '';
}
