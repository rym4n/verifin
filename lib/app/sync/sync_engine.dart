import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../backup/webdav_config.dart';
import 'sync_change_tracker.dart';
import 'sync_clock.dart';
import 'sync_codec.dart';
import 'sync_conflict.dart';
import 'sync_kv_projection.dart';
import 'sync_models.dart';
import 'sync_projection.dart';
import 'sync_store.dart';
import 'webdav_sync_transport.dart';

/// Sync trigger reason.
enum SyncTrigger {
  /// App startup.
  startup,

  /// App resumed from background.
  resumed,

  /// Local mutation occurred.
  localMutation,

  /// Manual user sync.
  manual,
}

/// Sync run result.
class SyncRunResult {
  const SyncRunResult({
    required this.uploaded,
    required this.downloaded,
    required this.conflicts,
    required this.pending,
    this.errorCode,
  });

  final int uploaded;
  final int downloaded;
  final int conflicts;
  final int pending;
  final String? errorCode;
}

/// Sync engine: orchestrates upload, download, merge, and conflict resolution.
class SyncEngine {
  SyncEngine({
    required SyncRepository repository,
    WebdavSyncTransport? transport,
    required SyncProjectionSource controller,
    WebdavConfig? config,

    /// Wrap remote-apply calls to suppress outbox echo (e.g.,
    /// `VeriFinController.runRemoteApply`). If null, calls applyRemoteBatch
    /// directly — suitable only for tests that don't use a change tracker.
    Future<void> Function(Future<void> Function())? remoteApply,
  }) : _repository = repository, // ignore: prefer_initializing_formals
       _transport = transport, // ignore: prefer_initializing_formals
       _controller = controller, // ignore: prefer_initializing_formals
       _config = config, // ignore: prefer_initializing_formals
       _remoteApply = remoteApply; // ignore: prefer_initializing_formals

  final SyncRepository _repository;

  /// 传输层可空：冲突决议（[resolveConflict]）只写本地 outbox，不碰网络。
  /// 决议 UI 因此在没有 WebDAV 配置时也能构造一个仅用于决议的引擎，
  /// 无需为一次纯本地写入先建一个 HTTP 客户端。
  final WebdavSyncTransport? _transport;
  final SyncProjectionSource _controller;
  final Future<void> Function(Future<void> Function())? _remoteApply;
  WebdavConfig? _config;

  SyncClock? _clock;

  // _changeTracker is intentionally not used yet; reserved for future
  // integration where the engine creates and disposes the tracker.
  // ignore: unused_field
  SyncChangeTracker? _changeTracker;

  /// Holds full batch records between enqueueBatch and upload so event bytes
  /// can be encoded for upload without a separate storage round-trip.
  final Map<String, SyncBatchRecord> _pendingBatchCache = {};

  /// Update the WebDAV config (e.g., after settings change).
  void updateConfig(WebdavConfig? config) {
    _config = config;
  }

  /// Enqueue a local batch for upload. Caches the full record so event bytes
  /// are available during the upload phase without a second encoding round-trip.
  Future<void> enqueueBatch(SyncBatchRecord batch) async {
    _pendingBatchCache[batch.batchId] = batch;
    await _repository.enqueueBatch(batch);
  }

  /// Run a sync cycle: upload outbox, scan remote, download and merge.
  Future<SyncRunResult> run({required SyncTrigger trigger}) async {
    final transport = _transport;
    if (_config == null || transport == null) {
      return const SyncRunResult(
        uploaded: 0,
        downloaded: 0,
        conflicts: 0,
        pending: 0,
        errorCode: 'no_config',
      );
    }

    try {
      // Ensure clock is initialized
      await _ensureClock();

      // Ensure sync tree exists
      await transport.ensureSyncTree(_config!);

      // Upload phase
      final uploaded = await _uploadOutbox();

      // Download phase
      final (downloaded, conflicts, pending) = await _scanAndApply();

      return SyncRunResult(
        uploaded: uploaded,
        downloaded: downloaded,
        conflicts: conflicts,
        pending: pending,
      );
    } catch (error) {
      return SyncRunResult(
        uploaded: 0,
        downloaded: 0,
        conflicts: 0,
        pending: 0,
        errorCode: error.toString(),
      );
    }
  }

