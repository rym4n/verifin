import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/sync/sync_codec.dart';
import 'package:verifin/app/sync/sync_models.dart';

void main() {
  test('v1 decode bridge accepts only protocol version 1', () async {
    const codec = SyncCodec(passphrase: '');
    final v1 = await codec.encodeValue({'value': 1}, syncProtocolVersion);
    final v2 = await codec.encodeValue({
      'value': 2,
    }, syncSnapshotProtocolVersion);

    expect(await codec.decode(v1), {'value': 1});
    await expectLater(codec.decode(v2), throwsA(isA<SyncCodecException>()));
    await expectLater(
      codec.decodeValue(
        v1,
        expectedProtocolVersion: syncSnapshotProtocolVersion,
      ),
      throwsA(isA<SyncCodecException>()),
    );
    expect(
      await codec.decodeValue(
        v2,
        expectedProtocolVersion: syncSnapshotProtocolVersion,
      ),
      {'value': 2},
    );
  });
}
