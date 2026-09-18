import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'sync_codec.dart';
import 'sync_models.dart';
import 'sync_wire.dart';

const int _snapshotPlaintextBytes = 16 * 1024 * 1024;
const int _snapshotEnvelopeBytes = 24 * 1024 * 1024;
final RegExp _hex64 = RegExp(r'^[0-9a-f]{64}$');
final RegExp _deviceId = RegExp(r'^[0-9a-f]{32}$');
final RegExp _snapshotName = RegExp(
  r'^verifin-sync-v2-([0-9a-f]{32})-(\d{20})-(\d{8}T\d{9}Z)-([0-9a-f]{64})\.json$',
);
final RegExp _blobName = RegExp(r'^verifin-sync-v2-blob-([0-9a-f]{64})\.blob$');

class SyncSnapshotException implements Exception {
  const SyncSnapshotException(this.code);

  final String code;

  @override
  String toString() => code;
}

class SyncSnapshotLimits {
  const SyncSnapshotLimits({
    this.maxPlaintextBytes = _snapshotPlaintextBytes,
    this.maxEnvelopeBytes = _snapshotEnvelopeBytes,
  });

  final int maxPlaintextBytes;
  final int maxEnvelopeBytes;
}

/// Strict names for immutable v2 snapshot and encrypted blob files.
class SnapshotFileName {
  const SnapshotFileName._({
    required this.fileHash,
    this.deviceId,
    this.snapshotSequence,
    this.createdAtUtc,
  });

  final String? deviceId;
  final int? snapshotSequence;
  final DateTime? createdAtUtc;
  final String fileHash;

  bool get isBlob => deviceId == null;

  factory SnapshotFileName.snapshot({
    required String deviceId,
    required int snapshotSequence,
    required DateTime createdAtUtc,
    required String fileHash,
  }) {
    _requireDeviceId(deviceId);
    if (snapshotSequence < 0) {
      throw const FormatException('snapshot_sequence');
    }
    _requireHash(fileHash);
    return SnapshotFileName._(
      deviceId: deviceId,
      snapshotSequence: snapshotSequence,
      createdAtUtc: _atMillisecondPrecision(createdAtUtc),
      fileHash: fileHash,
    );
  }

  factory SnapshotFileName.blob({required String fileHash}) {
    _requireHash(fileHash);
    return SnapshotFileName._(fileHash: fileHash);
  }

  factory SnapshotFileName.parse(String value) {
    final snapshot = _snapshotName.firstMatch(value);
    if (snapshot != null) {
      final timestamp = _parseTimestamp(snapshot[3]!);
      return SnapshotFileName.snapshot(
        deviceId: snapshot[1]!,
        snapshotSequence: int.parse(snapshot[2]!),
        createdAtUtc: timestamp,
        fileHash: snapshot[4]!,
      );
    }
    final blob = _blobName.firstMatch(value);
    if (blob != null) return SnapshotFileName.blob(fileHash: blob[1]!);
    throw const FormatException('snapshot_filename');
  }

  SnapshotFileName withFileHash(String value) => isBlob
      ? SnapshotFileName.blob(fileHash: value)
      : SnapshotFileName.snapshot(
          deviceId: deviceId!,
          snapshotSequence: snapshotSequence!,
          createdAtUtc: createdAtUtc!,
          fileHash: value,
        );

  @override
  String toString() {
    if (isBlob) return 'verifin-sync-v2-blob-$fileHash.blob';
    final timestamp = _formatTimestamp(createdAtUtc!);
    return 'verifin-sync-v2-$deviceId-'
        '${snapshotSequence!.toString().padLeft(20, '0')}-$timestamp-$fileHash.json';
  }

  static void _requireDeviceId(String value) {
    if (!_deviceId.hasMatch(value)) throw const FormatException('device_id');
  }

  static void _requireHash(String value) {
    if (!_hex64.hasMatch(value)) throw const FormatException('file_hash');
  }