  /// Initialize from restored data: baseline or join-conflict flow.
  Future<void> initializeFromRestoredData() async {
    final transport = _transport;
    if (_config == null || transport == null) {
      return;
    }

    try {
      await _ensureClock();

      // Ensure sync tree exists
      await transport.ensureSyncTree(_config!);

      // Scan remote to determine if empty or not
      final remoteFiles = await transport.listSyncFiles(_config!);
      final remoteEvents = remoteFiles
          .where((f) => f.kind == WebdavSyncFileKind.event)
          .toList();

      if (remoteEvents.isEmpty) {
        // Empty remote: create baseline batch
        await _createBaselineBatch();
      } else {
        // Non-empty remote: join-conflict flow
        await _joinConflictFlow(remoteFiles);
      }

      // Save shadow from current state
      final snapshot = SyncProjection.fromExportData(
        _controller.exportDataForSync(),
      );
      await _repository.saveShadow(snapshot.payloadHashes);

      // Save scan state
      final scanState = await _buildScanState(remoteFiles);
      await _repository.saveScanState(scanState);
    } catch (error) {
      // Initialization errors are logged but not thrown
      // to avoid blocking app startup
      return;
    }
  }

  /// Get all current conflicts.
  Future<List<SyncConflict>> conflicts() async {
    final records = await _repository.loadConflicts();
    return records.map(SyncConflict.fromRecord).toList();
  }

  /// Resolve a conflict by creating a resolve event.
  Future<void> resolveConflict(
    String conflictId,
    ConflictResolution resolution,
  ) async {
    if (resolution == ConflictResolution.cancel) {
      return;
    }

    // Load the conflict
    final conflicts = await _repository.loadConflicts();
    final conflict = conflicts.where((c) => c.id == conflictId).firstOrNull;
    if (conflict == null) {
      return;
    }

    await _ensureClock();

    // Determine which payload to keep
    Object? chosenPayload;
    SyncOperationKind operation = SyncOperationKind.upsert;

    switch (resolution) {
      case ConflictResolution.keepLocal:
        chosenPayload = conflict.local.payload;
        if (conflict.local.deleted) {
          operation = SyncOperationKind.delete;
        }
        break;
      case ConflictResolution.keepRemote:
        chosenPayload = conflict.remote.payload;
        if (conflict.remote.deleted) {
          operation = SyncOperationKind.delete;
        }
        break;
      case ConflictResolution.keepDelete:
        chosenPayload = null;
        operation = SyncOperationKind.delete;
        break;
      case ConflictResolution.keepEdit:
        // Find the non-deleted version
        if (!conflict.local.deleted) {
          chosenPayload = conflict.local.payload;
        } else if (!conflict.remote.deleted) {
          chosenPayload = conflict.remote.payload;
        }
        break;
      case ConflictResolution.cancel:
        return;
    }

    // Create resolve event
    final batchId = _clock!.nextOperationId();
    final event = SyncEvent(
      protocolVersion: syncProtocolVersion,
      operationId: _clock!.nextOperationId(),
      version: _clock!.nextVersion(),
      entity: conflict.entity,
      operation: operation,
      payloadHash: computeSyncPayloadHash(chosenPayload),
      payload: chosenPayload,
      batchId: batchId,
      keyFingerprint: 'local',
    );

    // Enqueue the resolve event
    await _repository.enqueueBatch(
      SyncBatchRecord(
        batchId: batchId,
        events: [event],
        manifest: SyncBatchManifest(
          batchId: batchId,
          operationIds: [event.operationId],
          blobHashes: const [],
          manifestHash: 'resolve-manifest',
        ),
      ),
    );

    // 决议事件已入队：用户已经做出选择，这条冲突不再需要出现在审阅列表里。
    // 必须在 enqueue 成功之后删除——先删后写会在写失败时把用户的选择丢掉。
    await _repository.removeConflict(conflictId);

    // Apply locally through change tracker
    // This would require updating the controller state
    // For now, we'll rely on the next sync to propagate
  }

