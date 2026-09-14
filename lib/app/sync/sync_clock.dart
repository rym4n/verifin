import 'dart:math';

import '../../local_storage/local_storage.dart';
import 'sync_models.dart';

const String _deviceIdKey = 'sync_device_id';

/// Causal clock for generating versions and operation IDs.
class SyncClock {
  SyncClock._({
    required this.deviceId,
    required int nextSequence,
    required SyncVersionVector knownVector,
  })  : _nextSequence = nextSequence,
        _knownVector = knownVector;

  final String deviceId;
  int _nextSequence;
  SyncVersionVector _knownVector;

  /// Initialize or restore the clock from persistent storage.
  static Future<SyncClock> create(LocalKeyValueStore store) async {
    String? deviceId = store.read(_deviceIdKey);
    if (deviceId == null || deviceId.isEmpty) {
      deviceId = _generateDeviceId();
      await store.writeAndFlush(_deviceIdKey, deviceId);
    }
    return SyncClock._(
      deviceId: deviceId,
      nextSequence: 1,
      knownVector: const SyncVersionVector({}),
    );
  }

  /// Generate next version, incrementing sequence and merging the new dot into known vector.
  SyncVersion nextVersion({required SyncVersionVector known}) {
    final sequence = _nextSequence++;
    final dot = SyncDot(deviceId: deviceId, sequence: sequence);
    final logicalTime = DateTime.now().microsecondsSinceEpoch;

    // Merge known vector with the new dot.
    final dotAsVector = SyncVersionVector({deviceId: sequence});
    _knownVector = known.merged(dotAsVector);

    return SyncVersion(
      dot: dot,
      context: known,
      logicalTime: logicalTime,
    );
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
    _nextSequence = state.nextSequence;
    _knownVector = state.knownVector;
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