  static String _formatTimestamp(DateTime value) {
    final utc = value.toUtc();
    String two(int number) => number.toString().padLeft(2, '0');
    String three(int number) => number.toString().padLeft(3, '0');
    return '${utc.year.toString().padLeft(4, '0')}${two(utc.month)}${two(utc.day)}'
        'T${two(utc.hour)}${two(utc.minute)}${two(utc.second)}'
        '${three(utc.millisecond)}Z';
  }

  static DateTime _atMillisecondPrecision(DateTime value) {
    final utc = value.toUtc();
    return DateTime.utc(
      utc.year,
      utc.month,
      utc.day,
      utc.hour,
      utc.minute,
      utc.second,
      utc.millisecond,
    );
  }

  static DateTime _parseTimestamp(String value) {
    try {
      final parsed = DateTime.utc(
        int.parse(value.substring(0, 4)),
        int.parse(value.substring(4, 6)),
        int.parse(value.substring(6, 8)),
        int.parse(value.substring(9, 11)),
        int.parse(value.substring(11, 13)),
        int.parse(value.substring(13, 15)),
        int.parse(value.substring(15, 18)),
      );
      if (_formatTimestamp(parsed) != value) {
        throw const FormatException('snapshot_timestamp');
      }
      return parsed;
    } on FormatException {
      rethrow;
    } catch (_) {
      throw const FormatException('snapshot_timestamp');
    }
  }
}

class SyncSnapshotBlobRef {
  const SyncSnapshotBlobRef({required this.rawHash, required this.fileHash});

  final String rawHash;
  final String fileHash;

  Map<String, Object?> toJson() => {'rawHash': rawHash, 'fileHash': fileHash};

  factory SyncSnapshotBlobRef.fromJson(Map<String, Object?> json) {
    final rawHash = json['rawHash'] as String?;
    final fileHash = json['fileHash'] as String?;
    if (rawHash == null || !_hex64.hasMatch(rawHash)) {
      throw const FormatException('raw_hash');
    }
    if (fileHash == null || !_hex64.hasMatch(fileHash)) {
      throw const FormatException('file_hash');
    }
    return SyncSnapshotBlobRef(rawHash: rawHash, fileHash: fileHash);
  }
}

class SyncSnapshotAttachmentBlob {
  const SyncSnapshotAttachmentBlob({
    required this.attachmentId,
    required this.byteLength,
    required this.dataUrlPrefix,
    required this.chunks,
  });

  final String attachmentId;
  final int byteLength;
  final String dataUrlPrefix;
  final List<SyncSnapshotBlobRef> chunks;

  Map<String, Object?> toJson() => {
    'attachmentId': attachmentId,
    'byteLength': byteLength,
    'dataUrlPrefix': dataUrlPrefix,
    'chunks': chunks.map((chunk) => chunk.toJson()).toList(),
  };

  factory SyncSnapshotAttachmentBlob.fromJson(Map<String, Object?> json) {
    final attachmentId = json['attachmentId'] as String?;
    final byteLength = (json['byteLength'] as num?)?.toInt();
    final dataUrlPrefix = json['dataUrlPrefix'] as String?;
    final rawChunks = json['chunks'];
    if (attachmentId == null ||
        attachmentId.isEmpty ||
        byteLength == null ||
        byteLength < 0 ||
        dataUrlPrefix == null ||
        rawChunks is! List) {
      throw const FormatException('attachment_blob');
    }
    return SyncSnapshotAttachmentBlob(
      attachmentId: attachmentId,
      byteLength: byteLength,
      dataUrlPrefix: dataUrlPrefix,
      chunks: rawChunks
          .map(
            (value) => SyncSnapshotBlobRef.fromJson(
              Map<String, Object?>.from(value as Map),
            ),
          )
          .toList(),
    );
  }
}

class SyncSnapshot {
  const SyncSnapshot({
    this.protocolVersion = syncSnapshotProtocolVersion,
    required this.deviceId,
    required this.snapshotSequence,
    required this.createdAtUtc,
    required this.keyFingerprint,
    required this.knownVector,
    required this.heads,
    required this.attachmentBlobs,
    required this.conflicts,
  });

