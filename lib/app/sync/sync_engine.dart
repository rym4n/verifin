// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:convert';
import 'dart:io';
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
import 'sync_ledger_reducer.dart';
import 'sync_schema.dart';
import 'sync_snapshot.dart';
import 'sync_wire.dart';
import 'sync_store.dart';
import 'webdav_snapshot_transport.dart';
import 'webdav_sync_transport.dart';

/// Stable public status codes; exception detail belongs only in local logs.
String syncErrorCode(Object error) {
  final message = error.toString();
  if (error is SyncCodecException) {
    if (message.contains('protocol_version')) return 'protocol';
    return message.contains('fingerprint') ||
            message.contains('passphrase') ||
            message.contains('Passphrase')
        ? 'auth'
        : 'decode';
  }
  if (error is SyncSnapshotException) {
    if (message.contains('fingerprint')) return 'auth';
    if (message.contains('too_large')) return 'size_limit';
    return 'protocol';
  }
  if (error is WebdavFileCollision) return 'protocol';
  if (error is WebdavException) {
    return RegExp(r'\b(401|403)\b').hasMatch(message) ? 'auth' : 'network';
  }
  if (message.contains('outbox_event_missing')) return 'outbox_event_missing';
  if (message.contains('snapshot_sequence_collision') ||
      message.contains('snapshot_')) {
    return message.contains('too_large') ? 'size_limit' : 'protocol';
  }
  if (error is FormatException) {
    if (message.contains('protocol_version') ||
        message.contains('manifest_') ||
        message.contains('commit_')) {
      return 'protocol';
    }
    return message.contains('Invalid sync') ? 'validation' : 'decode';
  }
  if (error is SyncConflictException) return 'validation';
  return 'apply';
}

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

/// Stable phase names used by software logs to locate a sync failure.
enum SyncPhase {
  prepare('prepare'),
  initialize('initialize'),
  reconcile('reconcile'),
  ensureRemote('ensure_remote'),
  upload('upload'),
  download('download');

  const SyncPhase(this.logValue);

  final String logValue;
}

enum SyncPhaseState { start, success, error }

typedef SyncPhaseReporter =
    void Function(SyncPhase phase, SyncPhaseState state, Object? error);

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

class _SyncRunProgress {
  int uploaded = 0;
  int downloaded = 0;
  int conflicts = 0;
  int pending = 0;
}

/// Sync engine: orchestrates upload, download, merge, and conflict resolution.
class SyncEngine {
  SyncEngine({
    required SyncRepository repository,
    WebdavSyncTransport? transport,
    required SyncProjectionSource controller,
    WebdavConfig? config,
    SyncClock? clock,
    String passphrase = '',
    this.wireLimits = const SyncWireLimits(),
    Directory? snapshotTempRoot,
    void Function(Object)? onError,

    /// Wrap remote-apply calls to suppress outbox echo (e.g.,
    /// `VeriFinController.runRemoteApply`). If null, calls applyRemoteBatch
    /// directly — suitable only for tests that don't use a change tracker.
    Future<void> Function(Future<void> Function())? remoteApply,
  }) : _repository = repository,
       _transport = transport,
       _controller = controller,
       _config = config,
       _remoteApply = remoteApply,
       _clock = clock,
       _passphrase = passphrase,
       _snapshotTempRoot = snapshotTempRoot,
       _onError = onError;

  final SyncRepository _repository;
  final SyncWireLimits wireLimits;

  /// 传输层可空：冲突决议（[resolveConflict]）只写本地 outbox，不碰网络。
  /// 决议 UI 因此在没有 WebDAV 配置时也能构造一个仅用于决议的引擎，
  /// 无需为一次纯本地写入先建一个 HTTP 客户端。
  final WebdavSyncTransport? _transport;
  final SyncProjectionSource _controller;
  final Future<void> Function(Future<void> Function())? _remoteApply;
  WebdavConfig? _config;

  SyncClock? _clock;
  String _passphrase;
  final Directory? _snapshotTempRoot;
  final void Function(Object)? _onError;
  void updatePassphrase(String passphrase) {
    _passphrase = passphrase;
  }

  /// Update the WebDAV config (e.g., after settings change).
  void updateConfig(WebdavConfig? config) {
    _config = config;
  }

  /// Enqueue a local batch for upload. The repository persists complete events,
  /// so a later engine instance can resume the upload after process restart.
  Future<void> enqueueBatch(SyncBatchRecord batch) async {
    await _repository.enqueueBatch(batch);
  }

  /// Run a sync cycle: upload outbox, scan remote, download and merge.
  Future<SyncRunResult> run({
    required SyncTrigger trigger,
    SyncPhaseReporter? onPhase,
  }) async {
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

    final progress = _SyncRunProgress();
    try {
      if (await _repository.loadEnrollmentState() == 'enrolling') {
        await initializeFromRestoredData();
        if (await _repository.loadEnrollmentState() == 'enrolling') {
          return SyncRunResult(
            uploaded: 0,
            downloaded: 0,
            conflicts: 0,
            pending: (await _repository.loadPendingBatches()).length,
          );
        }
      }
      // Ensure clock is initialized
      await _ensureClock();

      // Ensure sync tree exists
      await _runPhase(
        SyncPhase.ensureRemote,
        () => transport.ensureSyncTree(_config!),
        onPhase,
      );

      // Upload phase
      progress.uploaded = await _runPhase(
        SyncPhase.upload,
        () => _uploadOutbox(progress),
        onPhase,
      );

      // Download phase
      final scanResult = await _runPhase(
        SyncPhase.download,
        () => _scanAndApply(progress),
        onPhase,
      );
      progress.downloaded = scanResult.$1;
      progress.conflicts = scanResult.$2;
      progress.pending = scanResult.$3;

      return SyncRunResult(
        uploaded: progress.uploaded,
        downloaded: progress.downloaded,
        conflicts: progress.conflicts,
        pending: progress.pending,
      );
    } catch (error) {
      _onError?.call(error);
      return SyncRunResult(
        uploaded: progress.uploaded,
        downloaded: progress.downloaded,
        conflicts: progress.conflicts,
        pending: progress.pending,
        errorCode: syncErrorCode(error),
      );
    }
  }

  /// Snapshot-v2 production flow. The legacy [run] remains available only for
  /// v1 compatibility tests and the read-only migration bridge.
  Future<SyncRunResult> runSnapshot({
    required SyncTrigger trigger,
    SyncPhaseReporter? onPhase,
  }) async {
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
    final progress = _SyncRunProgress();
    try {
      await _ensureClock();
      await _repository.abandonIncompleteSnapshotPublications();
      final gate = await _runPhase(SyncPhase.ensureRemote, () async {
        final listing = await transport.listRoot(_config!);
        final error = await prepareSnapshotCutover(
          legacyTreePresent: listing.legacyTreePresent,
        );
        return (listing, error);
      }, onPhase);
      final rootListing = gate.$1;
      final migrationError = gate.$2;
      if (migrationError != null) {
        return SyncRunResult(
          uploaded: 0,
          downloaded: 0,
          conflicts: (await _repository.loadConflicts()).length,
          pending: (await _repository.loadPendingBatches()).length,
          errorCode: migrationError,
        );
      }

      final rootFiles = rootListing.files;
      final merged = await _runPhase(
        SyncPhase.download,
        () => _mergeSnapshotCandidates(rootFiles),
        onPhase,
      );
      progress.downloaded = merged.$1;
      progress.conflicts = merged.$2;

      final state = await _repository.loadSnapshotState();
      final outbox = await _repository.loadOutbox();
      if (outbox.isNotEmpty || state.lastPublishedSequence == null) {
        progress.uploaded = await _runPhase(
          SyncPhase.upload,
          () => _publishSnapshot(rootFiles),
          onPhase,
        );
      }
      progress.pending = (await _repository.loadPendingBatches()).length;
      return SyncRunResult(
        uploaded: progress.uploaded,
        downloaded: progress.downloaded,
        conflicts: progress.conflicts,
        pending: progress.pending,
      );
    } catch (error) {
      _onError?.call(error);
      return SyncRunResult(
        uploaded: progress.uploaded,
        downloaded: progress.downloaded,
        conflicts: progress.conflicts,
        pending: progress.pending,
        errorCode: syncErrorCode(error),
      );
    }
  }

