import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Causality relationship between two version vectors.
enum SyncCausality { before, after, equal, concurrent }

/// 协议版本。写入每个事件的 `protocolVersion`，远端据此判定兼容性。
///
/// 单点定义：事件构造方（变更捕获、冲突决议、首次基线）都引用这里，
/// 避免各处硬编码出「同一协议、不同版本号」的文件。
const String syncProtocolVersion = '1';

/// A single logical timestamp: (deviceId, sequence).
class SyncDot {
  const SyncDot({required this.deviceId, required this.sequence});

  final String deviceId;
  final int sequence;

  Map<String, Object?> toJson() => {'deviceId': deviceId, 'sequence': sequence};

  static SyncDot fromJson(Map<String, Object?> json) {
    final deviceId = json['deviceId'] as String?;
    final sequence = (json['sequence'] as num?)?.toInt();
    if (deviceId == null || deviceId.isEmpty) {
      throw FormatException('SyncDot.deviceId must be non-empty');
    }
    if (sequence == null || sequence < 0) {
      throw FormatException('SyncDot.sequence must be non-negative');
    }
    return SyncDot(deviceId: deviceId, sequence: sequence);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncDot &&
          deviceId == other.deviceId &&
          sequence == other.sequence;

  @override
  int get hashCode => Object.hash(deviceId, sequence);

  @override
  String toString() => 'SyncDot($deviceId:$sequence)';
}

/// Version vector: maps deviceId → max known sequence.
class SyncVersionVector {
  const SyncVersionVector(this.values);

  final Map<String, int> values;

  /// Compare this vector to another, treating missing keys as 0.
  SyncCausality compare(SyncVersionVector other) {
    final allKeys = <String>{...values.keys, ...other.values.keys};
    bool thisGreater = false;
    bool otherGreater = false;

    for (final key in allKeys) {
      final thisVal = values[key] ?? 0;
      final otherVal = other.values[key] ?? 0;
      if (thisVal > otherVal) {
        thisGreater = true;
      } else if (otherVal > thisVal) {
        otherGreater = true;
      }
    }

    if (thisGreater && otherGreater) return SyncCausality.concurrent;
    if (thisGreater) return SyncCausality.after;
    if (otherGreater) return SyncCausality.before;
    return SyncCausality.equal;
  }

  /// Merge two vectors, taking the max of each device.
  SyncVersionVector merged(SyncVersionVector other) {
    final result = <String, int>{...values};
    for (final entry in other.values.entries) {
      final current = result[entry.key] ?? 0;
      result[entry.key] = current > entry.value ? current : entry.value;
    }
    return SyncVersionVector(result);
  }

  Map<String, Object?> toJson() => Map<String, Object?>.from(values);

