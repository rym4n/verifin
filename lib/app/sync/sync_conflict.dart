import 'sync_models.dart';

/// User-facing conflict resolution options.
enum ConflictResolution {
  /// Keep local version.
  keepLocal,

  /// Keep remote version.
  keepRemote,

  /// Keep deletion (if one side deleted).
  keepDelete,

  /// Keep edited version (if one side edited).
  keepEdit,

  /// Cancel resolution (leave conflict unresolved).
  cancel,
}

/// User-facing conflict representation.
class SyncConflict {
  const SyncConflict({
    required this.id,
    required this.entity,
    required this.localVersion,
    required this.remoteVersion,
    required this.localPayload,
    required this.remotePayload,
    required this.localDeleted,
    required this.remoteDeleted,
  });

  final String id;
  final SyncEntityKey entity;
  final SyncVersion localVersion;
  final SyncVersion remoteVersion;
  final Object? localPayload;
  final Object? remotePayload;
  final bool localDeleted;
  final bool remoteDeleted;

  /// Create from a stored conflict record.
  factory SyncConflict.fromRecord(SyncConflictRecord record) {
    return SyncConflict(
      id: record.id,
      entity: record.entity,
      localVersion: record.local.version,
      remoteVersion: record.remote.version,
      localPayload: record.local.payload,
      remotePayload: record.remote.payload,
      localDeleted: record.local.deleted,
      remoteDeleted: record.remote.deleted,
    );
  }
}