  Future<(int, int)> _mergeSnapshotCandidates(
    List<WebdavRootFile> rootFiles,
  ) async {
    final localDevice = _clock!.deviceId;
    final byDevice = <String, List<WebdavRootFile>>{};
    for (final file in rootFiles) {
      final name = file.name;
      if (name.isBlob || name.deviceId == localDevice) continue;
      byDevice.putIfAbsent(name.deviceId!, () => []).add(file);
    }
    var downloaded = 0;
    var conflicts = 0;
    for (final entry in byDevice.entries) {
      final hashesBySequence = <int, Set<String>>{};
      for (final file in entry.value) {
        hashesBySequence
            .putIfAbsent(file.name.snapshotSequence!, () => <String>{})
            .add(file.name.fileHash);
      }
      if (hashesBySequence.values.any((hashes) => hashes.length > 1)) {
        throw StateError('snapshot_sequence_collision');
      }
      final cursor = await _repository.loadSnapshotCursor(entry.key);
      final candidates =
          entry.value
              .where(
                (file) =>
                    file.name.snapshotSequence! >
                    (cursor?.lastMergedSequence ?? 0),
              )
              .toList()
            ..sort(
              (left, right) => right.name.snapshotSequence!.compareTo(
                left.name.snapshotSequence!,
              ),
            );
      Object? lastError;
      for (final candidate in candidates) {
        try {
          final downloadedFile = await _transport!.downloadRootFile(
            _config!,
            candidate.name,
            maxBytes: const SyncSnapshotLimits().maxEnvelopeBytes,
          );
          final snapshot = await SyncSnapshotCodec(
            passphrase: _passphrase,
          ).decode(downloadedFile.bytes, source: downloadedFile.name);
          final batchId =
              'snapshot-${snapshot.deviceId}-${snapshot.snapshotSequence}';
          final wireEvents = <SyncEvent>[
            for (final version in snapshot.heads)
              _snapshotVersionEvent(version, batchId, snapshot.keyFingerprint),
            for (final conflict in snapshot.conflicts) ...[
              _snapshotVersionEvent(
                conflict.local,
                batchId,
                snapshot.keyFingerprint,
              ),
              _snapshotVersionEvent(
                conflict.remote,
                batchId,
                snapshot.keyFingerprint,
              ),
            ],
          ];
          final rawBlobs = await _downloadSnapshotBlobs(snapshot, rootFiles);
          late final List<SyncEvent> events;
          try {
            events = <SyncEvent>[
              for (final event in wireEvents)
                await _materializeSnapshotEvent(event, rawBlobs),
            ];
          } finally {
            await rawBlobs.dispose();
          }
          final result = await _mergeAndApply(
            events,
            applyBatchId: batchId,
            allowPartialMergeOnConflict: true,
            cursorAdvance: SnapshotCursorAdvance(
              deviceId: snapshot.deviceId,
              sequence: snapshot.snapshotSequence,
              snapshotHash: candidate.name.fileHash,
              mergedAt: DateTime.now(),
            ),
          );
          downloaded += result.$1;
          conflicts += result.$2;
          lastError = null;
          break;
        } catch (error) {
          lastError = error;
        }
      }
      if (candidates.isNotEmpty && lastError != null) throw lastError;
    }
    return (downloaded, conflicts);
  }

  Future<_SnapshotBlobSession> _downloadSnapshotBlobs(
    SyncSnapshot snapshot,
    List<WebdavRootFile> rootFiles,
  ) async {
    final byHash = <String, SnapshotFileName>{
      for (final file in rootFiles)
        if (file.name.isBlob) file.name.fileHash: file.name,
    };
    final result = await _SnapshotBlobSession.create(_snapshotTempRoot);
    try {
      for (final attachment in snapshot.attachmentBlobs) {
        for (final chunk in attachment.chunks) {
          if (result.contains(chunk.rawHash)) continue;
          final knownMappings = await _repository.loadSnapshotBlobMappings(
            chunk.rawHash,
          );
          final candidates = <String>{
            chunk.fileHash,
            for (final mapping in knownMappings)
              if (mapping.verified) mapping.fileHash,
          }.toList()..sort();
          Object? lastError;
          for (final fileHash in candidates) {
            final name = byHash[fileHash];
            if (name == null) continue;
            try {
              final downloaded = await _transport!.downloadRootFile(
                _config!,
                name,
                maxBytes: wireLimits.maxEnvelopeBytes,
              );
              final envelope = jsonDecode(utf8.decode(downloaded.bytes));
              if (envelope is! Map) {
                throw const FormatException('snapshot_blob_envelope');
              }
              final decoded = await SyncCodec(passphrase: _passphrase)
                  .decodeValue(
                    Map<String, Object?>.from(envelope),
                    expectedProtocolVersion: syncSnapshotProtocolVersion,
                    maxPlaintextBytes: wireLimits.maxEnvelopeBytes,
                  );
              if (decoded is! Map ||
                  decoded['rawHash'] != chunk.rawHash ||
                  decoded['data'] is! String) {
                throw const FormatException('snapshot_blob_mapping');
              }
              final bytes = Uint8List.fromList(
                base64Decode(decoded['data'] as String),
              );
              if (sha256.convert(bytes).toString() != chunk.rawHash) {
                throw const FormatException('snapshot_blob_raw_hash');
              }
              await result.write(chunk.rawHash, bytes);
              await _repository.saveVerifiedBlobMapping(
                SnapshotBlobMapping(
                  rawHash: chunk.rawHash,
                  fileHash: fileHash,
                  rawLength: bytes.length,
                  verified: true,
                  verifiedAt: DateTime.now(),
                  source: 'remote_download',
                ),
              );
              lastError = null;
              break;
            } catch (error) {
              lastError = error;
              if (error is WebdavException) continue;
              await _repository.markSnapshotBlobMappingInvalid(
                chunk.rawHash,
                fileHash,
              );
            }
          }
          if (lastError != null) {
            throw lastError;
          }
        }
      }
      return result;
    } catch (_) {
      await result.dispose();
      rethrow;
    }
  }

  Future<SyncEvent> _materializeSnapshotEvent(
    SyncEvent event,
    _SnapshotBlobSession blobs,
  ) async {
    if (event.entity.type != 'attachments' ||
        event.operation == SyncOperationKind.delete ||
        event.payload is! Map ||
        !(event.payload as Map).containsKey('blobChunks')) {
      return event;
    }
    final hashes = ((event.payload as Map)['blobChunks'] as List)
        .cast<String>();
    final chunks = <String, Uint8List>{};
    for (final hash in hashes) {
      chunks[hash] = await blobs.read(hash);
    }
    return materializeSyncEvent(event, chunks, limits: wireLimits);
  }

  SyncEvent _snapshotVersionEvent(
    SyncEntityVersion version,
    String batchId,
    String keyFingerprint,
  ) => SyncEvent(
    protocolVersion: syncProtocolVersion,
    operationId: version.operationId,
    version: version.version,
    entity: version.entity,
    operation: version.deleted
        ? SyncOperationKind.delete
        : SyncOperationKind.upsert,
    payloadHash: version.payloadHash,
    payload: version.payload,
    batchId: batchId,
    keyFingerprint: keyFingerprint,
  );