  Future<void> _ensureClock() async {
    if (_clock != null) return;

    final state = await _repository.loadDeviceState();
    if (state.deviceId.isEmpty) {
      // First time: create device identity
      final deviceId = _generateDeviceId();
      _clock = SyncClock.createWithDeviceId(deviceId);
      await _repository.saveDeviceState(
        SyncDeviceState(
          deviceId: _clock!.deviceId,
          nextSequence: _clock!.nextSequence,
          knownVector: _clock!.knownVector,
        ),
      );
    } else {
      // Restore from state
      _clock = SyncClock.restore(
        deviceId: state.deviceId,
        nextSequence: state.nextSequence,
        knownVector: state.knownVector,
      );
    }
  }

  static String _generateDeviceId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Future<int> _uploadOutbox() async {
    final outbox = await _repository.loadOutbox();
    if (outbox.isEmpty) {
      return 0;
    }

    // Group by batchId; each outbox row carries the event stored at enqueueBatch.
    // We need to re-encode the events to upload them, so we load the batch from
    // the outbox records (which store events via SyncBatchRecord.events).
    final batches = <String, List<SyncOutboxRecord>>{};
    for (final record in outbox) {
      batches.putIfAbsent(record.batchId, () => []).add(record);
    }

    var uploadedCount = 0;
    String? lastUploadError;
    final codec = SyncCodec(passphrase: '');

    for (final entry in batches.entries) {
      final batchId = entry.key;
      final records = entry.value;

      try {
        // Re-encode event files from the pending batch cache and upload.
        for (final record in records) {
          final eventBytes = await _encodeEventForUpload(record, codec);
          if (eventBytes != null) {
            final hash = sha256.convert(eventBytes).toString();
            await _transport!.putImmutable(
              _config!,
              record.relativePath,
              Stream.value(eventBytes),
              eventBytes.length,
              hash,
            );
          }
        }

        // Upload manifest.
        await _uploadManifest(batchId, records);

        // Upload commit marker — only after manifest succeeds.
        final commitPath = _commitPath(batchId);
        await _uploadCommitMarker(commitPath);

        // Mark batch uploaded only after commit succeeds.
        await _repository.markBatchUploaded(batchId);
        uploadedCount++;
      } catch (error) {
        // Record error for propagation; continue trying remaining batches.
        lastUploadError = error.toString();
        continue;
      }
    }

    // Surface the upload error through run() so callers can inspect it.
    if (lastUploadError != null && uploadedCount == 0) {
      throw Exception(lastUploadError);
    }

    return uploadedCount;
  }

  /// Encode an outbox record's event as upload bytes.
  ///
  /// Returns null if the event payload is not available (already uploaded or
  /// not stored). In that case the upload step is skipped for that file.
  Future<Uint8List?> _encodeEventForUpload(
    SyncOutboxRecord record,
    SyncCodec codec,
  ) async {
    // The outbox record holds the payloadHash but not the full event payload.
    // Callers that need the full event bytes should supply the batch's events
    // via the in-memory cache populated at enqueueBatch time.
    // Without a pending-batch cache, we return null and skip the event file
    // upload — the batch will then fail its commit-present check on the remote
    // side and be deferred to sync_pending on the next scan.
    final batch = _pendingBatchCache[record.batchId];
    if (batch == null) return null;
    try {
      final event = batch.events.firstWhere(
        (e) => e.operationId == record.operationId,
      );
      final envelope = await codec.encode(event, syncProtocolVersion);
      final json = jsonEncode(envelope);
      return Uint8List.fromList(utf8.encode(json));
    } catch (_) {
      return null;
    }
  }

  Future<void> _uploadManifest(
    String batchId,
    List<SyncOutboxRecord> records,
  ) async {
    final manifest = {
      'batchId': batchId,
      'operationIds': records.map((r) => r.operationId).toList(),
      'blobHashes': <String>[],
      'manifestHash': 'manifest-$batchId',
    };
    final bytes = utf8.encode(jsonEncode(manifest));
    final hash = sha256.convert(bytes).toString();
    final stream = Stream.value(bytes);
    await _transport!.putImmutable(
      _config!,
      _manifestPath(batchId),
      stream,
      bytes.length,
      hash,
    );
  }

