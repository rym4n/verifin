import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/sync/sync_codec.dart';
import 'package:verifin/app/sync/sync_models.dart';
import 'package:verifin/app/sync/sync_snapshot.dart';

const deviceId = '4f8c19e6d7134be39c25820b2f55a912';

void main() {
  final fileHash = 'a' * 64;
  final source = SnapshotFileName.snapshot(
    deviceId: deviceId,
    snapshotSequence: 42,
    createdAtUtc: DateTime.utc(2026, 9, 18, 3, 15, 22, 417),
    fileHash: fileHash,
  );

  group('SnapshotFileName', () {
    test('round trips strict snapshot and blob names', () {
      final snapshot = SnapshotFileName.parse(source.toString());
      final blob = SnapshotFileName.parse(
        SnapshotFileName.blob(fileHash: fileHash).toString(),
      );

      expect(snapshot.deviceId, deviceId);
      expect(snapshot.snapshotSequence, 42);
      expect(snapshot.createdAtUtc, DateTime.utc(2026, 9, 18, 3, 15, 22, 417));
      expect(snapshot.fileHash, fileHash);
      expect(blob.isBlob, isTrue);
      expect(blob.fileHash, fileHash);

      final precise = SnapshotFileName.snapshot(
        deviceId: deviceId,
        snapshotSequence: 1,
        createdAtUtc: DateTime.utc(2026, 9, 18, 3, 15, 22, 417, 999),
        fileHash: fileHash,
      );
      expect(
        SnapshotFileName.parse(precise.toString()).createdAtUtc,
        DateTime.utc(2026, 9, 18, 3, 15, 22, 417),
      );
    });

    test('rejects non-canonical device, sequence, timestamp, and hash names', () {
      for (final name in [
        'verifin-sync-v2-${'A' * 32}-00000000000000000042-20260918T031522417Z-$fileHash.json',
        'verifin-sync-v2-$deviceId-42-20260918T031522417Z-$fileHash.json',
        'verifin-sync-v2-$deviceId-00000000000000000042-20260918T031522Z-$fileHash.json',
        'verifin-sync-v2-$deviceId-00000000000000000042-20260918T031522417Z-${'A' * 64}.json',
        'verifin-sync-v2-blob-${'A' * 64}.blob',
      ]) {
        expect(() => SnapshotFileName.parse(name), throwsFormatException);
      }
    });
  });

  group('SyncSnapshotCodec', () {
    test(
      'canonical plaintext encoding is deterministic and round trips',
      () async {
        final first = sampleSnapshot(
          heads: [sampleHead('b'), sampleHead('a')],
          knownVector: const SyncVersionVector({'z': 1, 'a': 2, deviceId: 1}),
        );
        final second = sampleSnapshot(
          heads: [sampleHead('a'), sampleHead('b')],
          knownVector: const SyncVersionVector({'a': 2, 'z': 1, deviceId: 1}),
        );
        const codec = SyncSnapshotCodec(passphrase: '');

        final firstBytes = await codec.encode(first);
        final secondBytes = await codec.encode(second);
        final decoded = await codec.decode(
          firstBytes,
          source: source.withFileHash(sha256.convert(firstBytes).toString()),
        );

        expect(firstBytes, secondBytes);
        expect(decoded.heads.map((head) => head.entity.id), ['a', 'b']);
        expect(utf8.decode(firstBytes), startsWith('{"attachmentBlobs":'));
      },
    );

    test(
      'encrypted snapshot round trips and rejects a different fingerprint',
      () async {
        final snapshot = sampleSnapshot(
          keyFingerprint: SyncCodec.keyFingerprintFor('secret'),
        );
        const codec = SyncSnapshotCodec(passphrase: 'secret');
        final bytes = await codec.encode(snapshot);

        expect(
          await codec.decode(
            bytes,
            source: source.withFileHash(sha256.convert(bytes).toString()),
          ),
          isA<SyncSnapshot>(),
        );
        await expectLater(
          const SyncSnapshotCodec(passphrase: 'other').decode(
            bytes,
            source: source.withFileHash(sha256.convert(bytes).toString()),
          ),
          throwsA(isA<SyncCodecException>()),
        );
      },
    );

    test('rejects bytes whose filename hash differs before parsing', () async {
      const codec = SyncSnapshotCodec(passphrase: '');
      final bytes = await codec.encode(sampleSnapshot());
      await expectLater(
        codec.decode(bytes, source: source),
        throwsA(isA<SyncSnapshotException>()),
      );
    });

    test('rejects duplicate entity and operation identifiers', () async {
      const codec = SyncSnapshotCodec(passphrase: '');
      final duplicateEntity = sampleSnapshot(
        heads: [
          sampleHead('same', operationId: 'one'),
          sampleHead('same', operationId: 'two'),
        ],
      );
      final duplicateOperation = sampleSnapshot(
        heads: [
          sampleHead('one', operationId: 'same'),
          sampleHead('two', operationId: 'same'),
        ],
      );

      await expectLater(codec.encode(duplicateEntity), throwsFormatException);
      await expectLater(
        codec.encode(duplicateOperation),
        throwsFormatException,
      );
    });

    test(
      'enforces plaintext and envelope limits before JSON decoding',
      () async {
        const tiny = SyncSnapshotLimits(
          maxPlaintextBytes: 32,
          maxEnvelopeBytes: 64,
        );
        const codec = SyncSnapshotCodec(passphrase: '', limits: tiny);
        await expectLater(
          codec.encode(sampleSnapshot()),
          throwsA(isA<SyncSnapshotException>()),
        );
        final tooLarge = Uint8List.fromList(utf8.encode('{${' ' * 65}'));
        final tooLargeSource = source.withFileHash(
          sha256.convert(tooLarge).toString(),
        );
        await expectLater(
          codec.decode(tooLarge, source: tooLargeSource),
          throwsA(isA<SyncSnapshotException>()),
        );
      },
    );

    test(
      'rejects an oversized plaintext document before JSON decoding',
      () async {
        const encoder = SyncSnapshotCodec(passphrase: '');
        const constrained = SyncSnapshotCodec(
          passphrase: '',
          limits: SyncSnapshotLimits(
            maxPlaintextBytes: 1,
            maxEnvelopeBytes: 1024,
          ),
        );
        final bytes = await encoder.encode(sampleSnapshot());

        await expectLater(
          constrained.decode(
            bytes,
            source: source.withFileHash(sha256.convert(bytes).toString()),
          ),
          throwsA(
            isA<SyncSnapshotException>().having(
              (error) => error.code,
              'code',
              'snapshot_plaintext_too_large',
            ),
          ),
        );
      },
    );

    test(
      'rejects oversized decrypted plaintext with its stable error code before JSON decoding',
      () async {
        final snapshot = sampleSnapshot(
          keyFingerprint: SyncCodec.keyFingerprintFor('secret'),
        );
        const encoder = SyncSnapshotCodec(passphrase: 'secret');
        const constrained = SyncSnapshotCodec(
          passphrase: 'secret',
          limits: SyncSnapshotLimits(
            maxPlaintextBytes: 1,
            maxEnvelopeBytes: 1024 * 1024,
          ),
        );
        final bytes = await encoder.encode(snapshot);

        await expectLater(
          constrained.decode(
            bytes,
            source: source.withFileHash(sha256.convert(bytes).toString()),
          ),
          throwsA(
            isA<SyncCodecException>().having(
              (error) => error.message,
              'message',
              'snapshot_plaintext_too_large',
            ),
          ),
        );
      },
    );

    test('rejects a hash-correct v1 document in the v2 decoder', () async {
      const v1Codec = SyncCodec(passphrase: '');
      final v1 = await v1Codec.encodeValue({'value': 1}, syncProtocolVersion);
      final bytes = Uint8List.fromList(utf8.encode(canonicalSyncJson(v1)));

      await expectLater(
        const SyncSnapshotCodec(passphrase: '').decode(
          bytes,
          source: source.withFileHash(sha256.convert(bytes).toString()),
        ),
        throwsFormatException,
      );
    });

    test(
      'rejects encrypted envelope filename mismatch before decryption',
      () async {
        final snapshot = sampleSnapshot(
          keyFingerprint: SyncCodec.keyFingerprintFor('secret'),
        );
        final bytes = await const SyncSnapshotCodec(
          passphrase: 'secret',
        ).encode(snapshot);

        await expectLater(
          const SyncSnapshotCodec(
            passphrase: 'wrong',
          ).decode(bytes, source: source),
          throwsA(
            isA<SyncSnapshotException>().having(
              (error) => error.code,
              'code',
              'snapshot_file_hash_mismatch',
            ),
          ),
        );
      },
    );

    test('rejects non-integral or negative snapshot metadata', () {
      final json = sampleSnapshot().toJson();
      for (final invalid in [2.5, double.nan, double.infinity]) {
        expect(
          () => SyncSnapshot.fromJson({...json, 'protocolVersion': invalid}),
          throwsFormatException,
        );
      }
      for (final invalid in [42.5, -1, double.nan, double.infinity]) {
        expect(
          () => SyncSnapshot.fromJson({...json, 'snapshotSequence': invalid}),
          throwsFormatException,
        );
      }
    });

    test('rejects invalid blob hashes before encoding a snapshot', () async {
      final snapshot = sampleSnapshotWithBlob(
        SyncSnapshotBlobRef(rawHash: 'not-a-hash', fileHash: 'f' * 64),
      );

      await expectLater(
        const SyncSnapshotCodec(passphrase: '').encode(snapshot),
        throwsFormatException,
      );
    });

    test(
      'preserves raw and file attachment hashes through projection',
      () async {
        final rawHash = sha256.convert([1, 2, 3]).toString();
        final blobHash = 'c' * 64;
        final event = SyncEvent(
          protocolVersion: syncProtocolVersion,
          operationId: 'attachment-operation',
          version: const SyncVersion(
            dot: SyncDot(deviceId: deviceId, sequence: 1),
            context: SyncVersionVector({}),
            logicalTime: 1,
          ),
          entity: const SyncEntityKey(
            scope: 'ledger',
            type: 'attachments',
            id: 'attachment',
          ),
          operation: SyncOperationKind.upsert,
          payloadHash: computeSyncPayloadHash({
            'id': 'attachment',
            'dataUrl': 'data:image/png;base64,AQID',
          }),
          payload: {
            'id': 'attachment',
            'dataUrl': 'data:image/png;base64,AQID',
          },
          batchId: 'batch',
          keyFingerprint: 'none',
        );
        final snapshot = SyncSnapshot.fromProjection(
          deviceId: deviceId,
          snapshotSequence: 42,
          createdAtUtc: source.createdAtUtc!,
          keyFingerprint: 'none',
          knownVector: const SyncVersionVector({deviceId: 1}),
          events: [event],
          attachmentBlobs: [
            SyncSnapshotAttachmentBlob(
              attachmentId: 'attachment',
              byteLength: 3,
              dataUrlPrefix: 'data:image/png;base64,',
              chunks: [
                SyncSnapshotBlobRef(rawHash: rawHash, fileHash: blobHash),
              ],
            ),
          ],
        );
        final head = snapshot.heads.single;

        expect((head.payload as Map)['blobChunks'], [rawHash]);
        expect(snapshot.attachmentBlobs.single.chunks.single.rawHash, rawHash);
        expect(
          snapshot.attachmentBlobs.single.chunks.single.fileHash,
          blobHash,
        );
      },
    );

    test(
      'round trips attachment mappings without swapping raw and file hashes',
      () async {
        final rawHash = 'a' * 64;
        final fileHash = 'b' * 64;
        final snapshot = sampleSnapshotWithBlob(
          SyncSnapshotBlobRef(rawHash: rawHash, fileHash: fileHash),
        );
        const codec = SyncSnapshotCodec(passphrase: '');
        final bytes = await codec.encode(snapshot);
        final decoded = await codec.decode(
          bytes,
          source: source.withFileHash(sha256.convert(bytes).toString()),
        );
        final chunk = decoded.attachmentBlobs.single.chunks.single;

        expect(chunk.rawHash, rawHash);
        expect(chunk.fileHash, fileHash);
      },
    );
  });
}