  Future<int> _publishSnapshot(List<WebdavRootFile> rootFiles) async {
    final prepared = await _repository.prepareSnapshotPublication();
    final batchId = 'snapshot-${prepared.publication.sequence}';
    final originalEvents = <SyncEvent>[
      for (final version in prepared.heads)
        _snapshotVersionEvent(version, batchId, 'local'),
    ];
    final rawBlobs = syncAttachmentBlobs(originalEvents, limits: wireLimits);
    final existingRootHashes = <String>{
      for (final file in rootFiles)
        if (file.name.isBlob) file.name.fileHash,
    };
    final selectedMappings = <String, SnapshotBlobMapping>{};
    for (final raw in rawBlobs.entries) {
      final persisted = await _repository.loadVerifiedBlobMappings(raw.key);
      final reusable = persisted
          .where((mapping) => existingRootHashes.contains(mapping.fileHash))
          .firstOrNull;
      if (reusable != null) {
        selectedMappings[raw.key] = reusable;
        continue;
      }
      final envelope = await SyncCodec(passphrase: _passphrase).encodeValue(
        <String, Object?>{'rawHash': raw.key, 'data': base64Encode(raw.value)},
        syncSnapshotProtocolVersion,
      );
      final bytes = Uint8List.fromList(
        utf8.encode(canonicalSyncJson(envelope)),
      );
      if (bytes.length > wireLimits.maxEnvelopeBytes) {
        throw const FormatException('snapshot_blob_too_large');
      }
      final mapping = SnapshotBlobMapping(
        rawHash: raw.key,
        fileHash: sha256.convert(bytes).toString(),
        rawLength: raw.value.length,
        verified: true,
        verifiedAt: DateTime.now(),
        source: 'local_upload',
      );
      await _transport!.putBlob(
        _config!,
        SnapshotFileName.blob(fileHash: mapping.fileHash),
        Stream.value(bytes),
        bytes.length,
      );
      await _repository.saveVerifiedBlobMapping(mapping);
      selectedMappings[raw.key] = mapping;
      existingRootHashes.add(mapping.fileHash);
    }
    await _repository.freezeSnapshotBlobMembers(
      prepared.publication.sequence,
      selectedMappings.values.toList(),
    );
    final deviceState = await _repository.loadDeviceState();
    final codec = SyncSnapshotCodec(passphrase: _passphrase);
    final createdAt = DateTime.fromMillisecondsSinceEpoch(
      DateTime.now().toUtc().millisecondsSinceEpoch,
      isUtc: true,
    );
    final attachmentBlobs = <SyncSnapshotAttachmentBlob>[];
    for (final event in originalEvents) {
      final wire = syncEventForWire(event, limits: wireLimits);
      if (wire.entity.type != 'attachments' ||
          wire.operation == SyncOperationKind.delete) {
        continue;
      }
      final payload = Map<String, Object?>.from(wire.payload as Map);
      attachmentBlobs.add(
        SyncSnapshotAttachmentBlob(
          attachmentId: wire.entity.id,
          byteLength: payload['byteLength'] as int,
          dataUrlPrefix: payload['dataUrlPrefix'] as String,
          chunks: [
            for (final rawHash
                in (payload['blobChunks'] as List).cast<String>())
              SyncSnapshotBlobRef(
                rawHash: rawHash,
                fileHash: selectedMappings[rawHash]!.fileHash,
              ),
          ],
        ),
      );
    }
    final snapshot = SyncSnapshot.fromProjection(
      deviceId: deviceState.deviceId,
      snapshotSequence: prepared.publication.sequence,
      createdAtUtc: createdAt,
      keyFingerprint: SyncCodec(passphrase: _passphrase).keyFingerprint,
      knownVector: deviceState.knownVector,
      events: originalEvents,
      attachmentBlobs: attachmentBlobs,
      conflicts: prepared.conflicts,
    );
    final bytes = await codec.encode(snapshot);
    final name = SnapshotFileName.snapshot(
      deviceId: deviceState.deviceId,
      snapshotSequence: prepared.publication.sequence,
      createdAtUtc: snapshot.createdAtUtc,
      fileHash: sha256.convert(bytes).toString(),
    );
    await _transport!.putSnapshot(
      _config!,
      name,
      Stream.value(bytes),
      bytes.length,
    );
    final migration = await _repository.loadSnapshotState();
    if (migration.v1MigrationState == V1MigrationState.readyToCutover) {
      await _repository.completeV1CutoverWithPublication(
        prepared.publication.sequence,
        filename: name.toString(),
        snapshotHash: name.fileHash,
      );
    } else {
      await _repository.markSnapshotPublished(
        prepared.publication.sequence,
        filename: name.toString(),
        snapshotHash: name.fileHash,
      );
    }
    await _cleanupLocalSnapshots(rootFiles, deviceState.deviceId);
    return 1;
  }

  Future<void> _cleanupLocalSnapshots(
    List<WebdavRootFile> rootFiles,
    String localDevice,
  ) async {
    final snapshots =
        rootFiles
            .where(
              (file) => !file.name.isBlob && file.name.deviceId == localDevice,
            )
            .toList()
          ..sort(
            (left, right) => right.name.snapshotSequence!.compareTo(
              left.name.snapshotSequence!,
            ),
          );
    for (final file in snapshots.skip(2)) {
      try {
        await _transport!.deleteSnapshot(_config!, file.name);
      } catch (_) {
        // Snapshot publication already succeeded; cleanup is best effort.
      }
    }
  }

  Future<T> _runPhase<T>(
    SyncPhase phase,
    Future<T> Function() action,
    SyncPhaseReporter? reporter,
  ) async {
    reporter?.call(phase, SyncPhaseState.start, null);
    try {
      final result = await action();
      reporter?.call(phase, SyncPhaseState.success, null);
      return result;
    } catch (error) {
      reporter?.call(phase, SyncPhaseState.error, error);
      rethrow;
    }
  }

  /// Read-only v1 migration/bridge gate run before any snapshot-v2 work.
  ///
  /// Returns a stable blocking code while the user still needs to upgrade or
  /// stop legacy clients. A null result means snapshot-v2 work may continue.
  Future<String?> prepareSnapshotCutover({bool? legacyTreePresent}) async {
    final transport = _transport;
    if (_config == null || transport == null) return 'no_config';

    final state = await _repository.loadSnapshotState();
    if (legacyTreePresent == false &&
        state.v1LastSeenFingerprint == null &&
        state.v1MigrationState == V1MigrationState.notStarted) {
      await _repository.markV1MigrationNotRequired();
      return null;
    }
    if (legacyTreePresent == false &&
        state.v1LastSeenFingerprint == null &&
        state.v1MigrationState == V1MigrationState.cutoverComplete) {
      return null;
    }
    final remoteFiles = await transport.listSyncFiles(_config!);
    final batches = await _groupFilesByBatchAsync(remoteFiles);
    final complete = _causalBatchOrder(
      batches.values.where((batch) => batch.isComplete),
    );
    final fingerprint = _v1Fingerprint(complete);

    var migrationConflict = false;
    for (final batch in complete) {
      final result = await _mergeAndApply(
        batch.events,
        applyBatchId: batch.batchId,
      );
      if (result.$2 > 0) {
        migrationConflict = true;
        await _repository.savePendingBatch(
          batch.batchId,
          batch.events,
          'conflict',
        );
      } else {
        await _repository.removePendingBatch(batch.batchId);
      }
    }

    if (fingerprint == null) {
      if (state.v1MigrationState == V1MigrationState.notStarted) {
        await _repository.markV1MigrationNotRequired();
        return null;
      }
      return state.v1MigrationState == V1MigrationState.needsUpgradeConfirmation
          ? 'legacy_client_upgrade_required'
          : null;
    }

    switch (state.v1MigrationState) {
      case V1MigrationState.notStarted:
        await _repository.recordV1Scan(
          v1HistoryFound: true,
          fingerprint: fingerprint,
        );
        return 'legacy_client_upgrade_required';
      case V1MigrationState.needsUpgradeConfirmation:
        if (state.v1LastSeenFingerprint != fingerprint) {
          await _repository.recordV1Scan(
            v1HistoryFound: true,
            fingerprint: fingerprint,
          );
        }
        return 'legacy_client_upgrade_required';
      case V1MigrationState.readyToCutover:
        if (migrationConflict) return 'legacy_client_upgrade_required';
        if (state.v1LastSeenFingerprint == fingerprint) return null;
        await _repository.recordV1Scan(
          v1HistoryFound: true,
          fingerprint: fingerprint,
        );
        return 'legacy_client_upgrade_required';
      case V1MigrationState.cutoverComplete:
        if (migrationConflict) return 'legacy_client_upgrade_required';
        if (state.v1LastSeenFingerprint == fingerprint) return null;
        await _repository.recordV1Scan(
          v1HistoryFound: true,
          fingerprint: fingerprint,
        );
        return 'legacy_client_upgrade_required';
    }
  }

  static String? _v1Fingerprint(List<_BatchFiles> batches) {
    if (batches.isEmpty) return null;
    final maxima = <String, int>{};
    for (final batch in batches) {
      for (final event in batch.events) {
        final device = event.version.dot.deviceId;
        final sequence = event.version.dot.sequence;
        if (sequence > (maxima[device] ?? 0)) maxima[device] = sequence;
      }
    }
    final ordered = maxima.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    return computeSyncPayloadHash(<String, int>{
      for (final entry in ordered) entry.key: entry.value,
    });
  }

