import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

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
  request.followRedirects = false;
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

String _rootedSyncPath(String relativePath) {
  final segments = _logicalPathSegments(relativePath);
  if (segments.first == 'verifin-sync') {
    if (segments.length == 1 || segments[1] == 'v1') {
      return segments.join('/');
    }
    throw const WebdavException('Sync path is outside the v1 root');
  }
  return <String>['verifin-sync', 'v1', ...segments].join('/');
}

/// Join base collection URL with relative sync path, encoding each segment.
Uri _syncFileUri(WebdavConfig config, String relativePath) {
  final base = _collectionUri(config);
  final segments = _rootedSyncPath(relativePath).split('/');
  final encodedPath = segments.map((s) => Uri.encodeComponent(s)).join('/');
  final uri = base.resolve(encodedPath);
  _validateSyncUri(base, uri, segments);
  return uri;
}

List<String> _logicalPathSegments(String value) {
  if (value.isEmpty) {
    throw const WebdavException('Sync path is empty');
  }
  return value.split('/').map(_validatePathSegment).toList(growable: false);
}

String _validatePathSegment(String raw) {
  if (raw.isEmpty || raw == '.' || raw == '..' || raw.contains('\\')) {
    throw const WebdavException('Unsafe sync path segment');
  }
  final decoded = _decodePathSegment(raw);
  if (decoded.isEmpty ||
      decoded == '.' ||
      decoded == '..' ||
      decoded.contains('/') ||
      decoded.contains('\\') ||
      RegExp(r'[\x00-\x1F\x7F]').hasMatch(decoded)) {
    throw const WebdavException('Unsafe sync path segment');
  }
  return decoded;
}

String _decodePathSegment(String raw) {
  try {
    return Uri.decodeComponent(raw);
  } on FormatException {
    throw const WebdavException('Malformed sync path segment');
  }
}

void _validateSyncUri(Uri base, Uri uri, List<String> syncSegments) {
  if (uri.scheme != base.scheme ||
      uri.host != base.host ||
      uri.port != base.port) {
    throw const WebdavException('Sync URI escapes configured collection');
  }
  final collectionSegments = base.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
  final expected = <String>[...collectionSegments, ...syncSegments];
  if (uri.pathSegments.length != expected.length ||
      !_sameSegments(uri.pathSegments, expected) ||
      syncSegments.first != 'verifin-sync' ||
      (syncSegments.length > 1 && syncSegments[1] != 'v1')) {
    throw const WebdavException('Sync URI escapes configured collection');
  }
}