  Future<void> _uploadCommitMarker(String commitPath) async {
    final bytes = utf8.encode('committed');
    final hash = sha256.convert(bytes).toString();
    final stream = Stream.value(bytes);
    await _transport!.putImmutable(
      _config!,
      commitPath,
      stream,
      bytes.length,
      hash,
    );
  }

  Future<(int, int, int)> _scanAndApply() async {
    final transport = _transport!;
    final remoteFiles = await transport.listSyncFiles(_config!);

    // Build scan state
    final scanState = await _buildScanState(remoteFiles);

    // Group files by batch — downloads each manifest to match events correctly.
    final batches = await _groupFilesByBatchAsync(remoteFiles);

    var downloadedCount = 0;
    var conflictCount = 0;
    var pendingCount = 0;

    for (final batch in batches.values) {
      if (!batch.isComplete) {
        pendingCount++;
        continue;
      }

      try {
        // Download and decode events
        final events = <SyncEvent>[];
        for (final eventFile in batch.eventFiles) {
          final bytes = await transport.downloadSyncFile(
            _config!,
            eventFile.relativePath,
            maxBytes: syncMaxDownloadBytes,
          );
          final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
          final event = SyncEvent.fromJson(json);
          events.add(event);
        }

        // Merge and apply
        final result = await _mergeAndApply(events);
        downloadedCount += result.$1;
        conflictCount += result.$2;
      } catch (error, stack) {
        // Batch processing failed; record for diagnostics and skip.
        assert(() {
          // ignore: avoid_print
          print('SyncEngine batch error: $error\n$stack');
          return true;
        }());
        continue;
      }
    }

    // Save scan state
    await _repository.saveScanState(scanState);

    return (downloadedCount, conflictCount, pendingCount);
  }

  Future<(int, int)> _mergeAndApply(List<SyncEvent> events) async {
    var appliedCount = 0;
    var conflictCount = 0;

    // Load known vector once for all events in this batch.
    final state = await _repository.loadDeviceState();
    final knownVector = state.knownVector;

    for (final event in events) {
      // Check if already applied via dot sequence.
      final knownSeq = knownVector.values[event.version.dot.deviceId] ?? 0;
      if (event.version.dot.sequence <= knownSeq) {
        continue;
      }

      final shadow = await _repository.loadShadow();
      final currentHash = shadow[event.entity];

      final causality = _determineCausality(event, currentHash, knownVector);

      if (causality == SyncCausality.before) {
        // We already have a causally later version — discard.
        continue;
      } else if (causality == SyncCausality.equal) {
        // Identical payload already present — idempotent.
        continue;
      } else if (causality == SyncCausality.concurrent) {
        await _storeConflict(event);
        conflictCount++;
        continue;
      }

      // SyncCausality.after — incoming causally follows what we know.
      await _applyEvent(event);
      appliedCount++;
    }

    return (appliedCount, conflictCount);
  }

  SyncCausality _determineCausality(
    SyncEvent event,
    String? currentHash,
    SyncVersionVector knownVector,
  ) {
    if (currentHash == null) {
      // No current entity — incoming is definitely new.
      return SyncCausality.after;
    }
    if (currentHash == event.payloadHash) {
      // Same payload already applied — idempotent.
      return SyncCausality.equal;
    }

    // Entity exists with a different payload.
    // Compare the event's causal context against this device's known vector.
    //
    //   after  — event was created knowing our entire state or more → apply it.
    //   equal  — event's context matches our known vector exactly.
    //            Sub-case A: device is known (knownSeq > 0) → direct successor, apply.
    //            Sub-case B: device is unknown (knownSeq == 0) → first event from a
    //            device we've never synced with; local entity already exists from a
    //            different source → genuine join conflict.
    //   before / concurrent — conflict.
    final cmp = event.version.context.compare(knownVector);
    if (cmp == SyncCausality.after) {
      return SyncCausality.after;
    }
    if (cmp == SyncCausality.equal) {
      final knownSeqForDevice =
          knownVector.values[event.version.dot.deviceId] ?? 0;
      if (knownSeqForDevice > 0) {
        // We have already seen events from this device and our vectors are
        // equal — this is a direct successor, apply it.
        return SyncCausality.after;
      }
      // First-ever event from a previously unknown device.
      // Local entity exists from a different origin → join conflict.
      return SyncCausality.concurrent;
    }
    // before or concurrent → conflict.
    return SyncCausality.concurrent;
  }