  /// Initialize from restored data: baseline or join-conflict flow.
  Future<void> initializeFromRestoredData() async {
    final transport = _transport;
    if (_config == null || transport == null) {
      return;
    }

    final enrollment = await _repository.loadEnrollmentState();
    final scan = await _repository.loadScanState();
    if (enrollment == 'enrolled' ||
        (enrollment == null && scan.lastSuccess != null)) {
      return;
    }
    await _repository.saveEnrollmentState('enrolling');
    await _ensureClock();

    // Ensure sync tree exists
    await transport.ensureSyncTree(_config!);

    // Scan remote to determine if empty or not
    final remoteFiles = await transport.listSyncFiles(_config!);
    final hasRemoteHistory = remoteFiles.any(
      (f) => f.kind != WebdavSyncFileKind.blob,
    );

    if (!hasRemoteHistory) {
      // Empty remote: create baseline batch
      await _createBaselineBatch();
    } else {
      // Non-empty remote: join-conflict flow
      if (!await _joinConflictFlow(remoteFiles)) return;
    }

    // Save shadow from current state
    final snapshot = SyncProjection.fromExportData(
      _controller.exportDataForSync(),
    );
    await _repository.saveShadow(snapshot.payloadHashes);

    // Save scan state
    if (!hasRemoteHistory) {
      await _repository.saveScanState(await _buildScanState(const []));
    }
    await _repository.saveEnrollmentState('enrolled');
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
    final target = _controller;
    if (target is SyncRemoteApplyTarget) {
      return (target as SyncRemoteApplyTarget).runSyncRemoteMerge(
        () => _resolveConflictUnderGate(conflictId, resolution),
        resolving: true,
      );
    }
    return _resolveConflictUnderGate(conflictId, resolution);
  }

  Future<void> _resolveConflictUnderGate(
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
    final merged = conflict.local.version.context
        .merged(
          SyncVersionVector({
            conflict.local.version.dot.deviceId:
                conflict.local.version.dot.sequence,
          }),
        )
        .merged(conflict.remote.version.context)
        .merged(
          SyncVersionVector({
            conflict.remote.version.dot.deviceId:
                conflict.remote.version.dot.sequence,
          }),
        );
    _clock!.restoreState(
      SyncDeviceState(
        deviceId: _clock!.deviceId,
        nextSequence: _clock!.nextSequence,
        knownVector: merged,
      ),
    );
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

    final pending = await _repository.loadPendingBatches();
    Future<void> reserveSequence() async {
      final persisted = await _repository.loadDeviceState();
      await _repository.saveDeviceState(
        SyncDeviceState(
          deviceId: _clock!.deviceId,
          nextSequence: _clock!.nextSequence,
          knownVector: persisted.knownVector,
        ),
      );
    }

    pending.sort(
      (a, b) => (a.reason == 'join_conflict' ? 0 : 1).compareTo(
        b.reason == 'join_conflict' ? 0 : 1,
      ),
    );
    final aggregate = pending
        .where(
          (batch) => batch.events.any(
            (e) => e.operationId == conflict.remote.operationId,
          ),
        )
        .firstOrNull;
    final candidates =
        aggregate?.events ??
        [
          SyncEvent(
            protocolVersion: syncProtocolVersion,
            operationId: conflict.remote.operationId,
            version: conflict.remote.version,
            entity: conflict.entity,
            operation: conflict.remote.deleted
                ? SyncOperationKind.delete
                : SyncOperationKind.upsert,
            payloadHash: conflict.remote.payloadHash,
            payload: conflict.remote.payload,
            batchId: batchId,
            keyFingerprint: 'local',
          ),
        ];
    final latestHeads = await _repository.loadEntityHeads(
      candidates.map((e) => e.entity).toSet(),
    );
    final invalidChoices = <String>{};
    final supersededIds = <String>{};
    var selectedStale = false;
    for (final original in candidates) {
      final head = latestHeads[original.entity];
      final existing = conflicts
          .where((c) => c.remote.operationId == original.operationId)
          .firstOrNull;
      if (existing == null &&
          head != null &&
          _determineCausality(original, head.payloadHash, head) ==
              SyncCausality.before) {
        supersededIds.add(original.operationId);
        continue;
      }
      final changed =
          existing != null &&
          head != null &&
          (head.payloadHash != existing.local.payloadHash ||
              head.deleted != existing.local.deleted);
      final newlyConcurrent =
          existing == null &&
          _determineCausality(original, head?.payloadHash, head) ==
              SyncCausality.concurrent;
      final choice = existing == null ? null : aggregate?.choices[existing.id];
      final choiceStale =
          choice != null &&
          head != null &&
          ![
            SyncCausality.after,
            SyncCausality.equal,
          ].contains(choice.version.context.compare(_fullVector(head.version)));
      if (changed || newlyConcurrent || choiceStale) {
        final refreshed = await _buildConflict(original, localOverride: head);
        await _repository.storeConflict(refreshed);
        conflicts.removeWhere((c) => c.id == refreshed.id);
        conflicts.add(refreshed);
        invalidChoices.add(refreshed.id);
        if (refreshed.id == conflictId) selectedStale = true;
        if (aggregate != null) {
          await _repository.saveConflictChoice(
            aggregate.batchId,
            refreshed.id,
            null,
          );
        }
      }
    }
    if (selectedStale) return;
    final choices = <String, SyncEvent>{
      for (final item
          in aggregate?.choices.entries ??
              const <MapEntry<String, SyncEvent>>[])
        if (!invalidChoices.contains(item.key)) item.key: item.value,
      conflictId: event,
    };
    final aggregateConflicts = aggregate == null
        ? [conflict]
        : conflicts
              .where(
                (c) => aggregate.events.any(
                  (e) => e.operationId == c.remote.operationId,
                ),
              )
              .toList();
    if (aggregate != null &&
        aggregateConflicts.any((c) => !choices.containsKey(c.id))) {
      final tentative = [
        for (final original in aggregate.events)
          if (!supersededIds.contains(original.operationId))
            choices.values
                    .where((e) => e.entity == original.entity)
                    .firstOrNull ??
                original,
      ];
      SyncLedgerReducer.parse(
        SyncProjection.applyVersions(_controller.exportDataForSync(), [
          for (final e in tentative)
            SyncEntityVersion(
              entity: e.entity,
              version: e.version,
              payloadHash: e.payloadHash,
              payload: e.payload,
              deleted: e.operation == SyncOperationKind.delete,
              operationId: e.operationId,
            ),
        ]),
      );
      await reserveSequence();
      await _repository.saveConflictChoice(
        aggregate.batchId,
        conflictId,
        event,
      );
      return;
    }
    final resolutionEvents = [
      for (final choice in choices.values)
        SyncEvent(
          protocolVersion: choice.protocolVersion,
          operationId: choice.operationId,
          version: choice.version,
          entity: choice.entity,
          operation: choice.operation,
          payloadHash: choice.payloadHash,
          payload: choice.payload,
          batchId: batchId,
          keyFingerprint: choice.keyFingerprint,
        ),
    ];
    final resolvedEvents = <SyncEvent>[
      if (aggregate != null)
        for (final prior in aggregate.events)
          if (!supersededIds.contains(prior.operationId) &&
              !resolutionEvents.any((e) => e.entity == prior.entity))
            prior,
      ...resolutionEvents,
    ];
    final target = _controller;
    Future<void> commit() async {
      final data =
          SyncProjection.applyVersions(_controller.exportDataForSync(), [
            for (final e in resolvedEvents)
              SyncEntityVersion(
                entity: e.entity,
                version: e.version,
                payloadHash: e.payloadHash,
                payload: e.payload,
                deleted: e.operation == SyncOperationKind.delete,
                operationId: e.operationId,
              ),
          ]);
      SyncLedgerReducer.parse(data);
      await reserveSequence();
      await _applyEvents(
        resolvedEvents,
        batchId: batchId,
        resolutionEvents: resolutionEvents,
        acknowledgedEvents: [
          for (final e in candidates)
            if (supersededIds.contains(e.operationId)) e,
        ],
        resolvedConflictIds: choices.keys.toList(),
        completedPendingIds: [
          if (aggregate != null) ...{
            aggregate.batchId,
            ...aggregate.events.map((e) => e.batchId),
            if (aggregate.reason == 'join_conflict')
              ...pending
                  .where((p) => p.reason == 'join_dependency')
                  .map((p) => p.batchId),
          },
        ],
      );
    }

    if (target is SyncRemoteApplyTarget) {
      await (target as SyncRemoteApplyTarget).runSyncRemoteMerge(commit);
    } else {
      await commit();
    }
  }