bool _sameSegments(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
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
/// Format: verifin-sync/v1/events/{deviceId}/{20-digit-sequence}-{operationId}.vfsync
(String?, int?) _parseEventPath(String relativePath) {
  final parts = relativePath.split('/');
  if (parts.length == 5 &&
      parts[0] == 'verifin-sync' &&
      parts[1] == 'v1' &&
      parts[2] == 'events' &&
      parts[3].isNotEmpty) {
    final deviceId = parts[3];
    final filename = parts[4];
    final match = RegExp(r'^(\d{20})-([^.]+)\.vfsync$').firstMatch(filename);
    if (match != null) {
      final sequence = int.tryParse(match.group(1)!);
      return (deviceId, sequence);
    }
  }
  return (null, null);
}

String? _normalizeSyncPath(String href, WebdavConfig config) {
  final reference = Uri.tryParse(href);
  if (reference == null || reference.hasQuery || reference.hasFragment) {
    return null;
  }
  final collectionUri = _collectionUri(config);
  if (reference.hasScheme &&
      (reference.scheme != collectionUri.scheme ||
          reference.host != collectionUri.host ||
          reference.port != collectionUri.port)) {
    return null;
  }
  if (!reference.hasScheme && reference.hasAuthority) {
    return null;
  }

  final resolved = collectionUri.resolveUri(reference);
  if (resolved.scheme != collectionUri.scheme ||
      resolved.host != collectionUri.host ||
      resolved.port != collectionUri.port) {
    return null;
  }

  final collectionSegments = collectionUri.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
  final requiredPrefix = <String>[...collectionSegments, 'verifin-sync', 'v1'];
  final resolvedSegments = <String>[];
  for (final rawSegment in resolved.path.split('/')) {
    if (rawSegment.isEmpty) continue;
    resolvedSegments.add(_validatePathSegment(rawSegment));
  }
  if (resolvedSegments.length < requiredPrefix.length ||
      !_sameSegments(
        resolvedSegments.sublist(0, requiredPrefix.length),
        requiredPrefix,
      )) {
    return null;
  }
  return resolvedSegments.sublist(collectionSegments.length).join('/');
}

class _PropfindEntry {
  const _PropfindEntry({
    required this.href,
    required this.isCollection,
    required this.sizeBytes,
  });

  final String href;
  final bool isCollection;
  final int sizeBytes;
}

List<_PropfindEntry> _parsePropfindEntries(String xml) {
  try {
    final document = XmlDocument.parse(xml);
    if (document.rootElement.name.local != 'multistatus') {
      throw const WebdavException('Malformed PROPFIND response');
    }
    final responseElements = document.rootElement.children
        .whereType<XmlElement>()
        .where((element) => element.name.local == 'response');
    return responseElements
        .map((response) {
          final hrefs = response.children
              .whereType<XmlElement>()
              .where((element) => element.name.local == 'href')
              .toList(growable: false);
          final resourceTypes = response.descendants
              .whereType<XmlElement>()
              .where((element) => element.name.local == 'resourcetype')
              .toList(growable: false);
          if (hrefs.length != 1 ||
              hrefs.single.innerText.trim().isEmpty ||
              resourceTypes.length != 1) {
            throw const WebdavException('Malformed PROPFIND response entry');
          }
          final sizeElements = response.descendants
              .whereType<XmlElement>()
              .where((element) => element.name.local == 'getcontentlength')
              .toList(growable: false);
          final sizeBytes = sizeElements.isEmpty
              ? 0
              : int.tryParse(sizeElements.first.innerText.trim()) ?? 0;
          final isCollection = resourceTypes.single.descendants
              .whereType<XmlElement>()
              .any((element) => element.name.local == 'collection');
          return _PropfindEntry(
            href: hrefs.single.innerText.trim(),
            isCollection: isCollection,
            sizeBytes: sizeBytes,
          );
        })
        .toList(growable: false);
  } on WebdavException {
    rethrow;
  } on XmlException {
    throw const WebdavException('Malformed PROPFIND response');
  }
}

/// Parse PROPFIND response for sync files (without extension filter).
List<WebdavSyncFile> _parseSyncPropfind(
  String xml,
  String basePath,
  WebdavConfig config,
) {
  final files = <WebdavSyncFile>[];
  final entries = _parsePropfindEntries(xml);

  for (final entry in entries) {
    final relativePath = _normalizeSyncPath(entry.href, config);
    if (relativePath == null) {
      throw const WebdavException('PROPFIND href is outside sync root');
    }
    _validatePropfindDepth(relativePath, basePath);

    final kind = _parseSyncFileKind(relativePath);
    if (kind == null) continue;

    final (deviceId, sequence) = kind == WebdavSyncFileKind.event
        ? _parseEventPath(relativePath)
        : (null, null);
    if (kind == WebdavSyncFileKind.event &&
        (deviceId == null || sequence == null)) {
      throw const WebdavException('Malformed sync event path');
    }

    files.add(
      WebdavSyncFile(
        relativePath: relativePath,
        kind: kind,
        deviceId: deviceId,
        sequence: sequence,
        sizeBytes: entry.sizeBytes,
        modifiedAt: DateTime.now(),
      ),
    );
  }

  return files;
}

void _abortResponse(HttpClient client) => client.close(force: true);

Future<Uint8List> _readResponseWithLimit(
  HttpClient client,
  HttpClientResponse response, {
  required int maxBytes,
  required String errorMessage,
}) async {
  if (response.contentLength > maxBytes) {
    _abortResponse(client);
    throw WebdavException(errorMessage);
  }

  final builder = BytesBuilder(copy: false);
  var totalBytes = 0;
  final iterator = StreamIterator<List<int>>(response);
  try {
    while (await iterator.moveNext()) {
      final chunk = iterator.current;
      totalBytes += chunk.length;
      if (totalBytes > maxBytes) {
        _abortResponse(client);
        throw WebdavException(errorMessage);
      }
      builder.add(chunk);
    }
    return builder.toBytes();
  } finally {
    unawaited(iterator.cancel());
  }
}

void _validatePropfindDepth(String relativePath, String basePath) {
  if (relativePath == basePath) return;
  final prefix = '$basePath/';
  if (!relativePath.startsWith(prefix) ||
      relativePath.substring(prefix.length).contains('/')) {
    throw const WebdavException('PROPFIND href is outside requested path');
  }
}

/// Real WebDAV sync transport implementation.
class WebdavSyncTransportImpl implements WebdavSyncTransport {
  @override
  Future<void> ensureSyncTree(WebdavConfig config) async {
    final client = _newClient();
    try {
      // Create directories level by level
      final paths = [
        'verifin-sync',
        'verifin-sync/v1',
        'verifin-sync/v1/events',
        'verifin-sync/v1/blobs',
        'verifin-sync/v1/batches',
      ];

      for (final path in paths) {
        await _mkcolIfNeeded(client, _syncFileUri(config, path), config);
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
    final request = await _open(client, 'MKCOL', uri, config);
    final response = await request.close().timeout(_responseTimeout);
    await response.drain<void>();
    if (response.statusCode != HttpStatus.created &&
        response.statusCode != HttpStatus.methodNotAllowed) {
      throw WebdavException('MKCOL failed: ${response.statusCode}');
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

      await _ensureParentDirectories(client, config, relativePath);

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

      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.created &&
          response.statusCode != HttpStatus.noContent) {
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
    final request = await _open(client, 'GET', uri, config);
    final response = await request.close().timeout(_responseTimeout);

    if (response.statusCode == 404) {
      await response.drain<void>();
      return null;
    }

    if (response.statusCode < HttpStatus.ok || response.statusCode >= 300) {
      _abortResponse(client);
      throw WebdavException('GET failed: ${response.statusCode}');
    }
    final bytes = await _readResponseWithLimit(
      client,
      response,
      maxBytes: syncMaxDownloadBytes,
      errorMessage: 'Existing file exceeds sync size limit',
    );
    final hash = sha256.convert(bytes);
    return hash.toString();
  }

  Future<void> _ensureParentDirectories(
    HttpClient client,
    WebdavConfig config,
    String relativePath,
  ) async {
    final segments = _rootedSyncPath(relativePath).split('/');
    if (segments.length < 2) {
      throw const WebdavException('Sync file path has no parent directory');
    }
    for (var count = 1; count < segments.length; count++) {
      final directoryPath = segments.sublist(0, count).join('/');
      await _mkcolIfNeeded(client, _syncFileUri(config, directoryPath), config);
    }
  }

  @override
  Future<List<WebdavSyncFile>> listSyncFiles(WebdavConfig config) async {
    final client = _newClient();
    try {
      final files = <WebdavSyncFile>[];

      // List events/*/
      files.addAll(await _listEventsRecursive(client, config));

      // List blobs/
      files.addAll(
        await _listDirectory(
          client,
          _syncFileUri(config, 'verifin-sync/v1/blobs'),
          'verifin-sync/v1/blobs',
          config,
        ),
      );

      // List batches/*/
      files.addAll(await _listBatchesRecursive(client, config));

      return files;
    } catch (error) {
      _fail(error);
    } finally {
      client.close(force: true);
    }
  }

  Future<List<WebdavSyncFile>> _listEventsRecursive(
    HttpClient client,
    WebdavConfig config,
  ) async {
    final files = <WebdavSyncFile>[];
    final eventsPath = 'verifin-sync/v1/events';
    final eventsUri = _syncFileUri(config, eventsPath);

    // List device directories
    final deviceDirs = await _listDirectories(
      client,
      eventsUri,
      eventsPath,
      config,
    );

    for (final deviceDir in deviceDirs) {
      final devicePath = '$eventsPath/$deviceDir';
      final deviceUri = _syncFileUri(config, devicePath);
      files.addAll(await _listDirectory(client, deviceUri, devicePath, config));
    }

    return files;
  }

  Future<List<WebdavSyncFile>> _listBatchesRecursive(
    HttpClient client,
    WebdavConfig config,
  ) async {
    final files = <WebdavSyncFile>[];
    final batchesPath = 'verifin-sync/v1/batches';
    final batchesUri = _syncFileUri(config, batchesPath);

    // List device directories
    final deviceDirs = await _listDirectories(
      client,
      batchesUri,
      batchesPath,
      config,
    );

    for (final deviceDir in deviceDirs) {
      final devicePath = '$batchesPath/$deviceDir';
      final deviceUri = _syncFileUri(config, devicePath);
      files.addAll(await _listDirectory(client, deviceUri, devicePath, config));
    }

    return files;
  }

  Future<List<String>> _listDirectories(
    HttpClient client,
    Uri uri,
    String basePath,
    WebdavConfig config,
  ) async {
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

    if (response.statusCode == HttpStatus.notFound) {
      return [];
    }
    if (response.statusCode != HttpStatus.multiStatus) {
      throw WebdavException('PROPFIND failed: ${response.statusCode}');
    }

    final dirs = <String>[];
    for (final entry in _parsePropfindEntries(body)) {
      final normalized = _normalizeSyncPath(entry.href, config);
      if (normalized == null) {
        throw const WebdavException('PROPFIND href is outside sync root');
      }
      _validatePropfindDepth(normalized, basePath);
      if (normalized == basePath) continue;
      if (entry.isCollection) {
        dirs.add(normalized.substring(basePath.length + 1));
      }
    }
    return dirs;
  }

  Future<List<WebdavSyncFile>> _listDirectory(
    HttpClient client,
    Uri uri,
    String basePath,
    WebdavConfig config,
  ) async {
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

    if (response.statusCode == HttpStatus.notFound) {
      return [];
    }
    if (response.statusCode != HttpStatus.multiStatus) {
      throw WebdavException('PROPFIND failed: ${response.statusCode}');
    }
    return _parseSyncPropfind(body, basePath, config);
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

      if (response.statusCode < HttpStatus.ok || response.statusCode >= 300) {
        _abortResponse(client);
        throw WebdavException('Download failed: ${response.statusCode}');
      }
      return await _readResponseWithLimit(
        client,
        response,
        maxBytes: maxBytes,
        errorMessage: 'File exceeds maxBytes limit',
      );
    } catch (error) {
      _fail(error);
    } finally {
      client.close(force: true);
    }
  }
}