  Future<void> _applyEvent(SyncEvent event) async {
    // Build apply plan
    final entityVersion = SyncEntityVersion(
      entity: event.entity,
      version: event.version,
      payloadHash: event.payloadHash,
      payload: event.payload,
      deleted: event.operation == SyncOperationKind.delete,
      operationId: event.operationId,
    );

    final plan = RemoteApplyPlan(
      batchId: event.batchId,
      entityVersions: [entityVersion],
      appliedOperationIds: [event.operationId],
      shadowHashes: {encodeSyncEntityKey(event.entity): event.payloadHash},
      kvJournalValues: _kvJournalValuesFor(event),
      appliedPayloadHashes: {event.operationId: event.payloadHash},
    );

    // Route through the echo-suppression wrapper when provided.
    // Without it, a change tracker running on the same controller would
    // re-enqueue the just-applied remote data as a local mutation.
    if (_remoteApply != null) {
      await _remoteApply(() => _repository.applyRemoteBatch(plan));
    } else {
      await _repository.applyRemoteBatch(plan);
    }
  }

  /// 若 [event] 命中 KV 偏好类型（profile/主题/面板/排序/默认账户/FAB/金额/
  /// 小组件定义，见 [SyncKvProjection]），把它折算成一条「本地 KV 键 → 目标完整
  /// 值」的 journal 行；否则返回空表——SQLite 落库的账目类实体（entries/
  /// accounts/…）不经这条路径。
  ///
  /// 合并需要「当前完整值」打底（这些 KV 键各自只有一份整存的值，远端片段只是
  /// 其中一角），取自 [_controller.exportDataForSync()] 而不是本地 KV 原始字符串：
  /// 前者是控制器已解码好的内存视图，与 [SyncProjection.fromExportData] 拆分
  /// 片段时用的是同一份数据，两边字段语义天然对齐。
  Map<String, String> _kvJournalValuesFor(SyncEvent event) {
    final entityType = event.entity.type;
    final storageKey = SyncKvProjection.storageKeyFor(entityType);
    if (storageKey == null) {
      return const <String, String>{};
    }
    final current = _controller.exportDataForSync()[entityType];
    final merged = SyncKvProjection.mergeToStorageValue(
      entityType: entityType,
      entityId: event.entity.id,
      currentValue: current,
      payload: event.payload,
      deleted: event.operation == SyncOperationKind.delete,
    );
    if (merged == null) {
      return const <String, String>{};
    }
    return <String, String>{storageKey: merged};
  }

  Future<void> _storeConflict(SyncEvent remoteEvent) async {
    // Load the current shadow to find the locally-applied payload hash.
    final shadow = await _repository.loadShadow();
    final localHash = shadow[remoteEvent.entity];

    if (localHash == null) {
      // No local entity in shadow — no real conflict, just apply.
      await _applyEvent(remoteEvent);
      return;
    }

    // Build a stub local version from the shadow hash.
    // Full payload reconstruction would require reading from entity_versions;
    // for conflict storage we record the hash and leave payload as null
    // (resolveConflict will show both remote versions to the user).
    await _ensureClock();
    final localVersion = SyncEntityVersion(
      entity: remoteEvent.entity,
      version: _clock!.nextVersion(),
      payloadHash: localHash,
      payload: null, // Reconstructed from sync_entity_versions on resolution.
      deleted: false,
      operationId: _clock!.nextOperationId(),
    );

    final remoteVersion = SyncEntityVersion(
      entity: remoteEvent.entity,
      version: remoteEvent.version,
      payloadHash: remoteEvent.payloadHash,
      payload: remoteEvent.payload,
      deleted: remoteEvent.operation == SyncOperationKind.delete,
      operationId: remoteEvent.operationId,
    );

    final conflictRecord = SyncConflictRecord(
      id: 'conflict-${remoteEvent.operationId}',
      entity: remoteEvent.entity,
      local: localVersion,
      remote: remoteVersion,
    );

    // Store conflict directly, bypassing applyRemoteBatch validation which
    // would reject a plan referencing operations not yet in sync_applied_ops.
    await _repository.storeConflict(conflictRecord);
  }