  Future<void> _ensureClock() async {
    final state = await _repository.loadDeviceState();
    if (_clock != null) {
      if (state.deviceId.isEmpty) {
        await _repository.saveDeviceState(_clock!.getState());
      } else {
        _clock!.restoreState(state);
      }
      return;
    }
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

  Future<int> _uploadOutbox([_SyncRunProgress? progress]) async {
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
    Object? lastUploadError;
    final codec = SyncCodec(passphrase: _passphrase);
    final existingFiles = {
      for (final file in await _transport!.listSyncFiles(_config!))
        _canonicalPath(file.relativePath): file,
    };

    for (final entry in batches.entries) {
      final batchId = entry.key;
      final records = entry.value;

      try {
        final devices = records
            .map((r) => r.event?.version.dot.deviceId)
            .toSet();
        if (devices.length != 1 || devices.single == null) {
          throw StateError('outbox_event_missing_or_mixed_device');
        }
        final batchDevice = devices.single!;
        final wireEvents = <SyncEvent>[];
        final legacyInlineOperationIds = <String>{};
        // Re-encode durable outbox events and upload them before the manifest.
        for (final record in records) {
          final existing = existingFiles[_canonicalPath(record.relativePath)];
          final Uint8List eventBytes;
          if (existing != null) {
            eventBytes = await _transport.downloadSyncFile(
              _config!,
              existing.relativePath,
              maxBytes: wireLimits.maxEnvelopeBytes,
            );
            final existingEvent = await _decodeEvent(eventBytes);
            if (existingEvent != record.event &&
                existingEvent !=
                    syncEventForWire(record.event!, limits: wireLimits)) {
              throw const WebdavFileCollision(
                'sync_event_collision',
                diagnostic: WebdavDiagnostic(
                  method: 'GET',
                  operation: 'inspect_existing',
                  fileKind: 'event',
                  statusCode: 200,
                  reason: 'file_collision',
                ),
              );
            }
            wireEvents.add(existingEvent);
            if (existingEvent.entity.type == 'attachments' &&
                existingEvent.payload is Map &&
                (existingEvent.payload as Map).containsKey('dataUrl')) {
              legacyInlineOperationIds.add(existingEvent.operationId);
            }
          } else {
            eventBytes = await _encodeEventForUpload(record, codec);
            wireEvents.add(syncEventForWire(record.event!, limits: wireLimits));
          }
          final hash = sha256.convert(eventBytes).toString();
          await _transport.putImmutable(
            _config!,
            'verifin-sync/v1/${_canonicalPath(record.relativePath)}',
            Stream.value(eventBytes),
            eventBytes.length,
            hash,
          );
        }

        // Upload manifest.
        final events = records.map((r) => r.event!).toList();
        for (final blob in syncAttachmentBlobs(
          events,
          limits: wireLimits,
          legacyInlineOperationIds: legacyInlineOperationIds,
        ).entries) {
          await _putDocument('verifin-sync/v1/blobs/${blob.key}.blob', {
            'protocolVersion': syncProtocolVersion,
            'hash': blob.key,
            'data': base64Encode(blob.value),
          });
        }
        final manifest = syncManifest(
          batchId,
          wireEvents,
          limits: wireLimits,
          eventsAreWire: true,
        );
        final manifestBytes = await _putDocument(
          _manifestPath(batchId, batchDevice),
          manifest,
        );

        // Upload commit marker — only after manifest succeeds.
        final commitPath = _commitPath(batchId, batchDevice);
        final commitBytes = syncJsonBytes(syncCommit(manifest, manifestBytes));
        await _transport.putImmutable(
          _config!,
          commitPath,
          Stream.value(commitBytes),
          commitBytes.length,
          sha256.convert(commitBytes).toString(),
        );

        // Mark batch uploaded only after commit succeeds.
        await _repository.markBatchUploaded(batchId);
        uploadedCount++;
        progress?.uploaded = uploadedCount;
      } catch (error) {
        // Record error for propagation; continue trying remaining batches.
        lastUploadError = error;
        continue;
      }
    }

    // Surface the upload error through run() so callers can inspect it.
    if (lastUploadError != null) {
      throw lastUploadError;
    }

    return uploadedCount;
  }

  Future<Uint8List> _encodeEventForUpload(
    SyncOutboxRecord record,
    SyncCodec codec,
  ) async {
    if (record.event == null) throw StateError('outbox_event_missing');
    final event = syncEventForWire(record.event!, limits: wireLimits);
    final bytes = syncJsonBytes(
      _passphrase.isEmpty
          ? event.toJson()
          : await codec.encodeValue(event.toJson(), syncProtocolVersion),
    );
    if (bytes.length > wireLimits.maxEnvelopeBytes) {
      throw const FormatException('Invalid sync envelope size');
    }
    return bytes;
  }

  Future<SyncEvent> _decodeEvent(Uint8List bytes) async {
    final json = Map<String, Object?>.from(
      jsonDecode(utf8.decode(bytes)) as Map,
    );
    if (json['protocolVersion'] != syncProtocolVersion) {
      throw const SyncCodecException('protocol_version');
    }
    if (json.containsKey('operationId')) {
      if (_passphrase.isNotEmpty) {
        throw const SyncCodecException('Passphrase plaintext forbidden');
      }
      return SyncEvent.fromJson(json);
    }
    final payload = await SyncCodec(passphrase: _passphrase).decode(json);
    if (payload is! Map) {
      throw const FormatException('sync_event_missing_metadata');
    }
    if (payload['protocolVersion'] != syncProtocolVersion) {
      throw const SyncCodecException('protocol_version');
    }
    return SyncEvent.fromJson(Map<String, Object?>.from(payload));
  }

  static String _canonicalPath(String path) =>
      path.startsWith('verifin-sync/v1/')
      ? path.substring('verifin-sync/v1/'.length)
      : path;

  Future<Map<String, Object?>> _decodeDocument(Uint8List bytes) async {
    final raw = Map<String, Object?>.from(
      jsonDecode(utf8.decode(bytes)) as Map,
    );
    if (raw['protocolVersion'] != syncProtocolVersion) {
      throw const SyncCodecException('protocol_version');
    }
    if (raw.containsKey('ciphertext')) {
      final value = await SyncCodec(passphrase: _passphrase).decode(raw);
      if (value is! Map) throw const FormatException('Invalid sync document');
      if (value['protocolVersion'] != syncProtocolVersion) {
        throw const SyncCodecException('protocol_version');
      }
      return Map<String, Object?>.from(value);
    }
    if (_passphrase.isNotEmpty) {
      throw const SyncCodecException('Passphrase plaintext forbidden');
    }
    return raw;
  }

  Future<Uint8List> _putDocument(
    String path,
    Map<String, Object?> document,
  ) async {
    final files = await _transport!.listSyncFiles(_config!);
    final existing = files
        .where((f) => _canonicalPath(f.relativePath) == _canonicalPath(path))
        .firstOrNull;
    if (existing != null) {
      final bytes = await _transport.downloadSyncFile(
        _config!,
        existing.relativePath,
        maxBytes: wireLimits.maxEnvelopeBytes,
      );
      if (computeSyncPayloadHash(await _decodeDocument(bytes)) !=
          computeSyncPayloadHash(document)) {
        throw WebdavFileCollision(
          'sync_document_collision',
          diagnostic: WebdavDiagnostic(
            method: 'GET',
            operation: 'inspect_existing',
            fileKind: _fileKindFromSyncPath(path),
            statusCode: 200,
            reason: 'file_collision',
          ),
        );
      }
      return bytes;
    }
    final bytes = syncJsonBytes(
      _passphrase.isEmpty
          ? document
          : await SyncCodec(
              passphrase: _passphrase,
            ).encodeValue(document, syncProtocolVersion),
    );
    if (bytes.length > wireLimits.maxEnvelopeBytes) {
      throw const FormatException('Invalid sync envelope size');
    }
    await _transport.putImmutable(
      _config!,
      path,
      Stream.value(bytes),
      bytes.length,
      sha256.convert(bytes).toString(),
    );
    return bytes;
  }

  static String _fileKindFromSyncPath(String path) {
    if (path.endsWith('.vfsync')) return 'event';
    if (path.endsWith('.manifest')) return 'manifest';
    if (path.endsWith('.commit')) return 'commit';
    if (path.endsWith('.blob')) return 'blob';
    return 'tree';
  }

  Future<(int, int, int)> _scanAndApply([_SyncRunProgress? progress]) async {
    final joins = (await _repository.loadPendingBatches())
        .where((p) => p.reason == 'join_conflict' || p.reason == 'join_ready')
        .toList();
    for (final join in joins.where((p) => p.reason == 'join_ready')) {
      final result = await _mergeAndApply(
        join.events,
        applyBatchId: join.batchId,
      );
      if (result.$2 > 0) {
        await _repository.savePendingBatch(
          join.batchId,
          join.events,
          'join_conflict',
        );
      } else {
        await _repository.removePendingBatch(join.batchId);
      }
    }
    final remainingJoins = (await _repository.loadPendingBatches())
        .where((p) => p.reason == 'join_conflict' || p.reason == 'join_ready')
        .length;
    if (remainingJoins > 0) {
      final conflictCount = (await _repository.loadConflicts()).length;
      if (progress != null) {
        progress.conflicts = conflictCount;
        progress.pending = remainingJoins;
      }
      return (0, conflictCount, remainingJoins);
    }
    final transport = _transport!;
    final remoteFiles = await transport.listSyncFiles(_config!);

    // Group files by batch — downloads each manifest to match events correctly.
    final batches = await _groupFilesByBatchAsync(remoteFiles);

    var downloadedCount = 0;
    var conflictCount = 0;
    var pendingCount = 0;
    var invalidReferences = false;
    final completedFiles = <WebdavSyncFile>[];

    void captureProgress() {
      if (progress == null) return;
      progress.downloaded = downloadedCount;
      progress.conflicts = conflictCount;
      progress.pending = pendingCount;
    }

    for (final batch in _causalBatchOrder(batches.values)) {
      if (!batch.isComplete) {
        pendingCount++;
        await _repository.savePendingBatch(
          batch.batchId,
          batch.events,
          batch.missingBlobs
              ? 'missing_blob'
              : batch.manifestFile == null
              ? 'missing_manifest'
              : batch.commitFile == null
              ? 'missing_commit'
              : 'missing_event',
        );
        captureProgress();
        continue;
      }

      try {
        await _repository.savePendingBatch(
          batch.batchId,
          batch.events,
          'ready',
        );
        // Download and decode events
        // Merge and apply
        final result = await _mergeAndApply(batch.events);
        downloadedCount += result.$1;
        conflictCount += result.$2;
        captureProgress();
        if (result.$2 > 0) {
          await _repository.savePendingBatch(
            batch.batchId,
            batch.events,
            'conflict',
          );
          pendingCount++;
          captureProgress();
        } else {
          final prepared = (await _repository.loadPendingBatches()).any(
            (p) => p.batchId == batch.batchId && p.reason == 'prepared',
          );
          if (prepared) {
            pendingCount++;
            captureProgress();
          } else {
            completedFiles.addAll(batch.eventFiles);
            await _repository.removePendingBatch(batch.batchId);
          }
        }
      } catch (error) {
        if (error is FormatException &&
            error.message.startsWith('Invalid sync')) {
          await _repository.savePendingBatch(
            batch.batchId,
            batch.events,
            'invalid_reference',
          );
          invalidReferences = true;
          pendingCount++;
          captureProgress();
          continue;
        }
        rethrow;
      }
    }

    // Save scan state
    if (invalidReferences) {
      throw const FormatException('Invalid sync pending references');
    }
    pendingCount = max(
      pendingCount,
      (await _repository.loadPendingBatches()).length,
    );
    captureProgress();
    if (pendingCount == 0) {
      await _repository.saveScanState(await _buildScanState(completedFiles));
    }

    return (downloadedCount, conflictCount, pendingCount);
  }

  Future<(int, int)> _mergeAndApply(
    List<SyncEvent> events, {
    String? applyBatchId,
    bool allowPartialMergeOnConflict = false,
    SnapshotCursorAdvance? cursorAdvance,
  }) async {
    for (final event in events) {
      if (event.operation != SyncOperationKind.delete) {
        SyncSchema.validateIncoming(event.entity.type, event.payload);
      }
    }
    final target = _controller;
    if (target is SyncRemoteApplyTarget) {
      return (target as SyncRemoteApplyTarget).runSyncRemoteMerge(
        () => _mergeUnderGate(
          events,
          applyBatchId: applyBatchId,
          allowPartialMergeOnConflict: allowPartialMergeOnConflict,
          cursorAdvance: cursorAdvance,
        ),
      );
    }
    return _mergeUnderGate(
      events,
      applyBatchId: applyBatchId,
      allowPartialMergeOnConflict: allowPartialMergeOnConflict,
      cursorAdvance: cursorAdvance,
    );
  }

  Future<(int, int)> _mergeUnderGate(
    List<SyncEvent> events, {
    String? applyBatchId,
    required bool allowPartialMergeOnConflict,
    SnapshotCursorAdvance? cursorAdvance,
  }) async {
    final heads = await _repository.loadEntityHeads(
      events.map((e) => e.entity).toSet(),
    );
    final shadow = await _repository.loadShadow();
    final applied = await _repository.loadAppliedOperationHashes(
      events.map((e) => e.operationId).toList(),
    );
    final accepted = <SyncEvent>[];
    final superseded = <SyncEvent>[];
    final conflicts = <SyncConflictRecord>[];
    for (final event in events) {
      // A maximum observed sequence is not proof that a lower gap was applied.
      final priorHash = applied[event.operationId];
      if (priorHash != null) {
        if (priorHash != event.payloadHash) {
          throw const SyncConflictException('operation_payload_collision');
        }
        continue;
      }

      final currentHash =
          heads[event.entity]?.payloadHash ?? shadow[event.entity];

      final causality = _determineCausality(
        event,
        currentHash,
        heads[event.entity],
      );

      if (causality == SyncCausality.before) {
        superseded.add(event);
        continue;
      } else if (causality == SyncCausality.equal) {
        accepted.add(event);
        continue;
      } else if (causality == SyncCausality.concurrent) {
        conflicts.add(
          await _buildConflict(event, localOverride: heads[event.entity]),
        );
        continue;
      }

      // SyncCausality.after — incoming causally follows what we know.
      accepted.add(event);
      heads[event.entity] = SyncEntityVersion(
        entity: event.entity,
        version: event.version,
        payloadHash: event.payloadHash,
        payload: event.payload,
        deleted: event.operation == SyncOperationKind.delete,
        operationId: event.operationId,
      );
    }
    if (conflicts.isNotEmpty && !allowPartialMergeOnConflict) {
      // Legacy v1 batches are atomic: a conflict keeps the complete batch
      // pending so a later retry cannot acknowledge only part of it.
      await _applyEvents(
        const [],
        conflicts: conflicts,
        batchId: applyBatchId ?? events.first.batchId,
      );
    } else if (conflicts.isNotEmpty) {
      await _applyEvents(
        accepted,
        acknowledgedEvents: superseded,
        conflicts: conflicts,
        batchId: applyBatchId ?? events.first.batchId,
        cursorAdvance: cursorAdvance,
      );
    } else if (accepted.isNotEmpty || superseded.isNotEmpty) {
      await _applyEvents(
        accepted,
        acknowledgedEvents: superseded,
        conflicts: conflicts,
        batchId: applyBatchId ?? events.first.batchId,
        cursorAdvance: cursorAdvance,
      );
    } else if (cursorAdvance != null) {
      await _applyEvents(
        const [],
        batchId: applyBatchId ?? events.first.batchId,
        cursorAdvance: cursorAdvance,
      );
    }
    return (
      conflicts.isNotEmpty && !allowPartialMergeOnConflict
          ? 0
          : accepted.where((e) => shadow[e.entity] != e.payloadHash).length,
      conflicts.length,
    );
  }

  SyncCausality _determineCausality(
    SyncEvent event,
    String? currentHash,
    SyncEntityVersion? head,
  ) {
    if (head != null) {
      final incoming = _fullVector(event.version);
      final existing = _fullVector(head.version);
      if (incoming.compare(existing) == SyncCausality.before) {
        return SyncCausality.before;
      }
      if (head.payloadHash == event.payloadHash) return SyncCausality.equal;
      return incoming.compare(existing);
    }
    if (currentHash == null) {
      // No current entity — incoming is definitely new.
      return SyncCausality.after;
    }
    if (currentHash == event.payloadHash) {
      // Same payload already applied — idempotent.
      return SyncCausality.equal;
    }

    // A restored local entity with no version is a first-join candidate.
    // Remote history cannot establish causality with that local state.
    return SyncCausality.concurrent;
  }

  static SyncVersionVector _fullVector(SyncVersion version) => version.context
      .merged(SyncVersionVector({version.dot.deviceId: version.dot.sequence}));

  Future<void> _applyEvents(
    List<SyncEvent> events, {
    List<SyncConflictRecord> conflicts = const [],
    String? batchId,
    List<SyncEvent> resolutionEvents = const [],
    List<String> resolvedConflictIds = const [],
    List<String> completedPendingIds = const [],
    List<SyncEvent> acknowledgedEvents = const [],
    SnapshotCursorAdvance? cursorAdvance,
  }) async {
    final currentHeads = await _repository.loadEntityHeads(
      events.map((e) => e.entity).toSet(),
    );
    final versions = [
      for (final event in events)
        SyncEntityVersion(
          entity: event.entity,
          version: currentHeads[event.entity]?.payloadHash == event.payloadHash
              ? SyncVersion(
                  dot: event.version.dot,
                  context: event.version.context.merged(
                    _fullVector(currentHeads[event.entity]!.version),
                  ),
                  logicalTime: event.version.logicalTime,
                )
              : event.version,
          payloadHash: event.payloadHash,
          payload: event.payload,
          deleted: event.operation == SyncOperationKind.delete,
          operationId: event.operationId,
        ),
    ];
    final folded = SyncProjection.applyVersions(
      _controller.exportDataForSync(),
      versions,
    );
    final kv = <String, String>{};
    for (final version in versions) {
      final type = version.entity.type;
      final key = SyncKvProjection.storageKeyFor(type);
      if (key != null) {
        kv[key] = SyncKvProjection.encodeStorageValue(type, folded[type]);
      }
    }
    final plan = RemoteApplyPlan(
      batchId: batchId ?? events.first.batchId,
      entityVersions: versions,
      appliedOperationIds: [
        for (final event in [...events, ...acknowledgedEvents])
          event.operationId,
      ],
      shadowHashes: {
        for (final event in events)
          encodeSyncEntityKey(event.entity): event.payloadHash,
      },
      kvJournalValues: kv,
      appliedPayloadHashes: {
        for (final event in [...events, ...acknowledgedEvents])
          event.operationId: event.payloadHash,
      },
      conflicts: conflicts,
      resolutionEvents: resolutionEvents,
      resolvedConflictIds: resolvedConflictIds,
      completedPendingIds: completedPendingIds,
      cursorAdvance: cursorAdvance,
    );

    // Route through the echo-suppression wrapper when provided.
    // Without it, a change tracker running on the same controller would
    // re-enqueue the just-applied remote data as a local mutation.
    final target = _controller;
    if (target is SyncRemoteApplyTarget) {
      await (target as SyncRemoteApplyTarget).applySyncRemoteBatch(plan);
    } else if (_remoteApply != null) {
      await _remoteApply(() => _repository.applyRemoteBatch(plan));
    } else {
      await _repository.applyRemoteBatch(plan);
    }
    _clock!.restoreState(await _repository.loadDeviceState());
  }

  Future<SyncConflictRecord> _buildConflict(
    SyncEvent remoteEvent, {
    SyncEntityVersion? localOverride,
  }) async {
    // Load the current shadow to find the locally-applied payload hash.
    final shadow = await _repository.loadShadow();
    final heads = await _repository.loadEntityHeads({remoteEvent.entity});
    final localHash =
        localOverride?.payloadHash ??
        heads[remoteEvent.entity]?.payloadHash ??
        shadow[remoteEvent.entity];

    if (localHash == null) {
      throw StateError('sync_conflict_without_local_version');
    }

    // Build a stub local version from the shadow hash.
    // Full payload reconstruction would require reading from entity_versions;
    // for conflict storage we record the hash and leave payload as null
    // (resolveConflict will show both remote versions to the user).
    await _ensureClock();
    final localVersion =
        localOverride ??
        heads[remoteEvent.entity] ??
        SyncEntityVersion(
          entity: remoteEvent.entity,
          version: SyncVersion(
            dot: SyncDot(
              deviceId: _clock!.deviceId,
              sequence: max(1, _clock!.nextSequence - 1),
            ),
            context: _clock!.knownVector,
            logicalTime: 0,
          ),
          payloadHash: localHash,
          payload: SyncProjection.fromExportData(
            _controller.exportDataForSync(),
          ).entity(remoteEvent.entity)?.payload,
          deleted:
              SyncProjection.fromExportData(
                _controller.exportDataForSync(),
              ).entity(remoteEvent.entity) ==
              null,
          operationId:
              'local-${computeSyncPayloadHash(remoteEvent.entity.toJson())}-$localHash',
        );

    final remoteVersion = SyncEntityVersion(
      entity: remoteEvent.entity,
      version: remoteEvent.version,
      payloadHash: remoteEvent.payloadHash,
      payload: remoteEvent.payload,
      deleted: remoteEvent.operation == SyncOperationKind.delete,
      operationId: remoteEvent.operationId,
    );

    final conflictId = canonicalSyncConflictId(
      remoteEvent.entity,
      localVersion.operationId,
      remoteEvent.operationId,
    );
    return SyncConflictRecord(
      id: conflictId,
      entity: remoteEvent.entity,
      local: localVersion,
      remote: remoteVersion,
    );
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
    await _repository.saveDeviceState(_clock!.getState());
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

  Future<bool> _joinConflictFlow(List<WebdavSyncFile> remoteFiles) async {
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

    // Reconstruct the remote maximal versions before comparing to restored
    // local data. Directory ordering is unrelated to causal ordering.
    final batches = await _groupFilesByBatchAsync(remoteFiles);
    if (batches.values.any((b) => !b.isComplete)) {
      for (final batch in batches.values.where((b) => !b.isComplete)) {
        await _repository.savePendingBatch(
          batch.batchId,
          batch.events,
          'enrollment_missing_dependency',
        );
      }
      return false;
    }
    final finalEvents = <SyncEntityKey, List<SyncEvent>>{};
    for (final batch in batches.values) {
      if (!batch.isComplete) {
        await _repository.savePendingBatch(
          batch.batchId,
          batch.events,
          'missing_dependency',
        );
        continue;
      }
      for (final event in batch.events) {
        final versions = finalEvents.putIfAbsent(event.entity, () => []);
        if (versions.any(
          (v) =>
              _fullVector(v.version).compare(_fullVector(event.version)) ==
              SyncCausality.after,
        )) {
          continue;
        }
        versions.removeWhere(
          (v) =>
              _fullVector(v.version).compare(_fullVector(event.version)) ==
              SyncCausality.before,
        );
        versions.add(event);
      }
    }
    final finalList = finalEvents.values.expand((v) => v).toList();
    if (finalList.isNotEmpty) {
      final joinId =
          'join-${computeSyncPayloadHash(finalList.map((e) => e.operationId).toList()..sort())}';
      await _repository.savePendingBatch(joinId, finalList, 'join_ready');
      final result = await _mergeAndApply(finalList, applyBatchId: joinId);
      if (result.$2 > 0) {
        await _repository.savePendingBatch(joinId, finalList, 'join_conflict');
        for (final batch in batches.values.where((b) => b.isComplete)) {
          await _repository.savePendingBatch(
            batch.batchId,
            batch.events,
            'join_dependency',
          );
        }
      }
      if (result.$2 == 0) await _scanAndApply();
    }
    return true;
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
          if (deviceGaps.isEmpty) contiguous = seq;
          expected++;
        } else if (seq > expected) {
          for (var i = expected; i < seq; i++) {
            deviceGaps.add(i);
          }
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
          batches
                  .putIfAbsent(batchId, () => _BatchFiles(batchId))
                  .manifestFile =
              file;
        }
      } else if (file.kind == WebdavSyncFileKind.commit) {
        final batchId = _extractBatchId(file.relativePath);
        if (batchId != null) {
          batches.putIfAbsent(batchId, () => _BatchFiles(batchId)).commitFile =
              file;
        }
      }
    }

