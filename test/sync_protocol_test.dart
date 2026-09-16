import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/sync/sync_models.dart';

void main() {
  group('SyncVersionVector', () {
    test('dotted vectors distinguish causal and concurrent edits', () {
      const a = SyncVersionVector({'phone': 2, 'tablet': 1});
      const b = SyncVersionVector({'phone': 2, 'tablet': 2});
      const c = SyncVersionVector({'phone': 3, 'tablet': 1});
      expect(a.compare(b), SyncCausality.before);
      expect(b.compare(a), SyncCausality.after);
      expect(b.compare(c), SyncCausality.concurrent);
    });

    test('equal vectors return equal, not concurrent', () {
      const a = SyncVersionVector({'phone': 2, 'tablet': 1});
      const b = SyncVersionVector({'phone': 2, 'tablet': 1});
      expect(a.compare(b), SyncCausality.equal);
    });

    test('missing keys treated as zero', () {
      const a = SyncVersionVector({'phone': 1});
      const b = SyncVersionVector({'phone': 1, 'tablet': 0});
      expect(a.compare(b), SyncCausality.equal);
    });

    test('merged combines max of each device', () {
      const a = SyncVersionVector({'phone': 3, 'tablet': 1});
      const b = SyncVersionVector({'phone': 2, 'tablet': 5, 'desktop': 1});
      final merged = a.merged(b);
      expect(merged.values['phone'], 3);
      expect(merged.values['tablet'], 5);
      expect(merged.values['desktop'], 1);
    });
  });

  group('SyncEvent JSON', () {
    test('event JSON preserves operation, vector, batch and hash', () {
      final event = makeTestEvent();
      final json = event.toJson();
      final restored = SyncEvent.fromJson(json);
      expect(restored, event);
    });

    test('equality covers all serialized fields', () {
      final event1 = makeTestEvent();
      final event2 = makeTestEvent(operationId: 'different-op-id');
      expect(event1, isNot(equals(event2)));
    });

    test('fromJson rejects missing protocolVersion', () {
      final json = makeTestEvent().toJson();
      json.remove('protocolVersion');
      expect(() => SyncEvent.fromJson(json), throwsA(isA<FormatException>()));
    });

    test('fromJson rejects empty operationId', () {
      final json = makeTestEvent().toJson();
      json['operationId'] = '';
      expect(() => SyncEvent.fromJson(json), throwsA(isA<FormatException>()));
    });

    test('fromJson rejects negative sequence', () {
      final json = makeTestEvent().toJson();
      (json['version'] as Map<String, Object?>)['dot'] = {
        'deviceId': 'dev1',
        'sequence': -1,
      };
      expect(() => SyncEvent.fromJson(json), throwsA(isA<FormatException>()));
    });

    test('fromJson rejects unknown SyncOperationKind', () {
      final json = makeTestEvent().toJson();
      json['operation'] = 'unknown_operation';
      expect(() => SyncEvent.fromJson(json), throwsA(isA<FormatException>()));
    });

    test('fromJson rejects mismatched payloadHash', () {
      final json = makeTestEvent().toJson();
      json['payloadHash'] = 'wrong_hash';
      expect(() => SyncEvent.fromJson(json), throwsA(isA<FormatException>()));
    });
  });
}

SyncEvent makeTestEvent({String? operationId, Object? payload}) {
  final actualPayload = payload ?? const <String, Object?>{};
  return SyncEvent(
    protocolVersion: '1.0.0',
    operationId: operationId ?? 'op-12345',
    version: const SyncVersion(
      dot: SyncDot(deviceId: 'phone', sequence: 5),
      context: SyncVersionVector({'phone': 4, 'tablet': 2}),
      logicalTime: 1234567890000,
    ),
    entity: const SyncEntityKey(
      scope: 'ledger',
      type: 'transaction',
      id: 'txn-001',
    ),
    operation: SyncOperationKind.upsert,
    payloadHash: computeSyncPayloadHash(actualPayload),
    payload: actualPayload,
    batchId: 'batch-001',
    keyFingerprint: 'none',
  );
}