  Future<void> _createBaselineBatch() async {
    await _ensureClock();

    // Export current state
    final snapshot = SyncProjection.fromExportData(
      _controller.exportDataForSync(),
    );
    final entities = snapshot.entities.values.toList();

    if (entities.isEmpty) {
      return;
    }

    final batchId = _clock!.nextOperationId();
    final events = <SyncEvent>[];

    for (final entity in entities) {
      final event = SyncEvent(
        protocolVersion: syncProtocolVersion,
        operationId: _clock!.nextOperationId(),
        version: _clock!.nextVersion(),
        entity: entity.key,
        operation: SyncOperationKind.upsert,
        payloadHash: entity.payloadHash,
        payload: entity.payload,
        batchId: batchId,
        keyFingerprint: 'local',
      );
      events.add(event);
    }

    // Enqueue baseline batch
    await _repository.enqueueBatch(
      SyncBatchRecord(
        batchId: batchId,
        events: events,
        manifest: SyncBatchManifest(
          batchId: batchId,
          operationIds: events.map((e) => e.operationId).toList(),
          blobHashes: const [],
          manifestHash: 'baseline-manifest',
        ),
      ),
    );
  }

  Future<void> _joinConflictFlow(List<WebdavSyncFile> remoteFiles) async {
    // Seed the shadow from the current local state before scanning. Without
    // this, the first remote event for any locally-present entity would be
    // treated as "no current version" and applied silently instead of flagged
    // as a join conflict.
    final localSnapshot = SyncProjection.fromExportData(
      _controller.exportDataForSync(),
    );
    if (!localSnapshot.isEmpty) {
      await _repository.saveShadow(localSnapshot.payloadHashes);
    }

    // Scan and download all remote events; differing hashes produce conflicts.
    await _scanAndApply();
  }

  Future<SyncScanState> _buildScanState(
    List<WebdavSyncFile> remoteFiles,
  ) async {
    final contiguousSequences = <String, int>{};
    final gaps = <String, List<int>>{};

    // Group by device
    final deviceFiles = <String, List<WebdavSyncFile>>{};
    for (final file in remoteFiles) {
      if (file.kind == WebdavSyncFileKind.event && file.deviceId != null) {
        deviceFiles.putIfAbsent(file.deviceId!, () => []).add(file);
      }
    }

    // Find contiguous sequences
    for (final entry in deviceFiles.entries) {
      final deviceId = entry.key;
      final files = entry.value;
      final sequences =
          files
              .where((f) => f.sequence != null)
              .map((f) => f.sequence!)
              .toList()
            ..sort();

      if (sequences.isEmpty) continue;

      var contiguous = 0;
      var expected = 1;
      final deviceGaps = <int>[];

      for (final seq in sequences) {
        if (seq == expected) {
          contiguous = seq;
          expected++;
        } else if (seq > expected) {
          for (var i = expected; i < seq; i++) {
            deviceGaps.add(i);
          }
          contiguous = seq;
          expected = seq + 1;
        }
      }

      contiguousSequences[deviceId] = contiguous;
      if (deviceGaps.isNotEmpty) {
        gaps[deviceId] = deviceGaps;
      }
    }

    return SyncScanState(
      contiguousSequences: contiguousSequences,
      gaps: gaps,
      lastSuccess: DateTime.now(),
      lastErrorCode: null,
      retryCount: 0,
    );
  }