    // Index exact operation ids, including legacy numeric filenames by reading
    // their complete event. Never infer batch membership from file counts.
    final eventFilesByOperation = <String, WebdavSyncFile>{};
    final eventsByOperation = <String, SyncEvent>{};
    for (final file in files) {
      if (file.kind == WebdavSyncFileKind.event) {
        final bytes = await _transport!.downloadSyncFile(
          _config!,
          file.relativePath,
          maxBytes: wireLimits.maxEnvelopeBytes,
        );
        final event = await _decodeEvent(bytes);
        final pathParts = _canonicalPath(file.relativePath).split('/');
        if (pathParts.length != 3 ||
            pathParts[1] != event.version.dot.deviceId ||
            (file.sequence != null &&
                file.sequence != event.version.dot.sequence)) {
          throw const FormatException('Invalid sync event path identity');
        }
        if (eventFilesByOperation.containsKey(event.operationId)) {
          throw StateError('duplicate_remote_operation');
        }
        eventFilesByOperation[event.operationId] = file;
        eventsByOperation[event.operationId] = event;
        batches.putIfAbsent(event.batchId, () => _BatchFiles(event.batchId));
      }
    }

    // For each batch that has a manifest, download it to get the operationId
    // list, then match files by exact operation id.
    for (final entry in batches.entries) {
      final batchFiles = entry.value;
      final manifestFile = batchFiles.manifestFile;
      if (manifestFile == null) {
        batchFiles.events.addAll(
          eventsByOperation.values.where((e) => e.batchId == entry.key),
        );
        continue;
      }

      final bytes = await _transport!.downloadSyncFile(
        _config!,
        manifestFile.relativePath,
        maxBytes: wireLimits.maxEnvelopeBytes,
      );
      final json = await _decodeDocument(bytes);
      validateSyncManifest(json);
      final operationIds =
          (json['operationIds'] as List<Object?>?)
              ?.whereType<String>()
              .toList() ??
          <String>[];
      batchFiles.operationIds.addAll(operationIds);
      final commitFile = batchFiles.commitFile;
      if (commitFile != null) {
        final commitBytes = await _transport.downloadSyncFile(
          _config!,
          commitFile.relativePath,
          maxBytes: wireLimits.maxEnvelopeBytes,
        );
        final commit = jsonDecode(utf8.decode(commitBytes));
        // The marker contains no ledger data. Its exact expected contents bind
        // both the authenticated decrypted manifest hash and ciphertext hash.
        // Editing a plaintext marker cannot replace the encrypted manifest or
        // its event/blob commitments without failing these comparisons.
        if (computeSyncPayloadHash(commit) !=
            computeSyncPayloadHash(syncCommit(json, bytes))) {
          throw const FormatException('commit_hash_mismatch');
        }
      }
      if (json['batchId'] != entry.key ||
          operationIds.toSet().length != operationIds.length) {
        throw const FormatException('Invalid sync manifest');
      }
      for (final operationId in operationIds) {
        final file = eventFilesByOperation[operationId];
        if (file != null) {
          final event = eventsByOperation[operationId]!;
          final device = _canonicalPath(
            manifestFile.relativePath,
          ).split('/')[1];
          if (event.batchId != entry.key ||
              event.version.dot.deviceId != device) {
            throw const FormatException('Invalid sync manifest event identity');
          }
          if ((json['payloadHashes'] as Map)[operationId] !=
              event.payloadHash) {
            throw const FormatException('manifest_payload_hash_mismatch');
          }
          batchFiles.eventFiles.add(file);
          batchFiles.events.add(event);
        }
      }
      final blobs = (json['blobHashes'] as List).cast<String>();
      final decodedBlobs = <String, Uint8List>{};
      for (final hash in blobs) {
        final blob = files
            .where((f) => _canonicalPath(f.relativePath) == 'blobs/$hash.blob')
            .firstOrNull;
        if (blob == null) {
          batchFiles.missingBlobs = true;
          continue;
        }
        final value = await _decodeDocument(
          await _transport.downloadSyncFile(
            _config!,
            blob.relativePath,
            maxBytes: wireLimits.maxEnvelopeBytes,
          ),
        );
        final content = base64Decode(value['data'] as String);
        if (value['hash'] != hash ||
            sha256.convert(content).toString() != hash) {
          await _repository.savePendingBatch(
            batchFiles.batchId,
            batchFiles.events,
            'corrupt_blob',
          );
          throw const FormatException('blob_hash_mismatch');
        }
        decodedBlobs[hash] = content;
      }
      if (batchFiles.events.length == operationIds.length &&
          computeSyncPayloadHash(
                syncBlobHashes(batchFiles.events, limits: wireLimits).toList()
                  ..sort(),
              ) !=
              computeSyncPayloadHash(blobs)) {
        throw const FormatException('manifest_blob_reference_mismatch');
      }
      if (!batchFiles.missingBlobs) {
        final materialized = batchFiles.events
            .map(
              (e) => materializeSyncEvent(e, decodedBlobs, limits: wireLimits),
            )
            .toList();
        batchFiles.events
          ..clear()
          ..addAll(materialized);
      }
    }

