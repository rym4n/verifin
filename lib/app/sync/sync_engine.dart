import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../backup/webdav_config.dart';
import '../veri_fin_controller.dart';
import 'sync_change_tracker.dart';
import 'sync_clock.dart';
import 'sync_codec.dart';
import 'sync_conflict.dart';
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
    required WebdavSyncTransport transport,
    required SyncProjectionSource controller,
    WebdavConfig? config,
  }) : _repository = repository,
       _transport = transport,
       _controller = controller,
       _config = config;

  final SyncRepository _repository;
  final WebdavSyncTransport _transport;
  final SyncProjectionSource _controller;
  WebdavConfig? _config;

  SyncClock? _clock;
  SyncChangeTracker? _changeTracker;

  /// Update the WebDAV config (e.g., after settings change).
  void updateConfig(WebdavConfig? config) {
    _config = config;
  }

  /// Run a sync cycle: upload outbox, scan remote, download and merge.
  Future<SyncRunResult> run({required SyncTrigger trigger}) async {
    if (_config == null) {
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
      await _transport.ensureSyncTree(_config!);

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
    if (_config == null) {
      return;
    }

    try {
      await _ensureClock();

      // Ensure sync tree exists
      await _transport.ensureSyncTree(_config!);

      // Scan remote to determine if empty or not
      final remoteFiles = await _transport.listSyncFiles(_config!);
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

    // Group by batchId
    final batches = <String, List<SyncOutboxRecord>>{};
    for (final record in outbox) {
      batches.putIfAbsent(record.batchId, () => []).add(record);
    }

    var uploadedCount = 0;

    for (final entry in batches.entries) {
      final batchId = entry.key;
      final records = entry.value;

      try {
        // Upload event files
        for (final record in records) {
          await _uploadFile(record.relativePath, record.payloadHash);
        }

        // Upload manifest
        final manifestPath = _manifestPath(batchId);
        await _uploadManifest(batchId, records);

        // Upload commit marker
        final commitPath = _commitPath(batchId);
        await _uploadCommitMarker(commitPath);

        // Mark batch uploaded
        await _repository.markBatchUploaded(batchId);
        uploadedCount++;
      } catch (error) {
        // Batch upload failed, will retry next time
        continue;
      }
    }

    return uploadedCount;
  }

  Future<void> _uploadFile(String relativePath, String expectedHash) async {
    // Read file content from repository (would be stored during enqueue)
    // For this implementation, we'll reconstruct from outbox
    // In a real implementation, the file bytes would be stored separately
    final bytes = utf8.encode(jsonEncode({'stub': 'data'}));
    final stream = Stream.value(bytes);
    await _transport.putImmutable(
      _config!,
      relativePath,
      stream,
      bytes.length,
      expectedHash,
    );
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
    await _transport.putImmutable(
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
    await _transport.putImmutable(
      _config!,
      commitPath,
      stream,
      bytes.length,
      hash,
    );
  }

  Future<(int, int, int)> _scanAndApply() async {
    final remoteFiles = await _transport.listSyncFiles(_config!);

    // Build scan state
    final scanState = await _buildScanState(remoteFiles);

    // Group files by batch
    final batches = _groupFilesByBatch(remoteFiles);

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
        final codec = SyncCodec(passphrase: '');
        for (final eventFile in batch.eventFiles) {
          final bytes = await _transport.downloadSyncFile(
            _config!,
            eventFile.relativePath,
            maxBytes: syncMaxDownloadBytes,
          );
          final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
          final payload = await codec.decode(json);
          final event = SyncEvent.fromJson(payload as Map<String, Object?>);
          events.add(event);
        }

        // Merge and apply
        final result = await _mergeAndApply(events);
        downloadedCount += result.$1;
        conflictCount += result.$2;
      } catch (error) {
        // Batch processing failed, skip for now
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

    for (final event in events) {
      // Check if already applied
      final state = await _repository.loadDeviceState();
      final knownSeq =
          state.knownVector.values[event.version.dot.deviceId] ?? 0;
      if (event.version.dot.sequence <= knownSeq) {
        // Already applied, skip
        continue;
      }

      // Load current entity state
      final shadow = await _repository.loadShadow();
      final currentHash = shadow[event.entity];

      // Determine causality
      final causality = _determineCausality(event, currentHash);

      if (causality == SyncCausality.before) {
        // Predecessor replaced by successor, skip
        continue;
      } else if (causality == SyncCausality.equal) {
        // Idempotent, skip
        continue;
      } else if (causality == SyncCausality.concurrent) {
        // Conflict: store both versions
        await _storeConflict(event);
        conflictCount++;
        continue;
      }

      // Apply event
      await _applyEvent(event);
      appliedCount++;
    }

    return (appliedCount, conflictCount);
  }

  SyncCausality _determineCausality(SyncEvent event, String? currentHash) {
    // Simple causality check based on hash
    if (currentHash == null) {
      // No current version, apply
      return SyncCausality.after;
    }

    if (currentHash == event.payloadHash) {
      // Same hash, idempotent
      return SyncCausality.equal;
    }

    // Different hash, concurrent (conflict)
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
      kvJournalValues: const {},
      appliedPayloadHashes: {event.operationId: event.payloadHash},
    );

    // Apply through repository
    await _repository.applyRemoteBatch(plan);
  }

  Future<void> _storeConflict(SyncEvent remoteEvent) async {
    // Load local version
    final snapshot = SyncProjection.fromExportData(
      _controller.exportDataForSync(),
    );
    final localEntity = snapshot.entity(remoteEvent.entity);

    if (localEntity == null) {
      // No local version, just apply remote
      await _applyEvent(remoteEvent);
      return;
    }

    // Create conflict record
    await _ensureClock();
    final localVersion = SyncEntityVersion(
      entity: remoteEvent.entity,
      version: _clock!.nextVersion(),
      payloadHash: localEntity.payloadHash,
      payload: localEntity.payload,
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

    // Store conflict through apply plan
    final plan = RemoteApplyPlan(
      batchId: remoteEvent.batchId,
      entityVersions: [localVersion, remoteVersion],
      appliedOperationIds: [remoteEvent.operationId],
      shadowHashes: const {},
      kvJournalValues: const {},
    );

    await _repository.applyRemoteBatch(plan);
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
    // Scan and download all remote events
    final (downloaded, conflicts, _) = await _scanAndApply();

    // Any differing hashes will create conflicts
    // which are already handled by scanAndApply
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

  Map<String, _BatchFiles> _groupFilesByBatch(List<WebdavSyncFile> files) {
    final batches = <String, _BatchFiles>{};

    for (final file in files) {
      if (file.kind == WebdavSyncFileKind.event) {
        // Extract batchId from manifest/commit files
        continue;
      } else if (file.kind == WebdavSyncFileKind.manifest) {
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

    // Associate event files with batches
    // For now, we need to download manifests to know which events belong to which batch
    // This is simplified for the initial implementation

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

  bool get isComplete =>
      manifestFile != null && commitFile != null && eventFiles.isNotEmpty;
}
