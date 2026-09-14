import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import '../app/sync/sync_models.dart';
import '../app/sync/sync_store.dart';

/// [SyncRepository] 的 SQLite 实现，与业务表共享同一个 [_database] 连接与写队列。
///
/// 写操作复用宿主仓储的 `_enqueue`：sqflite 本身会串行执行事务，但「先读当前
/// 状态再决定写什么」的临界区（例如 applyRemoteBatch 的已应用校验）若不排队，
/// 两个并发批次可能都基于同一份旧状态通过校验。排队后与既有 saveX 共用同一条
/// 串行链，本地记账与远端应用不会互相插队。
class SqliteSyncRepository implements SyncRepository {
  SqliteSyncRepository({
    required Database database,
    required Future<void> Function(Future<void> Function()) enqueue,
    // 私有字段不能作具名初始化形参（`this._database` 非法），沿用项目既有
    // veri_fin_controller.dart 的同一处 ignore。
    // ignore: prefer_initializing_formals
  }) : _database = database,
       // ignore: prefer_initializing_formals
       _enqueue = enqueue;

  final Database _database;
  final Future<void> Function(Future<void> Function()) _enqueue;

  /// 扫描状态单例行的主键。用固定键（而非多行）表达「每设备一份扫描进度」——
  /// 每台设备的连续序列与 gap 集合都聚合在这一行的 JSON 里。
  static const String _scanStateKey = 'singleton';

  // ---- 设备状态 ----

  @override
  Future<SyncDeviceState> loadDeviceState() async {
    final rows = await _database.query(
      'sync_device',
      orderBy: 'device_id ASC',
      limit: 1,
    );
    if (rows.isEmpty) {
      // 未曾初始化：返回空身份而不是编造一个 deviceId，让 SyncClock 决定真实身份。
      return const SyncDeviceState(
        deviceId: '',
        nextSequence: 1,
        knownVector: SyncVersionVector(<String, int>{}),
      );
    }
    final row = rows.single;
    return SyncDeviceState(
      deviceId: row['device_id'] as String,
      nextSequence: (row['next_sequence'] as int?) ?? 1,
      knownVector: SyncVersionVector.fromJson(
        _decodeObject(row['known_vector'] as String? ?? '{}'),
      ),
    );
  }

  @override
  Future<void> saveDeviceState(SyncDeviceState state) {
    return _enqueue(() async {
      // 设备身份是单例：事务内先清空再写入，避免历史多行残留导致 load 读到别的设备。
      await _database.transaction((txn) async {
        await txn.delete('sync_device');
        await txn.insert('sync_device', <String, Object?>{
          'device_id': state.deviceId,
          'next_sequence': state.nextSequence,
          'known_vector': jsonEncode(state.knownVector.toJson()),
        });
      });
    });
  }

  // ---- outbox ----

  @override
  Future<List<SyncOutboxRecord>> loadOutbox() async {
    final rows = await _database.query(
      'sync_outbox',
      where: 'uploaded = 0',
      orderBy: 'batch_id ASC, operation_id ASC',
    );
    return <SyncOutboxRecord>[
      for (final row in rows)
        SyncOutboxRecord(
          batchId: row['batch_id'] as String,
          operationId: row['operation_id'] as String,
          relativePath: row['relative_path'] as String,
          payloadHash: row['payload_hash'] as String,
          retryCount: (row['retry_count'] as int?) ?? 0,
        ),
    ];
  }