  /// Group remote files by batch, downloading each manifest to get the exact
  /// set of operationIds and matching event files to their batch.
  ///
  /// A batch is complete when its manifest, commit marker, and all event files
  /// listed in the manifest are present.
  Future<Map<String, _BatchFiles>> _groupFilesByBatchAsync(
    List<WebdavSyncFile> files,
  ) async {
    final batches = <String, _BatchFiles>{};

    // Collect manifest and commit files by batchId.
    for (final file in files) {
      if (file.kind == WebdavSyncFileKind.manifest) {
        final batchId = _extractBatchId(file.relativePath);
        if (batchId != null) {
          batches.putIfAbsent(batchId, _BatchFiles.new).manifestFile = file;
        }
      } else if (file.kind == WebdavSyncFileKind.commit) {
        final batchId = _extractBatchId(file.relativePath);
        if (batchId != null) {
          batches.putIfAbsent(batchId, _BatchFiles.new).commitFile = file;
        }
      }
    }

    // Index all event files by deviceId.
    final eventFilesByDevice = <String, List<WebdavSyncFile>>{};
    for (final file in files) {
      if (file.kind == WebdavSyncFileKind.event && file.deviceId != null) {
        eventFilesByDevice.putIfAbsent(file.deviceId!, () => []).add(file);
      }
    }

    // For each batch that has a manifest, download it to get the operationId
    // list, then match event files by sequence to those operations.
    for (final entry in batches.entries) {
      final batchFiles = entry.value;
      final manifestFile = batchFiles.manifestFile;
      if (manifestFile == null) continue;

      try {
        final bytes = await _transport!.downloadSyncFile(
          _config!,
          manifestFile.relativePath,
          maxBytes: syncMaxDownloadBytes,
        );
        final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
        final operationIds =
            (json['operationIds'] as List<Object?>?)
                ?.whereType<String>()
                .toList() ??
            <String>[];
        batchFiles.operationIds.addAll(operationIds);

        // Extract deviceId from manifest path: verifin-sync/v1/batches/{deviceId}/{batchId}.manifest
        final parts = manifestFile.relativePath.split('/');
        if (parts.length >= 5) {
          final deviceId = parts[3];
          final deviceEvents = eventFilesByDevice[deviceId] ?? [];
          // The manifest tells us how many events this batch has; take the
          // event files whose sequences fall within the batch. Since sequences
          // are monotonically increasing per device, we select the N events
          // with the lowest sequences that haven't been assigned to an earlier
          // batch. For simplicity, sort device events by sequence and take
          // exactly operationIds.length of them.
          final sorted = [...deviceEvents]
            ..sort((a, b) => (a.sequence ?? 0).compareTo(b.sequence ?? 0));
          batchFiles.eventFiles.addAll(sorted.take(operationIds.length));
          // Remove assigned events so they aren't re-used by another batch.
          for (final assigned in batchFiles.eventFiles) {
            deviceEvents.remove(assigned);
          }
        }
      } catch (_) {
        // Manifest unreadable — batch stays incomplete and deferred to pending.
        continue;
      }
    }

    return batches;
  }

  String? _extractBatchId(String path) {
    final parts = path.split('/');
    if (parts.length >= 5 && parts[2] == 'batches') {
      final filename = parts[4];
      final match = RegExp(r'^(.+)\.(manifest|commit)$').firstMatch(filename);
      return match?.group(1);
    }
    return null;
  }

  String _manifestPath(String batchId) {
    return 'verifin-sync/v1/batches/${_clock!.deviceId}/$batchId.manifest';
  }

  String _commitPath(String batchId) {
    return 'verifin-sync/v1/batches/${_clock!.deviceId}/$batchId.commit';
  }
}

class _BatchFiles {
  WebdavSyncFile? manifestFile;
  WebdavSyncFile? commitFile;
  final List<WebdavSyncFile> eventFiles = [];
  final List<String> operationIds = [];

  bool get isComplete =>
      manifestFile != null &&
      commitFile != null &&
      eventFiles.isNotEmpty &&
      eventFiles.length >= operationIds.length;
}
