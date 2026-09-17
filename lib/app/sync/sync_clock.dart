// ignore_for_file: prefer_initializing_formals
import 'dart:math';

import '../../local_storage/local_storage.dart';
import 'sync_models.dart';

const String _deviceIdKey = 'sync_device_id';
const String _nextSequenceKey = 'sync_device_next_sequence';

/// Causal clock for generating versions and operation IDs.
class SyncClock {
  SyncClock._({
    required this.deviceId,
    required int nextSequence,
    required SyncVersionVector knownVector,
    required LocalKeyValueStore store,
  }) : _nextSequence = nextSequence,
       _knownVector = knownVector,
       _store = store;

  final String deviceId;
  int _nextSequence;
  SyncVersionVector _knownVector;
  final LocalKeyValueStore _store;

  /// Initialize or restore the clock from persistent storage.
  ///
  /// Restores [deviceId] and [_nextSequence] from [store] so sequence numbers
  /// are never re-issued after an app restart. Later tasks may call
  /// [restoreState] to overlay the full [SyncDeviceState] from the database.
  static Future<SyncClock> create(LocalKeyValueStore store) async {
    String? deviceId = store.read(_deviceIdKey);
    if (deviceId == null || deviceId.isEmpty) {
      deviceId = _generateDeviceId();
      await store.writeAndFlush(_deviceIdKey, deviceId);
    }

    final sequenceStr = store.read(_nextSequenceKey);
    final nextSequence = sequenceStr != null
        ? (int.tryParse(sequenceStr) ?? 1)
        : 1;

    return SyncClock._(
      deviceId: deviceId,
      nextSequence: nextSequence,
      knownVector: const SyncVersionVector({}),
      store: store,
    );
  }

  /// Generate next version, incrementing sequence and merging the new dot into known vector.
  ///
  /// Persists the new [_nextSequence] to the store so restarts never re-issue
  /// sequence numbers.
  SyncVersion nextVersion({SyncVersionVector? known}) {
    final knownCtx = known ?? _knownVector;
    final sequence = _nextSequence++;
    _store.write(_nextSequenceKey, _nextSequence.toString());
    final dot = SyncDot(deviceId: deviceId, sequence: sequence);
    final logicalTime = DateTime.now().microsecondsSinceEpoch;

    // Merge known vector with the new dot.
    final dotAsVector = SyncVersionVector({deviceId: sequence});
    _knownVector = knownCtx.merged(dotAsVector);

    return SyncVersion(dot: dot, context: knownCtx, logicalTime: logicalTime);
  }

  /// Generate a unique operation ID.
  String nextOperationId() {
    return _generateUuid();
  }

  /// Current known vector.
  SyncVersionVector get knownVector => _knownVector;

  /// Current next sequence number.
  int get nextSequence => _nextSequence;

  /// Update the clock state from persisted device state.
  void restoreState(SyncDeviceState state) {
    if (state.deviceId != deviceId) {
      throw StateError(
        'Cannot restore state from different device: $deviceId != ${state.deviceId}',
      );
    }
    _nextSequence = max(_nextSequence, state.nextSequence);
    _knownVector = _knownVector.merged(state.knownVector);
  }

  /// Get current state for persistence.
  SyncDeviceState getState() {
    return SyncDeviceState(
      deviceId: deviceId,
      nextSequence: _nextSequence,
      knownVector: _knownVector,
    );
  }

  /// Generate a 16-byte device ID as hex string.
  static String _generateDeviceId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Create a clock with a specific device ID for testing (no persistence).
  static SyncClock createWithDeviceId(String deviceId) {
    return SyncClock._(
      deviceId: deviceId,
      nextSequence: 1,
      knownVector: const SyncVersionVector({}),
      store: _NoOpStore(),
    );
  }

  /// Restore clock from device state (no persistence).
  static SyncClock restore({
    required String deviceId,
    required int nextSequence,
    required SyncVersionVector knownVector,
  }) {
    return SyncClock._(
      deviceId: deviceId,
      nextSequence: nextSequence,
      knownVector: knownVector,
      store: _NoOpStore(),
    );
  }

  /// Generate a UUID v4 equivalent (random 128-bit identifier).
  static String _generateUuid() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));

    // Set version to 4 (random).
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    // Set variant to RFC 4122.
    bytes[8] = (bytes[8] & 0x3f) | 0x80;

    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}';
  }
}

/// No-op store for testing without persistence.
class _NoOpStore implements LocalKeyValueStore {
  @override
  String? read(String key) => null;

  @override
  void write(String key, String value) {}

  @override
  Future<void> writeAndFlush(String key, String value) async {}

  @override
  void delete(String key) {}

  @override
  Future<void> deleteAndFlush(String key) async {}

  Future<void> clear() async {}

  @override
  Future<void> flush() async {}
}
