import 'sync_models.dart';

/// Durable prepared commit. Business rows and journal are already stored;
/// this record contains only the metadata to finalize after KV flush succeeds.
Map<String, Object?> encodePreparedPlan(RemoteApplyPlan plan) => {
  'batchId': plan.batchId,
  'operations': {
    for (final id in plan.appliedOperationIds)
      id: plan.payloadHashForOperation(id),
  },
  'versions': [
    for (final v in plan.entityVersions) v.version.toJson(),
    for (final conflict in plan.conflicts) ...[
      conflict.local.version.toJson(),
      conflict.remote.version.toJson(),
    ],
  ],
  'resolutionEvents': plan.resolutionEvents.map((e) => e.toJson()).toList(),
  'resolvedConflictIds': plan.resolvedConflictIds,
  'completedPendingIds': plan.completedPendingIds,
};
