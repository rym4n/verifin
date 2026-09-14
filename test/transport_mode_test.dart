import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/backup/backup_settings.dart';
import 'package:verifin/app/backup/webdav_config.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/test_harness.dart';

/// Task 6 Step 1：传输模式迁移与崩溃修复。
///
/// 断言四件事：
/// 1. 旧 `BackupSettings.frequency` / `WebdavConfig.autoUpload` 能迁移到唯一模式；
/// 2. 开启一种自动模式会关掉另一种（互斥）；
/// 3. 写到一半被打断（规范键损坏/半份）时，启动按「未写入」处理并重新推导；
/// 4. 反复重开控制器，永远不会同时报告两种自动模式都处于开启。
void main() {
  useTestDatabases();

  const String canonicalKey = 'verifin.backup_transport_mode.v1';

  group('BackupTransportModeCodec', () {
    test('往返保留模式', () {
      for (final mode in BackupTransportMode.values) {
        final encoded = BackupTransportModeCodec.encode(mode);
        expect(BackupTransportModeCodec.decode(encoded), mode);
      }
    });

    test('缺失/空值/损坏 JSON 一律视为未写入', () {
      expect(BackupTransportModeCodec.decode(null), isNull);
      expect(BackupTransportModeCodec.decode(''), isNull);
      expect(BackupTransportModeCodec.decode('not json'), isNull);
      expect(BackupTransportModeCodec.decode('[]'), isNull);
      expect(BackupTransportModeCodec.decode('{}'), isNull);
    });

    test('校验和不匹配视为写到一半被打断', () {
      // 结构完整、模式合法，但校验和是被篡改/截断写入的：必须拒绝，
      // 否则一个半份写入会被当成合法模式使用。
      const tampered = '{"version":1,"mode":"autoSync","checksum":"deadbeef"}';
      expect(BackupTransportModeCodec.decode(tampered), isNull);
    });

    test('模式字段被替换而校验和未跟着变，同样拒绝', () {
      final encoded = BackupTransportModeCodec.encode(
        BackupTransportMode.manual,
      );
      final swapped = encoded.replaceFirst('"manual"', '"autoSync"');
      expect(BackupTransportModeCodec.decode(swapped), isNull);
    });
  });

  group('旧值迁移', () {
    test('全新安装默认手动', () async {
      final controller = await makeController(LocalKeyValueStore());
      expect(controller.backupTransportMode, BackupTransportMode.manual);
    });

    test('旧 WebdavConfig.autoUpload=true 迁移为 autoUpload', () async {
      final store = LocalKeyValueStore();
      store.write(
        'verifin.webdav.v1',
        const WebdavConfig(
          url: 'https://dav.example.com/verifin/',
          username: 'u',
          password: 'p',
          autoUpload: true,
        ).encode(),
      );

      final controller = await makeController(store);
      expect(controller.backupTransportMode, BackupTransportMode.autoUpload);
      // 迁移会把旧标记清掉，避免 BackupCoordinator 继续按它重复触发上传。
      expect(controller.webdavConfig.autoUpload, isFalse);
      // 服务器连接信息本身不受影响。
      expect(controller.webdavConfig.isConfigured, isTrue);
      expect(controller.webdavConfig.username, 'u');
    });

    test('旧非手动 frequency 迁移为 autoUpload', () async {
      final store = LocalKeyValueStore();
      store.write(
        'verifin.backup_settings.v1',
        const BackupSettings(
          directoryUri: 'content://tree/backup',
          directoryLabel: 'backup',
          frequency: BackupFrequency.onOpen,
        ).encode(),
      );

      final controller = await makeController(store);
      expect(controller.backupTransportMode, BackupTransportMode.autoUpload);
      // 本地目录计划本身保留：它与传输模式是两件事，迁移不该顺手关掉它。
      expect(controller.backupSettings.frequency, BackupFrequency.onOpen);
      expect(controller.backupSettings.hasDirectory, isTrue);
    });

    test('两个旧值指向同一自动模式时不冲突', () async {
      final store = LocalKeyValueStore();
      store.write(
        'verifin.backup_settings.v1',
        const BackupSettings(frequency: BackupFrequency.onEntry).encode(),
      );
      store.write(
        'verifin.webdav.v1',
        const WebdavConfig(
          url: 'https://dav.example.com/v/',
          autoUpload: true,
        ).encode(),
      );

      final controller = await makeController(store);
      expect(controller.backupTransportMode, BackupTransportMode.autoUpload);
      expect(controller.backupTransportModeConflict, isFalse);
    });

    test('冲突的旧值（自动上传 + 非手动频率同时活跃）默认 autoUpload', () async {
      final store = LocalKeyValueStore();
      store.write(
        'verifin.backup_settings.v1',
        const BackupSettings(frequency: BackupFrequency.everyNHours).encode(),
      );
      store.write(
        'verifin.webdav.v1',
        const WebdavConfig(
          url: 'https://dav.example.com/v/',
          autoUpload: true,
        ).encode(),
      );

      final controller = await makeController(store);
      // 冲突消解不选更激进的 autoSync：无法判断用户意图时选最小惊讶的那个。
      expect(controller.backupTransportMode, BackupTransportMode.autoUpload);
      expect(controller.backupTransportModeConflict, isFalse);
    });

    test('迁移只发生一次：迁移后改模式不会又被旧值拉回去', () async {
      final store = LocalKeyValueStore();
      store.write(
        'verifin.webdav.v1',
        const WebdavConfig(
          url: 'https://dav.example.com/v/',
          autoUpload: true,
        ).encode(),
      );

      final first = await makeController(store);
      expect(first.backupTransportMode, BackupTransportMode.autoUpload);
      expect(
        await first.setBackupTransportMode(BackupTransportMode.manual),
        isTrue,
      );

      final second = await makeController(store);
      expect(
        second.backupTransportMode,
        BackupTransportMode.manual,
        reason: '规范键已存在，不该再按旧值重新推导',
      );
    });
  });

  group('互斥', () {
    test('开 autoSync 关掉 autoUpload，反之亦然', () async {
      final store = LocalKeyValueStore();
      final controller = await makeController(store);
      controller.setWebdavConfig(
        const WebdavConfig(
          url: 'https://dav.example.com/v/',
          username: 'u',
          password: 'p',
        ),
      );

      expect(
        await controller.setBackupTransportMode(BackupTransportMode.autoSync),
        isTrue,
      );
      expect(controller.backupTransportMode, BackupTransportMode.autoSync);
      expect(controller.webdavConfig.autoUpload, isFalse);
      expect(controller.backupTransportModeConflict, isFalse);

      expect(
        await controller.setBackupTransportMode(BackupTransportMode.autoUpload),
        isTrue,
      );
      expect(controller.backupTransportMode, BackupTransportMode.autoUpload);
      expect(controller.webdavConfig.autoUpload, isTrue);
      expect(controller.backupTransportModeConflict, isFalse);

      expect(
        await controller.setBackupTransportMode(BackupTransportMode.manual),
        isTrue,
      );
      expect(controller.backupTransportMode, BackupTransportMode.manual);
      expect(controller.webdavConfig.autoUpload, isFalse);
    });

    test('重开控制器不会同时报告两种自动模式', () async {
      final store = LocalKeyValueStore();
      final controller = await makeController(store);
      controller.setWebdavConfig(
        const WebdavConfig(url: 'https://dav.example.com/v/'),
      );
      await controller.setBackupTransportMode(BackupTransportMode.autoSync);

      final reloaded = await makeController(store);
      expect(reloaded.backupTransportMode, BackupTransportMode.autoSync);
      expect(reloaded.webdavConfig.autoUpload, isFalse);
      expect(
        reloaded.backupTransportModeConflict,
        isFalse,
        reason: 'autoSync 下旧的上传标记必须为 false，否则两种自动模式同时活跃',
      );
    });

    test('模式持久化到规范键且可跨重启保留', () async {
      final store = LocalKeyValueStore();
      final controller = await makeController(store);
      await controller.setBackupTransportMode(BackupTransportMode.autoSync);

      expect(store.read(canonicalKey), isNotNull);
      expect(
        BackupTransportModeCodec.decode(store.read(canonicalKey)),
        BackupTransportMode.autoSync,
      );

      final reloaded = await makeController(store);
      expect(reloaded.backupTransportMode, BackupTransportMode.autoSync);
    });
  });

  group('崩溃修复', () {
    test('规范键半份损坏时按未写入重新推导（而不是当成合法模式）', () async {
      final store = LocalKeyValueStore();
      // 模拟「写了一半」：JSON 结构像模像样，校验和不匹配。
      store.write(
        canonicalKey,
        '{"version":1,"mode":"autoSync","checksum":"truncated"}',
      );
      store.write(
        'verifin.webdav.v1',
        const WebdavConfig(
          url: 'https://dav.example.com/v/',
          autoUpload: true,
        ).encode(),
      );

      final controller = await makeController(store);
      expect(
        controller.backupTransportMode,
        BackupTransportMode.autoUpload,
        reason: '损坏值不可信，应从旧字段推导而不是采信那个半份的 autoSync',
      );
      expect(controller.backupTransportModeConflict, isFalse);
      // 修复结果要写回：下次启动不该再走一遍推导。
      expect(
        BackupTransportModeCodec.decode(store.read(canonicalKey)),
        BackupTransportMode.autoUpload,
      );
    });

    test('规范键完全不可解析时回落到手动模式', () async {
      final store = LocalKeyValueStore();
      store.write(canonicalKey, 'garbage');

      final controller = await makeController(store);
      expect(controller.backupTransportMode, BackupTransportMode.manual);
      expect(
        BackupTransportModeCodec.decode(store.read(canonicalKey)),
        BackupTransportMode.manual,
      );
    });

    test('恢复守卫把冲突状态复位到 autoUpload', () async {
      final store = LocalKeyValueStore();
      final controller = await makeController(store);
      controller.setWebdavConfig(
        const WebdavConfig(url: 'https://dav.example.com/v/'),
      );
      await controller.setBackupTransportMode(BackupTransportMode.autoSync);
      // 模拟绕过 setBackupTransportMode 的遗留路径重新打开上传标记。
      controller.setWebdavAutoUpload(true);
      expect(controller.backupTransportModeConflict, isTrue);

      expect(await controller.recoverBackupTransportMode(), isTrue);
      expect(controller.backupTransportModeConflict, isFalse);
      expect(controller.backupTransportMode, BackupTransportMode.autoUpload);
      expect(controller.webdavConfig.autoUpload, isTrue);
    });

    test('损坏的规范键 + 无旧值 = 手动，且不残留半份值', () async {
      final store = LocalKeyValueStore();
      store.write(canonicalKey, '{"version":1,"mode":"autoSync"}');

      final first = await makeController(store);
      expect(first.backupTransportMode, BackupTransportMode.manual);

      final second = await makeController(store);
      expect(second.backupTransportMode, BackupTransportMode.manual);
    });
  });
}