  static SyncVersionVector fromJson(Map<String, Object?> json) {
    final result = <String, int>{};
    for (final entry in json.entries) {
      final deviceId = entry.key;
      final sequence = (entry.value as num?)?.toInt();
      if (deviceId.isEmpty) {
        throw FormatException('SyncVersionVector deviceId must be non-empty');
      }
      if (sequence == null || sequence < 0) {
        throw FormatException(
          'SyncVersionVector sequence must be non-negative',
        );
      }
      result[deviceId] = sequence;
    }
    return SyncVersionVector(result);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncVersionVector && _mapsEqual(values, other.values);

  @override
  int get hashCode {
    final sorted = values.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return Object.hashAll(sorted.map((e) => Object.hash(e.key, e.value)));
  }

  @override
  String toString() => 'SyncVersionVector($values)';

  static bool _mapsEqual(Map<String, int> a, Map<String, int> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}

/// Full version metadata: dot + causal context + logical time.
class SyncVersion {
  const SyncVersion({
    required this.dot,
    required this.context,
    required this.logicalTime,
  });

  final SyncDot dot;
  final SyncVersionVector context;
  final int logicalTime;

  Map<String, Object?> toJson() => {
    'dot': dot.toJson(),
    'context': context.toJson(),
    'logicalTime': logicalTime,
  };

  static SyncVersion fromJson(Map<String, Object?> json) {
    final dotJson = json['dot'] as Map<String, Object?>?;
    final contextJson = json['context'] as Map<String, Object?>?;
    final logicalTime = (json['logicalTime'] as num?)?.toInt();
    if (dotJson == null) {
      throw FormatException('SyncVersion.dot is required');
    }
    if (contextJson == null) {
      throw FormatException('SyncVersion.context is required');
    }
    if (logicalTime == null) {
      throw FormatException('SyncVersion.logicalTime is required');
    }
    return SyncVersion(
      dot: SyncDot.fromJson(dotJson),
      context: SyncVersionVector.fromJson(contextJson),
      logicalTime: logicalTime,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncVersion &&
          dot == other.dot &&
          context == other.context &&
          logicalTime == other.logicalTime;

  @override
  int get hashCode => Object.hash(dot, context, logicalTime);

  @override
  String toString() =>
      'SyncVersion(dot: $dot, context: $context, logicalTime: $logicalTime)';
}

/// Entity key: (scope, type, id).
class SyncEntityKey {
  const SyncEntityKey({
    required this.scope,
    required this.type,
    required this.id,
  });

  final String scope;
  final String type;
  final String id;

  Map<String, Object?> toJson() => {'scope': scope, 'type': type, 'id': id};

  static SyncEntityKey fromJson(Map<String, Object?> json) {
    final scope = json['scope'] as String?;
    final type = json['type'] as String?;
    final id = json['id'] as String?;
    if (scope == null || scope.isEmpty) {
      throw FormatException('SyncEntityKey.scope must be non-empty');
    }
    if (type == null || type.isEmpty) {
      throw FormatException('SyncEntityKey.type must be non-empty');
    }
    if (id == null || id.isEmpty) {
      throw FormatException('SyncEntityKey.id must be non-empty');
    }
    return SyncEntityKey(scope: scope, type: type, id: id);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncEntityKey &&
          scope == other.scope &&
          type == other.type &&
          id == other.id;

  @override
  int get hashCode => Object.hash(scope, type, id);

  @override
  String toString() => 'SyncEntityKey($scope/$type/$id)';
}

/// Operation kind.
enum SyncOperationKind {
  upsert,
  delete,
  resolve;

  String toJson() {
    switch (this) {
      case SyncOperationKind.upsert:
        return 'upsert';
      case SyncOperationKind.delete:
        return 'delete';
      case SyncOperationKind.resolve:
        return 'resolve';
    }
  }

  static SyncOperationKind fromJson(String value) {
    switch (value) {
      case 'upsert':
        return SyncOperationKind.upsert;
      case 'delete':
        return SyncOperationKind.delete;
      case 'resolve':
        return SyncOperationKind.resolve;
      default:
        throw FormatException('Unknown SyncOperationKind: $value');
    }
  }
}

/// Compute SHA-256 hash of canonical JSON payload.
String computeSyncPayloadHash(Object? payload) {
  final canonical = _canonicalJson(payload);
  final bytes = utf8.encode(canonical);
  final digest = sha256.convert(bytes);
  return digest.toString();
}

/// Produce canonical JSON (sorted keys, no whitespace).
String _canonicalJson(Object? value) {
  if (value == null) {
    return 'null';
  } else if (value is bool) {
    return value.toString();
  } else if (value is num) {
    if (!value.isFinite) {
      throw FormatException('Non-finite number in payload: $value');
    }
    return value.toString();
  } else if (value is String) {
    return jsonEncode(value);
  } else if (value is List) {
    final items = value.cast<Object?>().map(_canonicalJson).join(',');
    return '[$items]';
  } else if (value is Map) {
    final map = value.cast<Object?, Object?>();
    final keys = map.keys.cast<String>().toList()..sort();
    final pairs = keys
        .map((k) {
          final v = map[k];
          return '${jsonEncode(k)}:${_canonicalJson(v)}';
        })
        .join(',');
    return '{$pairs}';
  } else {
    throw FormatException('Unsupported payload type: ${value.runtimeType}');
  }
}

/// Sync event: immutable, JSON-serializable, validates on deserialization.
class SyncEvent {
  const SyncEvent({
    required this.protocolVersion,
    required this.operationId,
    required this.version,
    required this.entity,
    required this.operation,
    required this.payloadHash,
    required this.payload,
    required this.batchId,
    required this.keyFingerprint,
  });

  final String protocolVersion;
  final String operationId;
  final SyncVersion version;
  final SyncEntityKey entity;
  final SyncOperationKind operation;
  final String payloadHash;
  final Object? payload;
  final String batchId;
  final String keyFingerprint;

  Map<String, Object?> toJson() => {
    'protocolVersion': protocolVersion,
    'operationId': operationId,
    'version': version.toJson(),
    'entity': entity.toJson(),
    'operation': operation.toJson(),
    'payloadHash': payloadHash,
    'payload': payload,
    'batchId': batchId,
    'keyFingerprint': keyFingerprint,
  };

  static SyncEvent fromJson(Map<String, Object?> json) {
    final protocolVersion = json['protocolVersion'] as String?;
    final operationId = json['operationId'] as String?;
    final versionJson = json['version'] as Map<String, Object?>?;
    final entityJson = json['entity'] as Map<String, Object?>?;
    final operationStr = json['operation'] as String?;
    final payloadHash = json['payloadHash'] as String?;
    final payload = json['payload'];
    final batchId = json['batchId'] as String?;
    final keyFingerprint = json['keyFingerprint'] as String?;

    if (protocolVersion == null || protocolVersion.isEmpty) {
      throw FormatException('SyncEvent.protocolVersion is required');
    }
    if (operationId == null || operationId.isEmpty) {
      throw FormatException('SyncEvent.operationId must be non-empty');
    }
    if (versionJson == null) {
      throw FormatException('SyncEvent.version is required');
    }
    if (entityJson == null) {
      throw FormatException('SyncEvent.entity is required');
    }
    if (operationStr == null) {
      throw FormatException('SyncEvent.operation is required');
    }
    if (payloadHash == null || payloadHash.isEmpty) {
      throw FormatException('SyncEvent.payloadHash is required');
    }
    if (batchId == null || batchId.isEmpty) {
      throw FormatException('SyncEvent.batchId must be non-empty');
    }
    if (keyFingerprint == null) {
      throw FormatException('SyncEvent.keyFingerprint is required');
    }

    final version = SyncVersion.fromJson(versionJson);
    final entity = SyncEntityKey.fromJson(entityJson);
    final operation = SyncOperationKind.fromJson(operationStr);

    // Validate payload hash.
    final computedHash = computeSyncPayloadHash(payload);
    if (computedHash != payloadHash) {
      throw FormatException(
        'SyncEvent.payloadHash mismatch: expected $payloadHash, got $computedHash',
      );
    }

    return SyncEvent(
      protocolVersion: protocolVersion,
      operationId: operationId,
      version: version,
      entity: entity,
      operation: operation,
      payloadHash: payloadHash,
      payload: payload,
      batchId: batchId,
      keyFingerprint: keyFingerprint,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncEvent &&
          protocolVersion == other.protocolVersion &&
          operationId == other.operationId &&
          version == other.version &&
          entity == other.entity &&
          operation == other.operation &&
          payloadHash == other.payloadHash &&
          batchId == other.batchId &&
          keyFingerprint == other.keyFingerprint &&
          _payloadEquals(payload, other.payload);

  @override
  int get hashCode => Object.hash(
    protocolVersion,
    operationId,
    version,
    entity,
    operation,
    payloadHash,
    batchId,
    keyFingerprint,
  );

  @override
  String toString() =>
      'SyncEvent(op: $operationId, entity: $entity, operation: $operation)';

  static bool _payloadEquals(Object? a, Object? b) {
    if (identical(a, b)) return true;
    if (a == null || b == null) return a == b;
    if (a is List && b is List) {
      final al = a.cast<Object?>();
      final bl = b.cast<Object?>();
      if (al.length != bl.length) return false;
      for (var i = 0; i < al.length; i++) {
        if (!_payloadEquals(al[i], bl[i])) return false;
      }
      return true;
    }
    if (a is Map && b is Map) {
      final am = a.cast<Object?, Object?>();
      final bm = b.cast<Object?, Object?>();
      if (am.length != bm.length) return false;
      for (final key in am.keys) {
        if (!bm.containsKey(key)) return false;
        if (!_payloadEquals(am[key], bm[key])) return false;
      }
      return true;
    }
    return a == b;
  }
}

/// Entity version with payload.
class SyncEntityVersion {
  const SyncEntityVersion({
    required this.entity,
    required this.version,
    required this.payloadHash,
    required this.payload,
    required this.deleted,
    required this.operationId,
  });

  /// 版本所属实体。持久化层按 (scope, type, id) 建行，缺失它就无法把版本
  /// 写进 sync_entity_versions/sync_shadow。
  final SyncEntityKey entity;

  final SyncVersion version;
  final String payloadHash;
  final Object? payload;
  final bool deleted;
  final String operationId;
}

/// Batch manifest.
class SyncBatchManifest {
  const SyncBatchManifest({
    required this.batchId,
    required this.operationIds,
    required this.blobHashes,
    required this.manifestHash,
  });

  final String batchId;
  final List<String> operationIds;
  final List<String> blobHashes;
  final String manifestHash;
}

/// Projected entity (current state).
class SyncProjectedEntity {
  const SyncProjectedEntity({
    required this.key,
    required this.payload,
    required this.payloadHash,
  });

  final SyncEntityKey key;
  final Object? payload;
  final String payloadHash;
}

/// Local mutation (not yet versioned).
class SyncLocalMutation {
  const SyncLocalMutation({
    required this.entity,
    required this.operation,
    required this.payload,
    required this.batchId,
  });

  final SyncEntityKey entity;
  final SyncOperationKind operation;
  final Object? payload;
  final String batchId;
}

/// Device state (clock state).
class SyncDeviceState {
  const SyncDeviceState({
    required this.deviceId,
    required this.nextSequence,
    required this.knownVector,
  });

  final String deviceId;
  final int nextSequence;
  final SyncVersionVector knownVector;
}

/// Outbox record.
class SyncOutboxRecord {
  const SyncOutboxRecord({
    required this.batchId,
    required this.operationId,
    required this.relativePath,
    required this.payloadHash,
    required this.retryCount,
    required this.event,
  });

  final String batchId;
  final String operationId;
  final String relativePath;
  final String payloadHash;
  final int retryCount;

  /// 待上传的完整事件。v18 起新入队记录始终非空；从 v17 升级的
  /// 历史行没有可恢复的正文，保留为 null，由上传层报明确错误并保留记录。
  final SyncEvent? event;
}

/// Batch record.
class SyncBatchRecord {
  const SyncBatchRecord({
    required this.batchId,
    required this.events,
    required this.manifest,
  });

  final String batchId;
  final List<SyncEvent> events;
  final SyncBatchManifest manifest;
}

/// Scan state.
class SyncScanState {
  const SyncScanState({
    required this.contiguousSequences,
    required this.gaps,
    required this.lastSuccess,
    required this.lastErrorCode,
    required this.retryCount,
  });

  final Map<String, int> contiguousSequences;
  final Map<String, List<int>> gaps;
  final DateTime? lastSuccess;
  final String? lastErrorCode;
  final int retryCount;
}

/// Conflict record.
class SyncConflictRecord {
  const SyncConflictRecord({
    required this.id,
    required this.entity,
    required this.local,
    required this.remote,
  });

  final String id;
  final SyncEntityKey entity;
  final SyncEntityVersion local;
  final SyncEntityVersion remote;
}

/// Remote apply plan.
class RemoteApplyPlan {
  const RemoteApplyPlan({
    required this.batchId,
    required this.entityVersions,
    required this.appliedOperationIds,
    required this.shadowHashes,
    required this.kvJournalValues,
    this.appliedPayloadHashes = const <String, String>{},
    this.conflicts = const <SyncConflictRecord>[],
    this.resolutionEvents = const <SyncEvent>[],
    this.resolvedConflictIds = const <String>[],
    this.completedPendingIds = const <String>[],
    this.kvExpectedHashes = const <String, String>{},
  });

  final String batchId;
  final List<SyncEntityVersion> entityVersions;

  /// 本批标记为「已应用」的 operationId。允许包含没有实体版本的操作
  /// （只写 KV 的批次、决议事件等），因此它的 hash 不能靠 [entityVersions] 反查。
  final List<String> appliedOperationIds;

  /// 实体键 → 规范化 payload hash。键的编码为 `"scope|type|id"`（竖线分隔），
  /// 生成与解析统一走 `sync_store.dart` 的 `encodeSyncEntityKey` /
  /// `decodeSyncEntityKey`，调用方不要自行拼接。参与编码的三段取值不得含 `|`。
  final Map<String, String> shadowHashes;

  final Map<String, String> kvJournalValues;

  /// operationId → payload hash，供 `sync_applied_ops` 落库。
  ///
  /// 「已应用」判定的唯一依据是 `sync_applied_ops`，而 [appliedOperationIds] 可能
  /// 含有不在 [entityVersions] 里的操作——那种操作没有任何实体版本行可以反查 hash。
  /// 因此计划必须自带每个已应用操作的 hash，而不是让持久化层去猜。
  /// 缺省为空表，此时按 [entityVersions] 里的 hash 兜底（见持久化实现）。
  final Map<String, String> appliedPayloadHashes;

  /// 本批产生的冲突记录，落库到 sync_conflicts。
  final List<SyncConflictRecord> conflicts;
  final List<SyncEvent> resolutionEvents;
  final List<String> resolvedConflictIds;
  final List<String> completedPendingIds;
  final Map<String, String> kvExpectedHashes;

  /// 某个已应用操作的 payload hash：优先取 [appliedPayloadHashes]，
  /// 缺失时回落到 [entityVersions]；两者都没有则返回空串。
  ///
  /// 两个实现共用本方法，保证「同一批次在内存与 SQLite 得到同一结论」。
  String payloadHashForOperation(String operationId) {
    final explicit = appliedPayloadHashes[operationId];
    if (explicit != null) {
      return explicit;
    }
    for (final version in entityVersions) {
      if (version.operationId == operationId) {
        return version.payloadHash;
      }
    }
    return '';
  }
}