  final int protocolVersion;
  final String deviceId;
  final int snapshotSequence;
  final DateTime createdAtUtc;
  final String keyFingerprint;
  final SyncVersionVector knownVector;
  final List<SyncEntityVersion> heads;
  final List<SyncSnapshotAttachmentBlob> attachmentBlobs;
  final List<SyncConflictRecord> conflicts;

  factory SyncSnapshot.fromProjection({
    required String deviceId,
    required int snapshotSequence,
    required DateTime createdAtUtc,
    required String keyFingerprint,
    required SyncVersionVector knownVector,
    required Iterable<SyncEvent> events,
    required List<SyncSnapshotAttachmentBlob> attachmentBlobs,
    List<SyncConflictRecord> conflicts = const [],
  }) {
    final heads = events
        .map(syncEventForWire)
        .map(
          (event) => SyncEntityVersion(
            entity: event.entity,
            version: event.version,
            payloadHash: event.payloadHash,
            payload: event.payload,
            deleted: event.operation == SyncOperationKind.delete,
            operationId: event.operationId,
          ),
        )
        .toList();
    return SyncSnapshot(
      deviceId: deviceId,
      snapshotSequence: snapshotSequence,
      createdAtUtc: createdAtUtc,
      keyFingerprint: keyFingerprint,
      knownVector: knownVector,
      heads: heads,
      attachmentBlobs: attachmentBlobs,
      conflicts: conflicts,
    );
  }

  Map<String, Object?> toJson() => {
    'protocolVersion': protocolVersion,
    'deviceId': deviceId,
    'snapshotSequence': snapshotSequence,
    'createdAtUtc': createdAtUtc.toUtc().toIso8601String(),
    'keyFingerprint': keyFingerprint,
    'knownVector': knownVector.toJson(),
    'heads': _sortedHeads().map(_headToJson).toList(),
    'attachmentBlobs': _sortedBlobs().map((blob) => blob.toJson()).toList(),
    'conflicts': _sortedConflicts().map(_conflictToJson).toList(),
  };

  factory SyncSnapshot.fromJson(Map<String, Object?> json) {
    final protocolVersion = (json['protocolVersion'] as num?)?.toInt();
    final deviceId = json['deviceId'] as String?;
    final snapshotSequence = (json['snapshotSequence'] as num?)?.toInt();
    final createdAt = json['createdAtUtc'] as String?;
    final keyFingerprint = json['keyFingerprint'] as String?;
    final knownVector = json['knownVector'];
    final heads = json['heads'];
    final attachmentBlobs = json['attachmentBlobs'];
    final conflicts = json['conflicts'];
    if (protocolVersion != syncSnapshotProtocolVersion ||
        deviceId == null ||
        snapshotSequence == null ||
        createdAt == null ||
        keyFingerprint == null ||
        knownVector is! Map ||
        heads is! List ||
        attachmentBlobs is! List ||
        conflicts is! List) {
      throw const FormatException('snapshot_document');
    }
    final snapshot = SyncSnapshot(
      protocolVersion: protocolVersion!,
      deviceId: deviceId,
      snapshotSequence: snapshotSequence,
      createdAtUtc: DateTime.parse(createdAt).toUtc(),
      keyFingerprint: keyFingerprint,
      knownVector: SyncVersionVector.fromJson(
        Map<String, Object?>.from(knownVector),
      ),
      heads: heads
          .map(
            (value) => _headFromJson(Map<String, Object?>.from(value as Map)),
          )
          .toList(),
      attachmentBlobs: attachmentBlobs
          .map(
            (value) => SyncSnapshotAttachmentBlob.fromJson(
              Map<String, Object?>.from(value as Map),
            ),
          )
          .toList(),
      conflicts: conflicts
          .map(
            (value) =>
                _conflictFromJson(Map<String, Object?>.from(value as Map)),
          )
          .toList(),
    );
    snapshot._validate();
    return snapshot;
  }

  List<SyncEntityVersion> _sortedHeads() {
    final result = List<SyncEntityVersion>.from(heads);
    result.sort((a, b) => _entitySort(a.entity, b.entity));
    return result;
  }

