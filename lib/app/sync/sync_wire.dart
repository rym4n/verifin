import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'sync_models.dart';

/// Raw attachments are capped at 25 MiB; every encoded network document is
/// capped independently at 32 MiB. Chunking accounts for two base64 expansions
/// in encrypted blobs instead of assuming raw size equals envelope size.
class SyncWireLimits {
  const SyncWireLimits({
    this.maxAttachmentBytes = 25 * 1024 * 1024,
    this.maxEnvelopeBytes = 32 * 1024 * 1024,
  });
  final int maxAttachmentBytes;
  final int maxEnvelopeBytes;
  int get chunkBytes => min(
    8 * 1024 * 1024,
    max(1, ((maxEnvelopeBytes - 1024) * 9 / 16).floor()),
  );
}

({Uint8List bytes, String prefix}) _attachment(
  Object? value,
  SyncWireLimits limits,
) {
  if (value is! Map || value['dataUrl'] is! String) {
    throw const FormatException('Invalid sync attachment');
  }
  final dataUrl = value['dataUrl'] as String;
  final comma = dataUrl.indexOf(',');
  if (comma < 0 || !dataUrl.substring(0, comma).endsWith(';base64')) {
    throw const FormatException('Invalid sync attachment encoding');
  }
  final encoded = dataUrl.substring(comma + 1);
  if (encoded.length > ((limits.maxAttachmentBytes + 2) ~/ 3) * 4) {
    throw const FormatException('Invalid sync attachment size');
  }
  final bytes = base64Decode(encoded);
  if (bytes.length > limits.maxAttachmentBytes) {
    throw const FormatException('Invalid sync attachment size');
  }
  return (bytes: bytes, prefix: dataUrl.substring(0, comma + 1));
}

Map<String, Uint8List> syncAttachmentBlobs(
  Iterable<SyncEvent> events, {
  SyncWireLimits limits = const SyncWireLimits(),
  Set<String> legacyInlineOperationIds = const {},
}) {
  final blobs = <String, Uint8List>{};
  for (final event in events) {
    if (event.entity.type != 'attachments' ||
        event.operation == SyncOperationKind.delete) {
      continue;
    }
    final attachment = _attachment(event.payload, limits);
    if (legacyInlineOperationIds.contains(event.operationId)) {
      blobs[sha256.convert(attachment.bytes).toString()] = attachment.bytes;
      continue;
    }
    for (
      var offset = 0;
      offset < max(1, attachment.bytes.length);
      offset += limits.chunkBytes
    ) {
      final chunk = Uint8List.sublistView(
        attachment.bytes,
        offset,
        min(offset + limits.chunkBytes, attachment.bytes.length),
      );
      blobs[sha256.convert(chunk).toString()] = chunk;
    }
  }
  return blobs;
}

SyncEvent syncEventForWire(
  SyncEvent event, {
  SyncWireLimits limits = const SyncWireLimits(),
}) {
  if (event.entity.type != 'attachments' ||
      event.operation == SyncOperationKind.delete) {
    return event;
  }
  if (event.payload is Map &&
      (event.payload as Map).containsKey('blobChunks')) {
    return event;
  }
  final attachment = _attachment(event.payload, limits);
  final chunks = <String>[];
  for (
    var offset = 0;
    offset < max(1, attachment.bytes.length);
    offset += limits.chunkBytes
  ) {
    chunks.add(
      sha256
          .convert(
            Uint8List.sublistView(
              attachment.bytes,
              offset,
              min(offset + limits.chunkBytes, attachment.bytes.length),
            ),
          )
          .toString(),
    );
  }
  final payload = <String, Object?>{
    ...Map<String, Object?>.from(event.payload as Map)..remove('dataUrl'),
    'blobHash': sha256.convert(attachment.bytes).toString(),
    'blobChunks': chunks,
    'byteLength': attachment.bytes.length,
    'dataUrlPrefix': attachment.prefix,
    'materializedHash': event.payloadHash,
  };
  return _withPayload(event, payload);
}

Set<String> syncBlobHashes(
  Iterable<SyncEvent> events, {
  SyncWireLimits limits = const SyncWireLimits(),
}) => {
  // The wire shape is authoritative. Old inline events referenced one complete
  // blob; deriving modern chunks would change an immutable legacy manifest.
  for (final event in events)
    if (event.entity.type == 'attachments' &&
        event.operation != SyncOperationKind.delete)
      if ((event.payload as Map).containsKey('dataUrl'))
        sha256.convert(_attachment(event.payload, limits).bytes).toString()
      else
        ...((event.payload as Map)['blobChunks'] as List).cast<String>(),
};

