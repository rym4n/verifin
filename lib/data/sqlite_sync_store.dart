import 'dart:async';
import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';

import '../app/sync/sync_models.dart';
import '../app/sync/sync_store.dart';
import '../app/sync/sync_plan_codec.dart';
import '../app/sync/sync_snapshot.dart';

/// [SyncRepository] 的 SQLite 实现，与业务表共享同一个 [_database] 连接与写队列。
///
/// 写操作复用宿主仓储的 `_enqueue`：sqflite 本身会串行执行事务，但「先读当前
/// 状态再决定写什么」的临界区（例如 applyRemoteBatch 的已应用校验）若不排队，
/// 两个并发批次可能都基于同一份旧状态通过校验。排队后与既有 saveX 共用同一条
/// 串行链，本地记账与远端应用不会互相插队。
class SqliteSyncRepository implements SyncRepository {
  static const _enrollmentId = '__sync_enrollment__';
  @override
  Future<String?> loadEnrollmentState() async {
    final rows = await _database.query(
      'sync_pending',
      columns: ['reason'],
      where: 'batch_id = ?',
      whereArgs: [_enrollmentId],
    );
    return rows.firstOrNull?['reason'] as String?;
  }

  @override
  Future<void> saveEnrollmentState(String state) =>
      savePendingBatch(_enrollmentId, const [], state);
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
          event: _decodeOutboxEvent(row['event_json'] as String?),
        ),
    ];
  }

  @override
  Future<void> enqueueBatch(SyncBatchRecord batch) {
    return _enqueue(() async {
      await _database.transaction((txn) async {
        final statement = txn.batch();
        for (final event in batch.events) {
          await _writeVersion(
            txn,
            SyncEntityVersion(
              entity: event.entity,
              version: event.version,
              payloadHash: event.payloadHash,
              payload: event.payload,
              deleted: event.operation == SyncOperationKind.delete,
              operationId: event.operationId,
            ),
            head: true,
          );
          statement.insert('sync_outbox', <String, Object?>{
            'batch_id': batch.batchId,
            'operation_id': event.operationId,
            'relative_path': _relativePathFor(event),
            'payload_hash': event.payloadHash,
            'event_json': jsonEncode(event.toJson()),
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

  static SyncEvent? _decodeOutboxEvent(String? encoded) {
    if (encoded == null) {
      return null;
    }
    final decoded = jsonDecode(encoded);
    if (decoded is! Map) {
      throw const FormatException('sync_outbox.event_json must be an object');
    }
    return SyncEvent.fromJson(decoded.cast<String, Object?>());
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

  static const String _snapshotStateKey = 'singleton';

  @override
  Future<SyncSnapshotState> loadSnapshotState() async {
    final rows = await _database.query(
      'sync_snapshot_state',
      where: 'key = ?',
      whereArgs: [_snapshotStateKey],
    );
    if (rows.isEmpty) return const SyncSnapshotState();
    return _snapshotStateFromRow(rows.single);
  }

  @override
  Future<PreparedSyncSnapshot> prepareSnapshotPublication() {
    final completer = Completer<PreparedSyncSnapshot>();
    _enqueue(() async {
      late PreparedSyncSnapshot prepared;
      await _database.transaction((txn) async {
        final stateRows = await txn.query(
          'sync_snapshot_state',
          where: 'key = ?',
          whereArgs: [_snapshotStateKey],
        );
        final state = stateRows.isEmpty
            ? const SyncSnapshotState()
            : _snapshotStateFromRow(stateRows.single);
        final sequence = state.nextSnapshotSequence;
        await txn.insert('sync_snapshot_state', {
          'key': _snapshotStateKey,
          'next_snapshot_sequence': sequence + 1,
          'last_published_sequence': state.lastPublishedSequence,
          'last_published_hash': state.lastPublishedHash,
          'last_published_at': state.lastPublishedAt?.millisecondsSinceEpoch,
          'v1_import_completed': state.v1ImportCompleted ? 1 : 0,
          'v1_migration_state': _migrationStateValue(state.v1MigrationState),
          'v1_last_seen_fingerprint': state.v1LastSeenFingerprint,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        await txn.insert('sync_snapshot_publications', {
          'snapshot_sequence': sequence,
          'state': 'prepared',
        });
        final headRows = await txn.rawQuery(
          'SELECT v.* FROM sync_entity_versions v '
          'JOIN sync_entity_heads h ON h.operation_id = v.operation_id '
          'ORDER BY v.scope, v.type, v.id',
        );
        final heads = headRows.map(_versionFromRow).toList();
        final outboxRows = await txn.query(
          'sync_outbox',
          where: 'uploaded = 0',
          orderBy: 'batch_id ASC, operation_id ASC',
        );
        final members = <SyncOutboxRecord>[
          for (final row in outboxRows) _outboxFromRow(row),
        ];
        final conflictRows = await txn.query(
          'sync_conflicts',
          orderBy: 'created_at ASC, id ASC',
        );
        final conflicts = <SyncConflictRecord>[];
        for (final row in conflictRows) {
          final local = await _loadEntityVersionIn(
            txn,
            row['local_operation_id'] as String,
          );
          final remote = await _loadEntityVersionIn(
            txn,
            row['remote_operation_id'] as String,
          );
          if (local == null || remote == null) {
            throw StateError('snapshot_conflict_version_missing');
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
        final emittedVersions = <SyncEntityVersion>[
          ...heads,
          for (final conflict in conflicts) ...[
            conflict.local,
            conflict.remote,
          ],
        ];
        for (final member in members) {
          if (!snapshotVersionsCoverOutbox(member, emittedVersions)) {
            throw StateError('snapshot_outbox_not_represented');
          }
        }
        for (final member in members) {
          await txn.insert('sync_snapshot_members', {
            'snapshot_sequence': sequence,
            'operation_id': member.operationId,
            'payload_hash': member.payloadHash,
          });
        }
        prepared = PreparedSyncSnapshot(
          publication: SnapshotPublication(
            sequence: sequence,
            state: SnapshotPublicationState.prepared,
          ),
          heads: heads,
          conflicts: conflicts,
          members: members,
        );
      });
      completer.complete(prepared);
    }).catchError((Object error, StackTrace stackTrace) {
      if (!completer.isCompleted) completer.completeError(error, stackTrace);
    });
    return completer.future;
  }

  @override
  Future<void> freezeSnapshotBlobMembers(
    int snapshotSequence,
    List<SnapshotBlobMapping> mappings,
  ) => _enqueue(() async {
    await _database.transaction((txn) async {
      final publication = await txn.query(
        'sync_snapshot_publications',
        where: 'snapshot_sequence = ? AND state = ?',
        whereArgs: [snapshotSequence, 'prepared'],
      );
      if (publication.isEmpty) throw StateError('snapshot_not_prepared');
      final seen = <String>{};
      for (final mapping in mappings) {
        if (!mapping.verified || !seen.add(mapping.rawHash)) {
          throw StateError('snapshot_blob_mapping_invalid');
        }
        final verified = await txn.query(
          'sync_snapshot_blobs',
          where: 'raw_hash = ? AND file_hash = ? AND verified = 1',
          whereArgs: [mapping.rawHash, mapping.fileHash],
          limit: 1,
        );
        if (verified.isEmpty) {
          throw StateError('snapshot_blob_mapping_unverified');
        }
        await txn.insert('sync_snapshot_blob_members', {
          'snapshot_sequence': snapshotSequence,
          'raw_hash': mapping.rawHash,
          'file_hash': mapping.fileHash,
        });
      }
      await txn.update(
        'sync_snapshot_publications',
        {'state': 'blobs_ready'},
        where: 'snapshot_sequence = ?',
        whereArgs: [snapshotSequence],
      );
    });
  });

  @override
  Future<void> markSnapshotPublished(
    int snapshotSequence, {
    required String filename,
    required String snapshotHash,
  }) => _enqueue(
    () => _confirmSnapshotPublication(
      snapshotSequence,
      filename: filename,
      snapshotHash: snapshotHash,
      completeV1Cutover: false,
    ),
  );

  @override
  Future<void> completeV1CutoverWithPublication(
    int snapshotSequence, {
    required String filename,
    required String snapshotHash,
  }) => _enqueue(
    () => _confirmSnapshotPublication(
      snapshotSequence,
      filename: filename,
      snapshotHash: snapshotHash,
      completeV1Cutover: true,
    ),
  );

  Future<void> _confirmSnapshotPublication(
    int snapshotSequence, {
    required String filename,
    required String snapshotHash,
    required bool completeV1Cutover,
  }) async {
    await _database.transaction((txn) async {
      final parsedFilename = SnapshotFileName.parse(filename);
      if (parsedFilename.isBlob ||
          parsedFilename.snapshotSequence != snapshotSequence ||
          parsedFilename.fileHash != snapshotHash) {
        throw StateError('snapshot_publication_identity_mismatch');
      }
      final publications = await txn.query(
        'sync_snapshot_publications',
        where: 'snapshot_sequence = ? AND state = ?',
        whereArgs: [snapshotSequence, 'blobs_ready'],
      );
      if (publications.isEmpty) throw StateError('snapshot_not_blobs_ready');
      final state = await _snapshotStateIn(txn);
      if (state.lastPublishedSequence != null &&
          snapshotSequence <= state.lastPublishedSequence!) {
        throw StateError('snapshot_publication_sequence_regression');
      }
      if (completeV1Cutover &&
          state.v1MigrationState != V1MigrationState.readyToCutover) {
        throw StateError('snapshot_v1_cutover_not_ready');
      }
      final members = await txn.query(
        'sync_snapshot_members',
        columns: ['operation_id', 'payload_hash'],
        where: 'snapshot_sequence = ?',
        whereArgs: [snapshotSequence],
      );
      for (final member in members) {
        await txn.update(
          'sync_outbox',
          {'uploaded': 1},
          where: 'operation_id = ? AND payload_hash = ?',
          whereArgs: [member['operation_id'], member['payload_hash']],
        );
      }
      await txn.insert('sync_snapshot_state', {
        'key': _snapshotStateKey,
        'next_snapshot_sequence': state.nextSnapshotSequence,
        'last_published_sequence': snapshotSequence,
        'last_published_hash': snapshotHash,
        'last_published_at': DateTime.now().millisecondsSinceEpoch,
        'v1_import_completed': completeV1Cutover || state.v1ImportCompleted
            ? 1
            : 0,
        'v1_migration_state': _migrationStateValue(
          completeV1Cutover
              ? V1MigrationState.cutoverComplete
              : state.v1MigrationState,
        ),
        'v1_last_seen_fingerprint': state.v1LastSeenFingerprint,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.update(
        'sync_snapshot_publications',
        {
          'state': 'published',
          'filename': filename,
          'snapshot_hash': snapshotHash,
          'published_at': DateTime.now().millisecondsSinceEpoch,
        },
        where: 'snapshot_sequence = ?',
        whereArgs: [snapshotSequence],
      );
    });
  }

  @override
  Future<void> abandonIncompleteSnapshotPublications() => _enqueue(() async {
    await _database.update('sync_snapshot_publications', {
      'state': 'abandoned',
    }, where: "state IN ('prepared', 'blobs_ready')");
  });

  @override
  Future<void> recordV1Scan({
    required bool v1HistoryFound,
    required String? fingerprint,
  }) => _enqueue(
    () => _updateSnapshotState(
      (state) => SyncSnapshotState(
        nextSnapshotSequence: state.nextSnapshotSequence,
        lastPublishedSequence: state.lastPublishedSequence,
        lastPublishedHash: state.lastPublishedHash,
        lastPublishedAt: state.lastPublishedAt,
        v1ImportCompleted: state.v1ImportCompleted,
        v1MigrationState: v1HistoryFound
            ? V1MigrationState.needsUpgradeConfirmation
            : state.v1MigrationState,
        v1LastSeenFingerprint: fingerprint,
      ),
    ),
  );

  @override
  Future<void> markV1ReadyToCutover() => _enqueue(
    () => _updateSnapshotState((state) {
      if (state.v1MigrationState != V1MigrationState.needsUpgradeConfirmation) {
        throw StateError('snapshot_v1_confirmation_not_required');
      }
      return SyncSnapshotState(
        nextSnapshotSequence: state.nextSnapshotSequence,
        lastPublishedSequence: state.lastPublishedSequence,
        lastPublishedHash: state.lastPublishedHash,
        lastPublishedAt: state.lastPublishedAt,
        v1ImportCompleted: state.v1ImportCompleted,
        v1MigrationState: V1MigrationState.readyToCutover,
        v1LastSeenFingerprint: state.v1LastSeenFingerprint,
      );
    }),
  );

  @override
  Future<void> markV1MigrationNotRequired() => _enqueue(
    () => _updateSnapshotState((state) {
      if (state.v1MigrationState != V1MigrationState.notStarted) {
        throw StateError('snapshot_v1_migration_already_started');
      }
      return SyncSnapshotState(
        nextSnapshotSequence: state.nextSnapshotSequence,
        lastPublishedSequence: state.lastPublishedSequence,
        lastPublishedHash: state.lastPublishedHash,
        lastPublishedAt: state.lastPublishedAt,
        v1ImportCompleted: true,
        v1MigrationState: V1MigrationState.cutoverComplete,
        v1LastSeenFingerprint: state.v1LastSeenFingerprint,
      );
    }),
  );

  @override
  Future<SyncSnapshotCursor?> loadSnapshotCursor(String deviceId) async {
    final rows = await _database.query(
      'sync_snapshot_cursors',
      where: 'device_id = ?',
      whereArgs: [deviceId],
    );
    return rows.isEmpty ? null : _cursorFromRow(rows.single);
  }

  @override
  Future<List<SyncSnapshotCursor>> loadSnapshotCursors() async => [
    for (final row in await _database.query('sync_snapshot_cursors'))
      _cursorFromRow(row),
  ];

  @override
  Future<void> saveSnapshotCursor(SnapshotCursorAdvance cursor) =>
      _enqueue(() async {
        await _database.transaction(
          (txn) => _saveSnapshotCursorInTransaction(txn, cursor),
        );
      });

  @override
  Future<void> saveVerifiedBlobMapping(SnapshotBlobMapping mapping) => _enqueue(
    () => _database.insert(
      'sync_snapshot_blobs',
      _blobToRow(mapping),
      conflictAlgorithm: ConflictAlgorithm.replace,
    ),
  );

  @override
  Future<void> markSnapshotBlobMappingInvalid(
    String rawHash,
    String fileHash,
  ) => _enqueue(() async {
    final rows = await _database.query(
      'sync_snapshot_blobs',
      where: 'raw_hash = ? AND file_hash = ?',
      whereArgs: [rawHash, fileHash],
      limit: 1,
    );
    final existing = rows.isEmpty ? null : _blobFromRow(rows.single);
    await _database.insert(
      'sync_snapshot_blobs',
      _blobToRow(
        SnapshotBlobMapping(
          rawHash: rawHash,
          fileHash: fileHash,
          rawLength: existing?.rawLength ?? 0,
          verified: false,
          verifiedAt: DateTime.now(),
          source: existing?.source ?? 'invalid',
        ),
      ),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  });

  @override
  Future<List<SnapshotBlobMapping>> loadSnapshotBlobMappings(
    String rawHash,
  ) async => [
    for (final row in await _database.query(
      'sync_snapshot_blobs',
      where: 'raw_hash = ?',
      whereArgs: [rawHash],
      orderBy: 'file_hash ASC',
    ))
      _blobFromRow(row),
  ];

  @override
  Future<List<SnapshotBlobMapping>> loadVerifiedBlobMappings(
    String rawHash,
  ) async => [
    for (final row in await _database.query(
      'sync_snapshot_blobs',
      where: 'raw_hash = ? AND verified = 1',
      whereArgs: [rawHash],
      orderBy: 'file_hash ASC',
    ))
      _blobFromRow(row),
  ];

  // ---- 远端批次应用 ----

  @override
  Future<Map<String, String>> loadAppliedOperationHashes(
    List<String> operationIds,
  ) => _loadAppliedHashes(_database, operationIds);

  @override
  Future<void> savePendingBatch(
    String batchId,
    List<SyncEvent> events,
    String reason,
  ) => _enqueue(() async {
    final existing = await _database.query(
      'sync_pending',
      where: 'batch_id = ?',
      whereArgs: [batchId],
      limit: 1,
    );
    if (existing.firstOrNull?['reason'] == 'prepared') return;
    await _database.insert('sync_pending', {
      'batch_id': batchId,
      'events_json': jsonEncode(events.map((e) => e.toJson()).toList()),
      'reason': reason,
      'plan_json': existing.firstOrNull?['plan_json'],
      'choices_json': existing.firstOrNull?['choices_json'] ?? '{}',
      'received_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  });

  @override
  Future<List<SyncPendingBatch>> loadPendingBatches() async {
    final rows = await _database.query(
      'sync_pending',
      where: 'batch_id != ?',
      whereArgs: [_enrollmentId],
      orderBy: 'received_at ASC',
    );
    return [
      for (final row in rows)
        SyncPendingBatch(
          batchId: row['batch_id'] as String,
          events: [
            for (final item
                in (jsonDecode(row['events_json'] as String) as List))
              SyncEvent.fromJson(Map<String, Object?>.from(item as Map)),
          ],
          reason: row['reason'] as String? ?? 'unknown',
          choices: {
            for (final entry in _decodeObject(
              row['choices_json'] as String,
            ).entries)
              entry.key: SyncEvent.fromJson(
                Map<String, Object?>.from(entry.value as Map),
              ),
          },
        ),
    ];
  }

  @override
  Future<void> saveConflictChoice(
    String batchId,
    String conflictId,
    SyncEvent? event,
  ) => _enqueue(() async {
    await _database.transaction((txn) async {
      final rows = await txn.query(
        'sync_pending',
        where: 'batch_id = ?',
        whereArgs: [batchId],
      );
      if (rows.isEmpty) {
        throw StateError('pending_conflict_missing');
      }
      final choices = _decodeObject(rows.single['choices_json'] as String);
      if (event == null) {
        choices.remove(conflictId);
      } else {
        choices[conflictId] = event.toJson();
      }
      await txn.update(
        'sync_pending',
        {'choices_json': jsonEncode(choices)},
        where: 'batch_id = ?',
        whereArgs: [batchId],
      );
    });
  });

  @override
  Future<Map<SyncEntityKey, SyncEntityVersion>> loadEntityHeads(
    Set<SyncEntityKey> keys,
  ) async {
    final result = <SyncEntityKey, SyncEntityVersion>{};
    for (final key in keys) {
      final rows = await _database.rawQuery(
        'SELECT v.* FROM sync_entity_versions v JOIN sync_entity_heads h ON v.operation_id = h.operation_id WHERE h.scope = ? AND h.type = ? AND h.id = ?',
        [key.scope, key.type, key.id],
      );
      for (final row in rows) {
        final version = SyncEntityVersion(
          entity: key,
          version: SyncVersion.fromJson(
            _decodeObject(row['version_json'] as String),
          ),
          payloadHash: row['payload_hash'] as String,
          payload: row['payload_envelope'] == null
              ? null
              : jsonDecode(row['payload_envelope'] as String),
          deleted: (row['deleted'] as int) != 0,
          operationId: row['operation_id'] as String,
        );
        final prior = result[key];
        if (prior == null ||
            version.version.logicalTime > prior.version.logicalTime) {
          result[key] = version;
        }
      }
    }
    return result;
  }

  @override
  Future<void> removePendingBatch(String id) => _enqueue(() async {
    await _database.delete(
      'sync_pending',
      where: 'batch_id = ?',
      whereArgs: [id],
    );
  });

  static Future<void> _writeVersion(
    Transaction txn,
    SyncEntityVersion version, {
    required bool head,
  }) async {
    await txn.insert('sync_entity_versions', {
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
    if (head) {
      await txn.insert('sync_entity_heads', {
        'scope': version.entity.scope,
        'type': version.entity.type,
        'id': version.entity.id,
        'operation_id': version.operationId,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  @override
  Future<void> finalizePreparedBatches() => _enqueue(() async {
    await _database.transaction((txn) async {
      final prepared = await txn.query(
        'sync_pending',
        where: "reason = 'prepared'",
      );
      for (final row in prepared) {
        final outstanding = await txn.query(
          'sync_apply_journal',
          where: 'batch_id = ? AND applied = 0',
          whereArgs: [row['batch_id']],
          limit: 1,
        );
        if (outstanding.isNotEmpty) continue;
        await _finalizePlan(txn, _decodeObject(row['plan_json'] as String));
      }
    });
  });

  static Future<void> _finalizePlan(
    Transaction txn,
    Map<String, Object?> plan,
  ) async {
    final id = plan['batchId'] as String;
    final hashes = Map<String, Object?>.from(plan['operations'] as Map);
    for (final item in hashes.entries) {
      await txn.insert('sync_applied_ops', {
        'operation_id': item.key,
        'batch_id': id,
        'payload_hash': item.value,
        'applied_at': DateTime.now().millisecondsSinceEpoch,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    final states = await txn.query('sync_device', limit: 1);
    if (states.isNotEmpty) {
      var known = SyncVersionVector.fromJson(
        _decodeObject(states.single['known_vector'] as String),
      );
      for (final raw in plan['versions'] as List) {
        final version = SyncVersion.fromJson(
          Map<String, Object?>.from(raw as Map),
        );
        known = known
            .merged(version.context)
            .merged(
              SyncVersionVector({version.dot.deviceId: version.dot.sequence}),
            );
      }
      await txn.update('sync_device', {
        'known_vector': jsonEncode(known.toJson()),
      });
    }
    for (final raw in plan['resolutionEvents'] as List) {
      final event = SyncEvent.fromJson(Map<String, Object?>.from(raw as Map));
      await txn.insert('sync_outbox', {
        'batch_id': event.batchId,
        'operation_id': event.operationId,
        'relative_path': _relativePathFor(event),
        'payload_hash': event.payloadHash,
        'event_json': jsonEncode(event.toJson()),
        'retry_count': 0,
        'uploaded': 0,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    for (final conflictId in plan['resolvedConflictIds'] as List) {
      await txn.delete(
        'sync_conflicts',
        where: 'id = ?',
        whereArgs: [conflictId],
      );
    }
    for (final pendingId in <Object?>[
      id,
      ...plan['completedPendingIds'] as List,
    ]) {
      await txn.delete(
        'sync_pending',
        where: 'batch_id = ?',
        whereArgs: [pendingId],
      );
    }
  }

  /// 校验与写入在同一事务内完成。
  ///
  /// 事务内先读「已应用 hash」与该批涉及实体的当前版本，交给共享的
  /// [SyncPlanValidator] 判定；任何一条不满足即抛 [SyncConflictException]，
  /// 事务回滚、零副作用。校验通过后依次写 sync_entity_versions（含冲突两侧的历史行，
  /// 不覆盖既有版本）、sync_apply_journal、sync_shadow、sync_applied_ops。
  ///
  /// 生产业务应用由 LedgerRepository 在同一事务先写业务表，再调用事务内 helper。
  /// 含 KV journal 的批次保持 prepared，直到 finalizePreparedBatches 完成登记。
  @override
  Future<void> applyRemoteBatch(RemoteApplyPlan plan) {
    return _enqueue(() async {
      await _database.transaction((txn) async {
        await applyRemoteBatchInTransaction(txn, plan);
      });
    });
  }

  /// Called by the owning ledger repository inside its business transaction.
  Future<void> applyRemoteBatchInTransaction(
    Transaction txn,
    RemoteApplyPlan plan,
  ) async {
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

    final cursorAdvance = plan.cursorAdvance;
    if (cursorAdvance != null) {
      await _saveSnapshotCursorInTransaction(txn, cursorAdvance);
    }

    final appliedAt = DateTime.now().millisecondsSinceEpoch;

    // 实体版本：按 operation_id 插入，已存在则忽略——同一操作重放不应改写
    // 既有版本行（历史版本要留给冲突决议审计）。
    for (final version in plan.entityVersions) {
      await _writeVersion(txn, version, head: true);
    }

    // KV journal：偏好写不进 SQLite 事务，先落盘待应用值，由上层按批次刷盘后
    // 标记 applied。重放是幂等的（按目标值覆盖）。
    final journalStatement = txn.batch();
    for (final id in plan.completedPendingIds) {
      await txn.delete(
        'sync_apply_journal',
        where: 'batch_id = ?',
        whereArgs: [id],
      );
    }
    for (final entry in plan.kvJournalValues.entries) {
      journalStatement.insert('sync_apply_journal', <String, Object?>{
        'batch_id': plan.batchId,
        'kv_key': entry.key,
        'kv_value': entry.value,
        'target_hash': computeSyncPayloadHash(entry.value),
        'expected_hash':
            plan.kvExpectedHashes[entry.key] ?? computeSyncPayloadHash(null),
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

    // KV writes form a recoverable prepared commit. Applied ids and vector
    // stay invisible until every journal row has been durably flushed.
    final prepared = encodePreparedPlan(plan);
    if (plan.kvJournalValues.isEmpty && plan.conflicts.isEmpty) {
      await _finalizePlan(txn, prepared);
    } else if (plan.kvJournalValues.isNotEmpty) {
      await txn.insert('sync_pending', {
        'batch_id': plan.batchId,
        'events_json': jsonEncode([
          for (final v in plan.entityVersions)
            SyncEvent(
              protocolVersion: syncProtocolVersion,
              operationId: v.operationId,
              version: v.version,
              entity: v.entity,
              operation: v.deleted
                  ? SyncOperationKind.delete
                  : SyncOperationKind.upsert,
              payloadHash: v.payloadHash,
              payload: v.payload,
              batchId: plan.batchId,
              keyFingerprint: 'local',
            ).toJson(),
        ]),
        'received_at': appliedAt,
        'reason': 'prepared',
        'plan_json': jsonEncode(prepared),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    for (final conflict in plan.conflicts) {
      for (final version in [conflict.local, conflict.remote]) {
        await txn.insert('sync_entity_versions', {
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
      await txn.insert('sync_conflicts', {
        'id': conflict.id,
        'scope': conflict.entity.scope,
        'type': conflict.entity.type,
        'entity_id': conflict.entity.id,
        'local_operation_id': conflict.local.operationId,
        'remote_operation_id': conflict.remote.operationId,
        'created_at': appliedAt,
      }, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
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
    DatabaseExecutor txn,
    List<String> operationIds,
  ) async {
    if (operationIds.isEmpty) {
      return <String, String>{};
    }
    if (operationIds.length > 500) {
      final result = <String, String>{};
      for (var offset = 0; offset < operationIds.length; offset += 500) {
        result.addAll(
          await _loadAppliedHashes(
            txn,
            operationIds.sublist(
              offset,
              (offset + 500).clamp(0, operationIds.length),
            ),
          ),
        );
      }
      return result;
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
      final rows = await txn.rawQuery(
        'SELECT v.* FROM sync_entity_versions v JOIN sync_entity_heads h ON h.operation_id = v.operation_id WHERE h.scope = ? AND h.type = ? AND h.id = ?',
        [key.scope, key.type, key.id],
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
        }, conflictAlgorithm: ConflictAlgorithm.replace);
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

  static Future<SyncEntityVersion?> _loadEntityVersionIn(
    Transaction txn,
    String operationId,
  ) async {
    final rows = await txn.query(
      'sync_entity_versions',
      where: 'operation_id = ?',
      whereArgs: [operationId],
      limit: 1,
    );
    return rows.isEmpty ? null : _versionFromRow(rows.single);
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
          expectedHash: row['expected_hash'] as String?,
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

  static SyncSnapshotState _snapshotStateFromRow(
    Map<String, Object?> row,
  ) => SyncSnapshotState(
    nextSnapshotSequence: (row['next_snapshot_sequence'] as num?)?.toInt() ?? 1,
    lastPublishedSequence: (row['last_published_sequence'] as num?)?.toInt(),
    lastPublishedHash: row['last_published_hash'] as String?,
    lastPublishedAt: _dateFromMilliseconds(row['last_published_at']),
    v1ImportCompleted:
        ((row['v1_import_completed'] as num?)?.toInt() ?? 0) != 0,
    v1MigrationState: _migrationStateFromValue(
      row['v1_migration_state'] as String?,
    ),
    v1LastSeenFingerprint: row['v1_last_seen_fingerprint'] as String?,
  );

  Future<SyncSnapshotState> _snapshotStateIn(Transaction txn) async {
    final rows = await txn.query(
      'sync_snapshot_state',
      where: 'key = ?',
      whereArgs: [_snapshotStateKey],
    );
    return rows.isEmpty
        ? const SyncSnapshotState()
        : _snapshotStateFromRow(rows.single);
  }

  Future<void> _updateSnapshotState(
    SyncSnapshotState Function(SyncSnapshotState) update,
  ) async {
    await _database.transaction((txn) async {
      final state = update(await _snapshotStateIn(txn));
      await txn.insert('sync_snapshot_state', {
        'key': _snapshotStateKey,
        'next_snapshot_sequence': state.nextSnapshotSequence,
        'last_published_sequence': state.lastPublishedSequence,
        'last_published_hash': state.lastPublishedHash,
        'last_published_at': state.lastPublishedAt?.millisecondsSinceEpoch,
        'v1_import_completed': state.v1ImportCompleted ? 1 : 0,
        'v1_migration_state': _migrationStateValue(state.v1MigrationState),
        'v1_last_seen_fingerprint': state.v1LastSeenFingerprint,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  static String _migrationStateValue(V1MigrationState state) => switch (state) {
    V1MigrationState.notStarted => 'not_started',
    V1MigrationState.needsUpgradeConfirmation => 'needs_upgrade_confirmation',
    V1MigrationState.readyToCutover => 'ready_to_cutover',
    V1MigrationState.cutoverComplete => 'cutover_complete',
  };

  static V1MigrationState _migrationStateFromValue(String? value) =>
      switch (value) {
        'needs_upgrade_confirmation' =>
          V1MigrationState.needsUpgradeConfirmation,
        'ready_to_cutover' => V1MigrationState.readyToCutover,
        'cutover_complete' => V1MigrationState.cutoverComplete,
        _ => V1MigrationState.notStarted,
      };

  static DateTime? _dateFromMilliseconds(Object? value) =>
      value is num ? DateTime.fromMillisecondsSinceEpoch(value.toInt()) : null;

  static Map<String, Object?> _cursorToRow(SnapshotCursorAdvance cursor) => {
    'device_id': cursor.deviceId,
    'last_merged_sequence': cursor.sequence,
    'last_merged_hash': cursor.snapshotHash,
    'last_merged_at': cursor.mergedAt?.millisecondsSinceEpoch,
  };

  static Future<void> _saveSnapshotCursorInTransaction(
    Transaction txn,
    SnapshotCursorAdvance cursor,
  ) async {
    final existing = await txn.query(
      'sync_snapshot_cursors',
      where: 'device_id = ?',
      whereArgs: [cursor.deviceId],
      limit: 1,
    );
    if (existing.isNotEmpty) {
      final current = _cursorFromRow(existing.single);
      if (cursor.sequence < current.lastMergedSequence) {
        throw StateError('snapshot_cursor_regression');
      }
      if (cursor.sequence == current.lastMergedSequence &&
          cursor.snapshotHash != current.lastMergedHash) {
        throw StateError('snapshot_sequence_collision');
      }
    }
    await txn.insert(
      'sync_snapshot_cursors',
      _cursorToRow(cursor),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static SyncSnapshotCursor _cursorFromRow(Map<String, Object?> row) =>
      SyncSnapshotCursor(
        deviceId: row['device_id'] as String,
        lastMergedSequence: (row['last_merged_sequence'] as num).toInt(),
        lastMergedHash: row['last_merged_hash'] as String,
        lastMergedAt: _dateFromMilliseconds(row['last_merged_at']),
      );

  static Map<String, Object?> _blobToRow(SnapshotBlobMapping mapping) => {
    'raw_hash': mapping.rawHash,
    'file_hash': mapping.fileHash,
    'raw_length': mapping.rawLength,
    'verified': mapping.verified ? 1 : 0,
    'verified_at': mapping.verifiedAt?.millisecondsSinceEpoch,
    'source': mapping.source,
  };

  static SnapshotBlobMapping _blobFromRow(Map<String, Object?> row) =>
      SnapshotBlobMapping(
        rawHash: row['raw_hash'] as String,
        fileHash: row['file_hash'] as String,
        rawLength: (row['raw_length'] as num).toInt(),
        verified: ((row['verified'] as num).toInt()) != 0,
        verifiedAt: _dateFromMilliseconds(row['verified_at']),
        source: row['source'] as String?,
      );

  static SyncOutboxRecord _outboxFromRow(Map<String, Object?> row) =>
      SyncOutboxRecord(
        batchId: row['batch_id'] as String,
        operationId: row['operation_id'] as String,
        relativePath: row['relative_path'] as String,
        payloadHash: row['payload_hash'] as String,
        retryCount: (row['retry_count'] as num?)?.toInt() ?? 0,
        event: _decodeOutboxEvent(row['event_json'] as String?),
      );

  static SyncEntityVersion _versionFromRow(Map<String, Object?> row) =>
      SyncEntityVersion(
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
        deleted: ((row['deleted'] as num?)?.toInt() ?? 0) != 0,
        operationId: row['operation_id'] as String,
      );

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