    return batches;
  }

  String? _extractBatchId(String path) {
    final parts = _canonicalPath(path).split('/');
    if (parts.length == 3 && parts[0] == 'batches') {
      final filename = parts[2];
      final match = RegExp(r'^(.+)\.(manifest|commit)$').firstMatch(filename);
      return match?.group(1);
    }
    return null;
  }

  static List<_BatchFiles> _causalBatchOrder(Iterable<_BatchFiles> input) {
    final remaining = input.toList();
    final ordered = <_BatchFiles>[];
    while (remaining.isNotEmpty) {
      final next =
          remaining
              .where(
                (candidate) => !remaining.any(
                  (prior) =>
                      !identical(candidate, prior) &&
                      candidate.events.any(
                        (event) => prior.events.any(
                          (before) =>
                              (event.version.context.values[before
                                      .version
                                      .dot
                                      .deviceId] ??
                                  0) >=
                              before.version.dot.sequence,
                        ),
                      ),
                ),
              )
              .firstOrNull ??
          remaining.first;
      remaining.remove(next);
      ordered.add(next);
    }
    return ordered;
  }

  String _manifestPath(String batchId, String deviceId) {
    return 'verifin-sync/v1/batches/$deviceId/$batchId.manifest';
  }

  String _commitPath(String batchId, String deviceId) {
    return 'verifin-sync/v1/batches/$deviceId/$batchId.commit';
  }
}