  List<SyncSnapshotAttachmentBlob> _sortedBlobs() {
    final result = List<SyncSnapshotAttachmentBlob>.from(attachmentBlobs);
    result.sort((a, b) => a.attachmentId.compareTo(b.attachmentId));
    return result;
  }

  List<SyncConflictRecord> _sortedConflicts() {
    final result = List<SyncConflictRecord>.from(conflicts);
    result.sort((a, b) => a.id.compareTo(b.id));
    return result;
  }

  void _validate({SnapshotFileName? source, String? expectedFingerprint}) {
    if (protocolVersion != syncSnapshotProtocolVersion) {
      throw const FormatException('snapshot_protocol_version');
    }
    SnapshotFileName._requireDeviceId(deviceId);
    if (snapshotSequence < 0 || keyFingerprint.isEmpty) {
      throw const FormatException('snapshot_metadata');
    }
    if (source != null &&
        (source.isBlob ||
            source.deviceId != deviceId ||
            source.snapshotSequence != snapshotSequence ||
            source.createdAtUtc != createdAtUtc.toUtc())) {
      throw const FormatException('snapshot_filename_mismatch');
    }
    if (expectedFingerprint != null && keyFingerprint != expectedFingerprint) {
      throw const SyncSnapshotException('key_fingerprint_mismatch');
    }
    final entities = <String>{};
    final operationIds = <String>{};
    for (final head in heads) {
      final entity =
          '${head.entity.scope}\n${head.entity.type}\n${head.entity.id}';
      if (!entities.add(entity) || !operationIds.add(head.operationId)) {
        throw const FormatException('snapshot_duplicate_head');
      }
      _validateVersion(head.version);
      if (!head.deleted &&
          computeSyncPayloadHash(head.payload) != head.payloadHash) {
        throw const FormatException('snapshot_payload_hash');
      }
    }
    final attachmentIds = <String>{};
    final rawHashes = <String, String>{};
    for (final attachment in attachmentBlobs) {
      if (!attachmentIds.add(attachment.attachmentId)) {
        throw const FormatException('snapshot_duplicate_attachment');
      }
      for (final chunk in attachment.chunks) {
        final previous = rawHashes[chunk.rawHash];
        if (previous != null && previous != chunk.fileHash) {
          throw const FormatException('snapshot_blob_mapping');
        }
        rawHashes[chunk.rawHash] = chunk.fileHash;
      }
    }
    final conflictIds = <String>{};
    for (final conflict in conflicts) {
      if (!conflictIds.add(conflict.id)) {
        throw const FormatException('snapshot_duplicate_conflict');
      }
      _validateVersion(conflict.local.version);
      _validateVersion(conflict.remote.version);
    }
  }

  void _validateVersion(SyncVersion version) {
    for (final entry in version.context.values.entries) {
      if ((knownVector.values[entry.key] ?? -1) < entry.value) {
        throw const FormatException('snapshot_known_vector');
      }
    }
    if ((knownVector.values[version.dot.deviceId] ?? -1) <
        version.dot.sequence) {
      throw const FormatException('snapshot_known_vector');
    }
  }
}

Map<String, Object?> _headToJson(SyncEntityVersion head) => {
  'operationId': head.operationId,
  'entity': head.entity.toJson(),
  'version': head.version.toJson(),
  'deleted': head.deleted,
  'payloadHash': head.payloadHash,
  'payload': head.payload,
};

SyncEntityVersion _headFromJson(Map<String, Object?> json) {
  final operationId = json['operationId'] as String?;
  final entity = json['entity'];
  final version = json['version'];
  final deleted = json['deleted'];
  final payloadHash = json['payloadHash'] as String?;
  if (operationId == null ||
      operationId.isEmpty ||
      entity is! Map ||
      version is! Map ||
      deleted is! bool ||
      payloadHash == null ||
      payloadHash.isEmpty) {
    throw const FormatException('snapshot_head');
  }
  return SyncEntityVersion(
    entity: SyncEntityKey.fromJson(Map<String, Object?>.from(entity)),
    version: SyncVersion.fromJson(Map<String, Object?>.from(version)),
    payloadHash: payloadHash,
    payload: json['payload'],
    deleted: deleted,
    operationId: operationId,
  );
}