  @override
  Future<void> enqueueBatch(SyncBatchRecord batch) {
    return _enqueue(() async {
      await _database.transaction((txn) async {
        final statement = txn.batch();
        for (final event in batch.events) {
          statement.insert('sync_outbox', <String, Object?>{
            'batch_id': batch.batchId,
            'operation_id': event.operationId,
            'relative_path': _relativePathFor(event),
            'payload_hash': event.payloadHash,
            'retry_count': 0,
            'uploaded': 0,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await statement.commit(noResult: true);
      });
    });
  }

  /// 事件在同步目录下的相对路径：`events/<deviceId>/<sequence>-<operationId>.vfsync`，
  /// 与协议文档的远端布局一致。序列取本地 dot 的 sequence（0 补零到 20 位，
  /// 让目录按字典序即按序列序排列）。
  static String _relativePathFor(SyncEvent event) {
    final sequence = event.version.dot.sequence.toString().padLeft(20, '0');
    return 'events/${event.version.dot.deviceId}/'
        '$sequence-${event.operationId}.vfsync';
  }

  @override
  Future<void> markBatchUploaded(String batchId) {
    return _enqueue(() async {
      await _database.update(
        'sync_outbox',
        <String, Object?>{'uploaded': 1},
        where: 'batch_id = ?',
        whereArgs: <Object?>[batchId],
      );
    });
  }

  // ---- 远端批次应用 ----

  /// 校验与写入在同一事务内完成。
  ///
  /// 事务内先读「已应用 hash」与该批涉及实体的当前版本，交给共享的
  /// [SyncPlanValidator] 判定；任何一条不满足即抛 [SyncConflictException]，
  /// 事务回滚、零副作用。校验通过后依次写 sync_entity_versions（含冲突两侧的历史行，
  /// 不覆盖既有版本）、sync_apply_journal、sync_shadow、sync_applied_ops。
  ///
  /// 业务表写入不在本任务范围：Task 5 会把实体变更路由到对应业务表，届时仍在本
  /// 事务内追加，保持「远端账目与同步元数据同一次提交」的承诺。
  @override
  Future<void> applyRemoteBatch(RemoteApplyPlan plan) {
    return _enqueue(() async {
      await _database.transaction((txn) async {
        final operationIds = plan.appliedOperationIds;
        final appliedHashes = await _loadAppliedHashes(txn, operationIds);
        final knownVersions = await _loadKnownVersions(
          txn,
          plan.entityVersions.map((version) => version.entity).toSet(),
        );

        SyncPlanValidator.validate(
          plan: plan,
          appliedHashes: appliedHashes,
          knownVersions: knownVersions,
        );

        final appliedAt = DateTime.now().millisecondsSinceEpoch;

        // 实体版本：按 operation_id 插入，已存在则忽略——同一操作重放不应改写
        // 既有版本行（历史版本要留给冲突决议审计）。
        final versionStatement = txn.batch();
        for (final version in plan.entityVersions) {
          versionStatement.insert('sync_entity_versions', <String, Object?>{
            'operation_id': version.operationId,
            'scope': version.entity.scope,
            'type': version.entity.type,
            'id': version.entity.id,
            'version_json': jsonEncode(version.version.toJson()),
            'payload_hash': version.payloadHash,
            'payload_envelope': version.payload == null
                ? null
                : jsonEncode(version.payload),
            'deleted': version.deleted ? 1 : 0,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        await versionStatement.commit(noResult: true);

        // KV journal：偏好写不进 SQLite 事务，先落盘待应用值，由上层按批次刷盘后
        // 标记 applied。重放是幂等的（按目标值覆盖）。
        final journalStatement = txn.batch();
        for (final entry in plan.kvJournalValues.entries) {
          journalStatement.insert('sync_apply_journal', <String, Object?>{
            'batch_id': plan.batchId,
            'kv_key': entry.key,
            'kv_value': entry.value,
            'target_hash': computeSyncPayloadHash(entry.value),
            'applied': 0,
          });
        }
        await journalStatement.commit(noResult: true);

        // shadow：把远端结果记成「已知投影」，否则下一次本地投影比较会把刚应用的
        // 远端变更误判成本地新变更、再上传一遍。
        final shadowStatement = txn.batch();
        for (final row in shadowRowsOf(plan)) {
          shadowStatement.insert('sync_shadow', <String, Object?>{
            'scope': row.key.scope,
            'type': row.key.type,
            'id': row.key.id,
            'payload_hash': row.payloadHash,
            'version_json': jsonEncode(
              _versionOf(plan, row.key)?.toJson() ?? const <String, Object?>{},
            ),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await shadowStatement.commit(noResult: true);

        // 最后登记已应用：这是去重的唯一依据，必须与本批其他写入同事务可见。
        final appliedStatement = txn.batch();
        for (final operationId in plan.appliedOperationIds) {
          appliedStatement.insert('sync_applied_ops', <String, Object?>{
            'operation_id': operationId,
            'batch_id': plan.batchId,
            'payload_hash': plan.payloadHashForOperation(operationId),
            'applied_at': appliedAt,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        await appliedStatement.commit(noResult: true);
      });
    });
  }

  /// 计划中该实体对应的版本（用于给 shadow 行记下版本上下文）。
  static SyncVersion? _versionOf(RemoteApplyPlan plan, SyncEntityKey key) {
    for (final version in plan.entityVersions) {
      if (version.entity == key) {
        return version.version;
      }
    }
    return null;
  }

  /// 读「已应用」hash。数据源必须是 sync_applied_ops——这是协议里「已应用」的
  /// 唯一真相；sync_entity_versions 只保存实体版本历史，不含只写 KV / 决议这类
  /// 没有实体行的操作，从那里查会漏判、让重复应用以不同 hash 悄悄通过。
  ///
  /// 查询范围取 [RemoteApplyPlan.appliedOperationIds]（而非本批的实体版本），
  /// 因为「已应用」的判定必须覆盖计划声称的每一个操作。
  static Future<Map<String, String>> _loadAppliedHashes(
    Transaction txn,
    List<String> operationIds,
  ) async {
    if (operationIds.isEmpty) {
      return <String, String>{};
    }
    final placeholders = List<String>.filled(
      operationIds.length,
      '?',
    ).join(',');
    final rows = await txn.rawQuery(
      'SELECT operation_id, payload_hash FROM sync_applied_ops '
      'WHERE operation_id IN ($placeholders)',
      operationIds.toList(growable: false),
    );
    return <String, String>{
      for (final row in rows)
        row['operation_id'] as String: (row['payload_hash'] as String?) ?? '',
    };
  }

  /// 该批实体的「当前版本」：取已落库版本中逻辑时间最大的一行。
  /// 冲突两侧都留在表里，因此必须挑最新的一版作为因果比较基准，
  /// 否则会被更早的历史版本误判成回退。
  static Future<Map<SyncEntityKey, KnownSyncEntityVersion>> _loadKnownVersions(
    Transaction txn,
    Set<SyncEntityKey> keys,
  ) async {
    final result = <SyncEntityKey, KnownSyncEntityVersion>{};
    for (final key in keys) {
      final rows = await txn.query(
        'sync_entity_versions',
        where: 'scope = ? AND type = ? AND id = ?',
        whereArgs: <Object?>[key.scope, key.type, key.id],
      );
      KnownSyncEntityVersion? latest;
      var latestLogicalTime = -1;
      for (final row in rows) {
        final version = SyncVersion.fromJson(
          _decodeObject(row['version_json'] as String),
        );
        if (version.logicalTime >= latestLogicalTime) {
          latestLogicalTime = version.logicalTime;
          latest = KnownSyncEntityVersion(
            entity: key,
            operationId: row['operation_id'] as String,
            version: version,
            deleted: ((row['deleted'] as int?) ?? 0) != 0,
          );
        }
      }
      if (latest != null) {
        result[key] = latest;
      }
    }
    return result;
  }

  // ---- shadow ----

  /// 读取当前投影快照的 hash 表。行数随实体数增长（账目、账户各占一行），
  /// 但每行只有两个短字符串，比保存完整 payload 的旧列表轻得多。
  @override
  Future<Map<SyncEntityKey, String>> loadShadow() async {
    final rows = await _database.query(
      'sync_shadow',
      columns: <String>['scope', 'type', 'id', 'payload_hash'],
    );
    return <SyncEntityKey, String>{
      for (final row in rows)
        SyncEntityKey(
          scope: row['scope'] as String,
          type: row['type'] as String,
          id: row['id'] as String,
        ): row['payload_hash'] as String,
    };
  }

  /// 整体替换 shadow。先清空再写入，且在同一事务内完成：既避免旧实体行残留
  /// 导致删除被反复重放，也避免并发读看到半份 shadow 而误判本地变更。
  @override
  Future<void> saveShadow(Map<SyncEntityKey, String> shadow) {
    return _enqueue(() async {
      await _database.transaction((txn) async {
        await txn.delete('sync_shadow');
        final statement = txn.batch();
        for (final entry in shadow.entries) {
          statement.insert('sync_shadow', <String, Object?>{
            'scope': entry.key.scope,
            'type': entry.key.type,
            'id': entry.key.id,
            'payload_hash': entry.value,
            // 本地投影的 shadow 行没有远端版本上下文，写入空对象而不是编造一个
            // 版本：伪造的 dot 会让后续因果比较误判为「已有版本」。
            'version_json': '{}',
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        await statement.commit(noResult: true);
      });
    });
  }

  // ---- 扫描状态 ----

  @override
  Future<SyncScanState> loadScanState() async {
    final rows = await _database.query(
      'sync_scan_state',
      where: 'key = ?',
      whereArgs: const <Object?>[_scanStateKey],
      limit: 1,
    );
    if (rows.isEmpty) {
      return const SyncScanState(
        contiguousSequences: <String, int>{},
        gaps: <String, List<int>>{},
        lastSuccess: null,
        lastErrorCode: null,
        retryCount: 0,
      );
    }
    final row = rows.single;
    return SyncScanState(
      contiguousSequences: _decodeIntMap(row['contiguous_sequences_json']),
      gaps: _decodeGapMap(row['gaps_json']),
      lastSuccess: row['last_success_ms'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(row['last_success_ms'] as int),
      lastErrorCode: row['last_error_code'] as String?,
      retryCount: (row['retry_count'] as int?) ?? 0,
    );
  }

  @override
  Future<void> saveScanState(SyncScanState state) {
    return _enqueue(() async {
      await _database.insert('sync_scan_state', <String, Object?>{
        'key': _scanStateKey,
        'contiguous_sequences_json': jsonEncode(state.contiguousSequences),
        'gaps_json': jsonEncode(
          state.gaps.map(
            (deviceId, sequences) =>
                MapEntry<String, Object?>(deviceId, sequences),
          ),
        ),
        'last_success_ms': state.lastSuccess?.millisecondsSinceEpoch,
        'last_error_code': state.lastErrorCode,
        'retry_count': state.retryCount,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  // ---- 冲突 ----

  @override
  Future<void> storeConflict(SyncConflictRecord conflict) {
    return _enqueue(() async {
      await _database.transaction((txn) async {
        // Insert both version rows first (ignore if already present).
        for (final version in [conflict.local, conflict.remote]) {
          await txn.insert('sync_entity_versions', <String, Object?>{
            'operation_id': version.operationId,
            'scope': version.entity.scope,
            'type': version.entity.type,
            'id': version.entity.id,
            'version_json': jsonEncode(version.version.toJson()),
            'payload_hash': version.payloadHash,
            'payload_envelope': version.payload == null
                ? null
                : jsonEncode(version.payload),
            'deleted': version.deleted ? 1 : 0,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        // Then insert the conflict record.
        await txn.insert('sync_conflicts', <String, Object?>{
          'id': conflict.id,
          'scope': conflict.entity.scope,
          'type': conflict.entity.type,
          'entity_id': conflict.entity.id,
          'local_operation_id': conflict.local.operationId,
          'remote_operation_id': conflict.remote.operationId,
          'created_at': DateTime.now().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      });
    });
  }

  @override
  Future<void> removeConflict(String conflictId) {
    return _enqueue(() async {
      await _database.delete(
        'sync_conflicts',
        where: 'id = ?',
        whereArgs: <Object?>[conflictId],
      );
    });
  }

  @override
  Future<List<SyncConflictRecord>> loadConflicts() async {
    final rows = await _database.query(
      'sync_conflicts',
      orderBy: 'created_at ASC, id ASC',
    );
    final conflicts = <SyncConflictRecord>[];
    for (final row in rows) {
      final local = await _loadEntityVersion(
        row['local_operation_id'] as String,
      );
      final remote = await _loadEntityVersion(
        row['remote_operation_id'] as String,
      );
      // 两侧版本行必须存在（建表即有外键引用）。缺失说明库被外部改写，
      // 与其返回一条字段残缺的冲突记录，不如直接暴露出来。
      if (local == null || remote == null) {
        throw StateError(
          '冲突 ${row['id']} 引用了不存在的实体版本行：'
          'local=${row['local_operation_id']} remote=${row['remote_operation_id']}',
        );
      }
      conflicts.add(
        SyncConflictRecord(
          id: row['id'] as String,
          entity: SyncEntityKey(
            scope: row['scope'] as String,
            type: row['type'] as String,
            id: row['entity_id'] as String,
          ),
          local: local,
          remote: remote,
        ),
      );
    }
    return conflicts;
  }

  Future<SyncEntityVersion?> _loadEntityVersion(String operationId) async {
    final rows = await _database.query(
      'sync_entity_versions',
      where: 'operation_id = ?',
      whereArgs: <Object?>[operationId],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    final row = rows.single;
    return SyncEntityVersion(
      entity: SyncEntityKey(
        scope: row['scope'] as String,
        type: row['type'] as String,
        id: row['id'] as String,
      ),
      version: SyncVersion.fromJson(
        _decodeObject(row['version_json'] as String),
      ),
      payloadHash: row['payload_hash'] as String,
      payload: row['payload_envelope'] == null
          ? null
          : jsonDecode(row['payload_envelope'] as String),
      deleted: ((row['deleted'] as int?) ?? 0) != 0,
      operationId: row['operation_id'] as String,
    );
  }

  // ---- KV journal 重放 ----

  /// 按 id 升序返回，使同一批内先写入的行在调用方按 key 排序前仍有稳定的
  /// 次序基准（排序不稳定时至少不引入额外的不确定性）。
  @override
  Future<List<KvJournalEntry>> loadPendingKvJournal() async {
    final rows = await _database.query(
      'sync_apply_journal',
      where: 'applied = 0',
      orderBy: 'id ASC',
    );
    return <KvJournalEntry>[
      for (final row in rows)
        KvJournalEntry(
          id: row['id'] as int,
          batchId: row['batch_id'] as String,
          key: row['kv_key'] as String,
          value: row['kv_value'] as String,
          targetHash: row['target_hash'] as String,
        ),
    ];
  }

  @override
  Future<void> markKvJournalApplied(int id) {
    return _enqueue(() async {
      await _database.update(
        'sync_apply_journal',
        <String, Object?>{'applied': 1},
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
    });
  }

  // ---- JSON 解码 ----

  static Map<String, Object?> _decodeObject(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw FormatException('Expected a JSON object, got: $raw');
    }
    return decoded.cast<String, Object?>();
  }

  static Map<String, int> _decodeIntMap(Object? raw) {
    if (raw is! String || raw.isEmpty) {
      return <String, int>{};
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return <String, int>{};
    }
    return <String, int>{
      for (final entry in decoded.entries)
        entry.key.toString(): (entry.value as num).toInt(),
    };
  }

  static Map<String, List<int>> _decodeGapMap(Object? raw) {
    if (raw is! String || raw.isEmpty) {
      return <String, List<int>>{};
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      return <String, List<int>>{};
    }
    return <String, List<int>>{
      for (final entry in decoded.entries)
        entry.key.toString(): <int>[
          for (final value in (entry.value as List)) (value as num).toInt(),
        ],
    };
  }
}