SyncSnapshot sampleSnapshotWithBlob(SyncSnapshotBlobRef chunk) => SyncSnapshot(
  deviceId: deviceId,
  snapshotSequence: 42,
  createdAtUtc: DateTime.utc(2026, 9, 18, 3, 15, 22, 417),
  keyFingerprint: 'none',
  knownVector: const SyncVersionVector({deviceId: 1}),
  heads: [sampleHead('head')],
  attachmentBlobs: [
    SyncSnapshotAttachmentBlob(
      attachmentId: 'attachment',
      byteLength: 3,
      dataUrlPrefix: 'data:image/png;base64,',
      chunks: [chunk],
    ),
  ],
  conflicts: const [],
);

SyncSnapshot sampleSnapshot({
  List<SyncEntityVersion>? heads,
  SyncVersionVector? knownVector,
  String keyFingerprint = 'none',
}) => SyncSnapshot(
  deviceId: deviceId,
  snapshotSequence: 42,
  createdAtUtc: DateTime.utc(2026, 9, 18, 3, 15, 22, 417),
  keyFingerprint: keyFingerprint,
  knownVector: knownVector ?? const SyncVersionVector({deviceId: 1}),
  heads: heads ?? [sampleHead('head')],
  attachmentBlobs: const [],
  conflicts: const [],
);

SyncEntityVersion sampleHead(String id, {String? operationId}) {
  final payload = {'id': id};
  return SyncEntityVersion(
    entity: SyncEntityKey(scope: 'ledger', type: 'entries', id: id),
    version: const SyncVersion(
      dot: SyncDot(deviceId: deviceId, sequence: 1),
      context: SyncVersionVector({}),
      logicalTime: 1,
    ),
    payloadHash: computeSyncPayloadHash(payload),
    payload: payload,
    deleted: false,
    operationId: operationId ?? 'operation-$id',
  );
}