class _SnapshotBlobSession {
  _SnapshotBlobSession(this.directory);

  final Directory directory;
  final Map<String, File> _files = <String, File>{};

  static Future<_SnapshotBlobSession> create(Directory? root) async {
    final parent = root ?? Directory.systemTemp;
    await parent.create(recursive: true);
    return _SnapshotBlobSession(
      await parent.createTemp('verifin-sync-snapshot-'),
    );
  }

  bool contains(String rawHash) => _files.containsKey(rawHash);

  Future<void> write(String rawHash, Uint8List bytes) async {
    final file = File('${directory.path}${Platform.pathSeparator}$rawHash.tmp');
    await file.writeAsBytes(bytes, flush: true);
    _files[rawHash] = file;
  }

  Future<Uint8List> read(String rawHash) async {
    final file = _files[rawHash];
    if (file == null) throw const FormatException('snapshot_blob_missing');
    return file.readAsBytes();
  }

  Future<void> dispose() async {
    if (await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }
}

class _BatchFiles {
  _BatchFiles(this.batchId);
  final String batchId;
  WebdavSyncFile? manifestFile;
  WebdavSyncFile? commitFile;
  final List<WebdavSyncFile> eventFiles = [];
  final List<SyncEvent> events = [];
  final List<String> operationIds = [];
  bool missingBlobs = false;

  bool get isComplete =>
      manifestFile != null &&
      commitFile != null &&
      !missingBlobs &&
      eventFiles.isNotEmpty &&
      eventFiles.length >= operationIds.length;
}