SyncEvent materializeSyncEvent(
  SyncEvent event,
  Map<String, Uint8List> blobs, {
  SyncWireLimits limits = const SyncWireLimits(),
}) {
  if (event.entity.type != 'attachments' ||
      event.operation == SyncOperationKind.delete) {
    return event;
  }
  final payload = Map<String, Object?>.from(event.payload as Map);
  if (payload.containsKey('dataUrl')) {
    _attachment(payload, limits);
    if (computeSyncPayloadHash(payload) != event.payloadHash) {
      throw const FormatException('Invalid sync materialized payload');
    }
    return event;
  }
  if (payload['byteLength'] is! int ||
      payload['blobChunks'] is! List ||
      payload['dataUrlPrefix'] is! String) {
    throw const FormatException('Invalid sync attachment reference');
  }
  final size = payload['byteLength'] as int;
  if (size < 0 || size > limits.maxAttachmentBytes) {
    throw const FormatException('Invalid sync attachment size');
  }
  final builder = BytesBuilder(copy: false);
  for (final hash in payload['blobChunks'] as List) {
    final chunk = blobs[hash];
    if (chunk == null || builder.length + chunk.length > size) {
      throw const FormatException('Invalid sync attachment chunks');
    }
    builder.add(chunk);
  }
  final bytes = builder.takeBytes();
  if (bytes.length != size ||
      sha256.convert(bytes).toString() != payload['blobHash']) {
    throw const FormatException('Invalid sync attachment hash');
  }
  final expected = payload.remove('materializedHash');
  final prefix = payload.remove('dataUrlPrefix');
  payload.remove('blobHash');
  payload.remove('blobChunks');
  payload.remove('byteLength');
  payload['dataUrl'] = '$prefix${base64Encode(bytes)}';
  if (computeSyncPayloadHash(payload) != expected) {
    throw const FormatException('Invalid sync materialized payload');
  }
  return _withPayload(event, payload);
}

SyncEvent _withPayload(SyncEvent event, Object? payload) => SyncEvent(
  protocolVersion: event.protocolVersion,
  operationId: event.operationId,
  version: event.version,
  entity: event.entity,
  operation: event.operation,
  payloadHash: computeSyncPayloadHash(payload),
  payload: payload,
  batchId: event.batchId,
  keyFingerprint: event.keyFingerprint,
);

Map<String, Object?> syncManifest(
  String batchId,
  List<SyncEvent> events, {
  SyncWireLimits limits = const SyncWireLimits(),
  bool eventsAreWire = false,
}) {
  final sorted =
      events
          .map((e) => eventsAreWire ? e : syncEventForWire(e, limits: limits))
          .toList()
        ..sort((a, b) => a.operationId.compareTo(b.operationId));
  final body = <String, Object?>{
    'batchId': batchId,
    'operationIds': sorted.map((e) => e.operationId).toList(),
    'blobHashes': syncBlobHashes(sorted, limits: limits).toList()..sort(),
    'payloadHashes': {for (final e in sorted) e.operationId: e.payloadHash},
  };
  return {
    'protocolVersion': syncProtocolVersion,
    ...body,
    'manifestHash': computeSyncPayloadHash(body),
  };
}

void validateSyncManifest(Map<String, Object?> manifest) {
  if (manifest['protocolVersion'] != syncProtocolVersion) {
    throw const FormatException('protocol_version');
  }
  final body = {
    for (final key in [
      'batchId',
      'operationIds',
      'blobHashes',
      'payloadHashes',
    ])
      key: manifest[key],
  };
  if (computeSyncPayloadHash(body) != manifest['manifestHash']) {
    throw const FormatException('manifest_hash_mismatch');
  }
}

Map<String, Object?> syncCommit(
  Map<String, Object?> manifest,
  List<int> manifestBytes,
) => {
  'protocolVersion': syncProtocolVersion,
  'batchId': manifest['batchId'],
  'manifestHash': manifest['manifestHash'],
  'manifestFileHash': sha256.convert(manifestBytes).toString(),
};
Uint8List syncJsonBytes(Object? value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));