Map<String, Object?> _conflictToJson(SyncConflictRecord conflict) => {
  'id': conflict.id,
  'entity': conflict.entity.toJson(),
  'local': _headToJson(conflict.local),
  'remote': _headToJson(conflict.remote),
};

SyncConflictRecord _conflictFromJson(Map<String, Object?> json) {
  final id = json['id'] as String?;
  final entity = json['entity'];
  final local = json['local'];
  final remote = json['remote'];
  if (id == null ||
      id.isEmpty ||
      entity is! Map ||
      local is! Map ||
      remote is! Map) {
    throw const FormatException('snapshot_conflict');
  }
  return SyncConflictRecord(
    id: id,
    entity: SyncEntityKey.fromJson(Map<String, Object?>.from(entity)),
    local: _headFromJson(Map<String, Object?>.from(local)),
    remote: _headFromJson(Map<String, Object?>.from(remote)),
  );
}

int _entitySort(SyncEntityKey a, SyncEntityKey b) {
  final scope = a.scope.compareTo(b.scope);
  if (scope != 0) return scope;
  final type = a.type.compareTo(b.type);
  return type != 0 ? type : a.id.compareTo(b.id);
}

class SyncSnapshotCodec {
  const SyncSnapshotCodec({
    required this.passphrase,
    this.limits = const SyncSnapshotLimits(),
  });

  final String passphrase;
  final SyncSnapshotLimits limits;

  Future<Uint8List> encode(SyncSnapshot snapshot) async {
    final codec = SyncCodec(passphrase: passphrase);
    snapshot._validate(expectedFingerprint: codec.keyFingerprint);
    final logical = snapshot.toJson();
    final plaintext = Uint8List.fromList(
      utf8.encode(canonicalSyncJson(logical)),
    );
    if (plaintext.length > limits.maxPlaintextBytes) {
      throw const SyncSnapshotException('snapshot_plaintext_too_large');
    }
    final encoded = passphrase.isEmpty
        ? plaintext
        : Uint8List.fromList(
            utf8.encode(
              canonicalSyncJson(
                await codec.encodeValue(logical, syncSnapshotProtocolVersion),
              ),
            ),
          );
    if (encoded.length > limits.maxEnvelopeBytes) {
      throw const SyncSnapshotException('snapshot_envelope_too_large');
    }
    return encoded;
  }

  Future<SyncSnapshot> decode(
    Uint8List bytes, {
    required SnapshotFileName source,
  }) async {
    if (source.isBlob || sha256.convert(bytes).toString() != source.fileHash) {
      throw const SyncSnapshotException('snapshot_file_hash_mismatch');
    }
    if (bytes.length > limits.maxEnvelopeBytes) {
      throw const SyncSnapshotException('snapshot_envelope_too_large');
    }
    if (passphrase.isEmpty && bytes.length > limits.maxPlaintextBytes) {
      throw const SyncSnapshotException('snapshot_plaintext_too_large');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map) throw const FormatException('snapshot_document');
    final document = Map<String, Object?>.from(decoded);
    final codec = SyncCodec(passphrase: passphrase);
    final logical = document.containsKey('ciphertext')
        ? await codec.decodeValue(
            document,
            expectedProtocolVersion: syncSnapshotProtocolVersion,
            maxPlaintextBytes: limits.maxPlaintextBytes,
          )
        : _decodePlaintext(document);
    if (logical is! Map) throw const FormatException('snapshot_document');
    final snapshot = SyncSnapshot.fromJson(Map<String, Object?>.from(logical));
    snapshot._validate(
      source: source,
      expectedFingerprint: codec.keyFingerprint,
    );
    return snapshot;
  }

  Object? _decodePlaintext(Map<String, Object?> document) {
    if (passphrase.isNotEmpty) {
      throw const SyncCodecException('Passphrase plaintext forbidden');
    }
    return document;
  }
}
