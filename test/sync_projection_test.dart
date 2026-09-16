import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/sync/sync_models.dart';
import 'package:verifin/app/sync/sync_projection.dart';
import 'package:verifin/local_storage/local_storage.dart';

import 'support/test_harness.dart';

/// 构造一份最小导出结构：只需覆盖被断言的白名单键。
Map<String, Object?> sampleExportData({bool withEntry = true}) {
  return <String, Object?>{
    'app': 'verifin',
    'version': 3,
    'exportedAt': '2026-09-14T00:00:00.000',
    // 凭证类字段（不应进入投影）。
    'webdav': <String, Object?>{'url': 'https://dav.example', 'password': 'p'},
    'backupPassphrase': 'secret',
    'data': <String, Object?>{
      'ledgerBooks': <Object?>[
        <String, Object?>{'id': 'default', 'name': '日常账本'},
      ],
      'activeBookId': 'default',
      if (withEntry)
        'entries': <Object?>[
          <String, Object?>{
            'id': 'e1',
            'bookId': 'default',
            'type': 'expense',
            'amount': 12.5,
            'currencyCode': 'CNY',
            'baseAmount': 12.5,
            'categoryId': 'c1',
            'accountId': 'a1',
            'note': '午饭',
            'occurredAt': '2026-09-01T12:00:00.000',
            'refundedBaseAmount': 3.5,
          },
        ],
      'accounts': <Object?>[
        <String, Object?>{'id': 'a1', 'bookId': 'default', 'name': '现金'},
      ],
      'accountGroups': <Object?>[],
      'categories': <Object?>[
        <String, Object?>{'id': 'c1', 'label': '餐饮', 'type': 'expense'},
      ],
      'tags': <Object?>[
        <String, Object?>{'id': 't1', 'label': '出差'},
      ],
      'attachments': <Object?>[],
      'recurringRules': <Object?>[],
      'exchangeRates': <Object?>[],
      'monthlyBudgets': <String, Object?>{'default:2026-09': 1000.0},
      'categoryBudgets': <String, Object?>{'default:2026-09:c1': 200.5},
      'dailyBudgets': <String, Object?>{'default': 50.0},
      'budgetCycleStartDays': <String, Object?>{'default': 5},
      'profile': <String, Object?>{'nickname': '小明'},
      'themePreference': 'dark',
      'assetCoverUrl': '',
      'hapticsEnabled': true,
      'assetAccountViewMode': 'type',
      'collapsedAssetSections': <Object?>['default:type:cash'],
      'assetAccountOrders': <String, Object?>{
        'default:type': <Object?>['a1'],
      },
      'assetSectionOrders': <String, Object?>{
        'default:type': <Object?>['cash'],
      },
      'homePanels': <Object?>[
        <String, Object?>{'id': 'home.balance', 'enabled': true},
      ],
      'reportPanels': <Object?>[
        <String, Object?>{'id': 'report.trend', 'enabled': false},
      ],
      'defaultAccountIds': <String, Object?>{'default': 'a1'},
      'fabActionMode': 'manual',
      'amountForceTwoDecimals': false,
      'currencyFractionStyle': 'standard',
      'moneyUnitStyle': 'symbol',
      'hideUnitInSingleCurrency': true,
      'autoSuggestEnabled': true,
      'showRunningBalance': false,
      'homeTrendConfig': <String, Object?>{'range': 'thirtyDays'},
      'userWidgetDefinitions': <Object?>[
        <String, Object?>{'id': 'w1', 'name': '本月支出'},
      ],
    },
  };
}

SyncProjectionSnapshot projectionWithEntry(String id) {
  final data = sampleExportData();
  final root = Map<String, Object?>.from(data);
  root['data'] = <String, Object?>{
    ...(data['data']! as Map<String, Object?>),
    'entries': <Object?>[
      <String, Object?>{
        'id': id,
        'bookId': 'default',
        'type': 'expense',
        'amount': 1.0,
        'currencyCode': 'CNY',
        'baseAmount': 1.0,
        'categoryId': 'c1',
        'accountId': 'a1',
        'note': 'x',
        'occurredAt': '2026-09-01T12:00:00.000',
      },
    ],
  };
  return SyncProjection.fromExportData(root);
}

SyncProjectionSnapshot projectionWithoutEntry(String id) {
  final root = Map<String, Object?>.from(sampleExportData());
  root['data'] = <String, Object?>{
    ...(root['data']! as Map<String, Object?>),
    'entries': <Object?>[],
  };
  return SyncProjection.fromExportData(root);
}

void main() {
  useTestDatabases();

  group('SyncProjection.exportKeys', () {
    test(
      'projection includes every approved export key and excludes credentials',
      () {
        final snapshot = SyncProjection.fromExportData(sampleExportData());
        expect(SyncProjection.exportKeys, contains('userWidgetDefinitions'));
        expect(SyncProjection.exportKeys, contains('activeBookId'));
        expect(
          snapshot.entities.keys.any((key) => key.type == 'webdav'),
          isFalse,
        );
        expect(
          snapshot.entities.keys.any((key) => key.type.contains('Passphrase')),
          isFalse,
        );
      },
    );

    test('whitelist is the frozen首版清单，逐键固定', () {
      expect(SyncProjection.exportKeys, <String>{
        'ledgerBooks',
        'activeBookId',
        'entries',
        'accounts',
        'accountGroups',
        'categories',
        'tags',
        'attachments',
        'recurringRules',
        'exchangeRates',
        'monthlyBudgets',
        'categoryBudgets',
        'dailyBudgets',
        'budgetCycleStartDays',
        'profile',
        'themePreference',
        'assetCoverUrl',
        'hapticsEnabled',
        'assetAccountViewMode',
        'collapsedAssetSections',
        'assetAccountOrders',
        'assetSectionOrders',
        'homePanels',
        'reportPanels',
        'defaultAccountIds',
        'fabActionMode',
        'amountForceTwoDecimals',
        'currencyFractionStyle',
        'moneyUnitStyle',
        'hideUnitInSingleCurrency',
        'autoSuggestEnabled',
        'showRunningBalance',
        'homeTrendConfig',
        'userWidgetDefinitions',
      });
    });

    test('导出里缺少的键不产生实体，也不抛错', () {
      final root = Map<String, Object?>.from(sampleExportData());
      root['data'] = <String, Object?>{'activeBookId': 'default'};
      final snapshot = SyncProjection.fromExportData(root);
      expect(snapshot.entities.length, 1);
      expect(snapshot.entities.keys.single.id, 'singleton');
    });
  });

  group('实体键约定', () {
    test('标量键为 global/<key>/singleton', () {
      final snapshot = SyncProjection.fromExportData(sampleExportData());
      final theme = snapshot.entity(
        const SyncEntityKey(
          scope: 'global',
          type: 'themePreference',
          id: 'singleton',
        ),
      );
      expect(theme, isNotNull);
      expect(theme!.payload, 'dark');
    });

    test('列表按 id 拆分为 ledger 作用域实体，ledgerBooks 用 global', () {
      final snapshot = SyncProjection.fromExportData(sampleExportData());
      expect(
        snapshot.entity(
          const SyncEntityKey(scope: 'ledger', type: 'entries', id: 'e1'),
        ),
        isNotNull,
      );
      expect(
        snapshot.entity(
          const SyncEntityKey(
            scope: 'global',
            type: 'ledgerBook',
            id: 'default',
          ),
        ),
        isNotNull,
      );
    });

    test('预算 map 按键拆分为独立实体，避免无关字段互相覆盖', () {
      final snapshot = SyncProjection.fromExportData(sampleExportData());
      final monthly = snapshot.entity(
        const SyncEntityKey(
          scope: 'global',
          type: 'monthlyBudgets',
          id: 'default:2026-09',
        ),
      );
      final category = snapshot.entity(
        const SyncEntityKey(
          scope: 'global',
          type: 'categoryBudgets',
          id: 'default:2026-09:c1',
        ),
      );
      expect(monthly?.payload, 1000.0);
      expect(category?.payload, 200.5);
    });

    test('排序数组按 position token 拆分，且 token 稳定', () {
      final first = SyncProjection.fromExportData(sampleExportData());
      final second = SyncProjection.fromExportData(sampleExportData());
      final firstKeys = first.entities.keys
          .where((key) => key.type == 'assetAccountOrders')
          .toList();
      final secondKeys = second.entities.keys
          .where((key) => key.type == 'assetAccountOrders')
          .toList();
      expect(firstKeys, isNotEmpty);
      expect(firstKeys.first.id, 'default:type:0');
      expect(secondKeys.map((key) => key.id).toList(), [
        for (final key in firstKeys) key.id,
      ]);
      expect(first.entities[firstKeys.first]!.payloadHash, isNotEmpty);
    });
  });

  group('规范化', () {
    test('键顺序不同不产生 hash 差异', () {
      final a = SyncProjection.fromExportData(sampleExportData());
      final shuffled = Map<String, Object?>.from(sampleExportData());
      final data = Map<String, Object?>.from(shuffled['data']! as Map);
      shuffled['data'] = <String, Object?>{
        for (final entry in data.entries) entry.key: entry.value,
      };
      final b = SyncProjection.fromExportData(shuffled);
      expect(
        a.entities.values.map((e) => e.payloadHash).toSet(),
        b.entities.values.map((e) => e.payloadHash).toSet(),
      );
    });

    test('数值表示归一：int 1 与 double 1.0 同 hash', () {
      SyncProjectionSnapshot build(Object amount) {
        final root = Map<String, Object?>.from(sampleExportData());
        root['data'] = <String, Object?>{
          ...(root['data']! as Map<String, Object?>),
          'monthlyBudgets': <String, Object?>{'default:2026-09': amount},
        };
        return SyncProjection.fromExportData(root);
      }

      const key = SyncEntityKey(
        scope: 'global',
        type: 'monthlyBudgets',
        id: 'default:2026-09',
      );
      expect(
        build(1).entities[key]!.payloadHash,
        build(1.0).entities[key]!.payloadHash,
      );
    });

    test('refundedBaseAmount 是可重算派生字段，不进竞争 payload', () {
      final snapshot = SyncProjection.fromExportData(sampleExportData());
      final entry = snapshot.entity(
        const SyncEntityKey(scope: 'ledger', type: 'entries', id: 'e1'),
      );
      expect(
        (entry!.payload! as Map<String, Object?>).containsKey(
          'refundedBaseAmount',
        ),
        isFalse,
      );
      // 但聚合引用仍在：应用整批后可按退款条目重算。
      expect((entry.payload! as Map<String, Object?>)['bookId'], 'default');
      expect(entry.payloadHash, computeSyncPayloadHash(entry.payload));
    });
  });

  group('SyncProjection.diff', () {
    test(
      'projection diff emits delete tombstone instead of inferring absence remotely',
      () {
        final previous = projectionWithEntry('e1');
        final next = projectionWithoutEntry('e1');
        final mutation = SyncProjection.diff(previous, next).single;
        expect(mutation.operation, SyncOperationKind.delete);
        expect(mutation.entity.id, 'e1');
        expect(mutation.entity.type, 'entries');
        expect(mutation.payload, isNull);
      },
    );

    test('未变化的实体不产生事件', () {
      final snapshot = SyncProjection.fromExportData(sampleExportData());
      expect(SyncProjection.diff(snapshot, snapshot), isEmpty);
    });

    test('新增实体产生 upsert，携带完整 payload', () {
      final before = projectionWithoutEntry('e1');
      final after = projectionWithEntry('e1');
      final mutations = SyncProjection.diff(before, after);
      final upsert = mutations.single;
      expect(upsert.operation, SyncOperationKind.upsert);
      expect(
        upsert.entity,
        const SyncEntityKey(scope: 'ledger', type: 'entries', id: 'e1'),
      );
      expect((upsert.payload! as Map<String, Object?>)['id'], 'e1');
    });

    test('同一批次的批量差异共享 batchId，删除排在后（先 upsert 后 tombstone）', () {
      final before = projectionWithEntry('e1');
      final root = Map<String, Object?>.from(sampleExportData());
      root['data'] = <String, Object?>{
        ...(root['data']! as Map<String, Object?>),
        'entries': <Object?>[
          <String, Object?>{
            'id': 'e2',
            'bookId': 'default',
            'type': 'expense',
            'amount': 2.0,
            'currencyCode': 'CNY',
            'baseAmount': 2.0,
            'categoryId': 'c1',
            'accountId': 'a1',
            'note': 'y',
            'occurredAt': '2026-09-02T12:00:00.000',
          },
        ],
      };
      final after = SyncProjection.fromExportData(root);
      final mutations = SyncProjection.diff(before, after, batchId: 'batch-1');
      expect(mutations.length, 2);
      expect(mutations.map((m) => m.batchId).toSet(), <String>{'batch-1'});
      expect(mutations.first.operation, SyncOperationKind.upsert);
      expect(mutations.first.entity.id, 'e2');
      expect(mutations.last.operation, SyncOperationKind.delete);
      expect(mutations.last.entity.id, 'e1');
    });

    test('diff 输出顺序确定（按 key 排序），重复调用结果一致', () {
      final before = projectionWithEntry('e1');
      final after = projectionWithoutEntry('e1');
      final first = SyncProjection.diff(before, after, batchId: 'b');
      final second = SyncProjection.diff(before, after, batchId: 'b');
      expect(
        first.map((m) => m.entity.toString()).toList(),
        second.map((m) => m.entity.toString()).toList(),
      );
    });
  });

  group('decodeExportData', () {
    test('可解析 exportDataJson 产出的 JSON 文本', () {
      final snapshot = SyncProjection.fromExportData(
        SyncProjection.decodeExportData(
          const JsonEncoder.withIndent('  ').convert(sampleExportData()),
        ),
      );
      expect(snapshot.entities, isNotEmpty);
    });
  });

  group('导出与白名单的一致性', () {
    test('真实导出的每个数据键都在白名单内（新增备份字段必须显式决定是否同步）', () async {
      final controller = await makeController(LocalKeyValueStore());
      final exported = controller.exportDataSection().keys.toSet();
      final unexpected = exported.difference(SyncProjection.exportKeys);
      expect(
        unexpected,
        isEmpty,
        reason:
            '这些导出键不在同步白名单里：要么加入 SyncProjection.exportKeys，'
            '要么在设计文档里说明它为什么属于设备本地数据',
      );
      controller.dispose();
    });

    test('白名单里唯一尚未进入导出的键是 userWidgetDefinitions', () async {
      final controller = await makeController(LocalKeyValueStore());
      final exported = controller.exportDataSection().keys.toSet();
      // 小组件定义存在设备本地 KV（WidgetConfigStore），当前 exportDataJson 没有
      // 输出它。白名单保留该键以匹配设计文档；等导出补上后本断言会失败，
      // 提醒把它从例外名单里移除。
      expect(SyncProjection.exportKeys.difference(exported), <String>{
        'userWidgetDefinitions',
      });
      controller.dispose();
    });

    test('导出与投影共用同一份数据：投影能覆盖导出的关键实体', () async {
      final controller = await makeController(LocalKeyValueStore());
      final snapshot = SyncProjection.fromExportData(
        controller.exportDataSection(),
      );
      // 播种后至少应有账本、分类、条目的实体。
      final types = snapshot.entities.keys.map((key) => key.type).toSet();
      expect(types, contains('ledgerBook'));
      expect(types, contains('categories'));
      expect(types, contains('activeBookId'));
      controller.dispose();
    });

    test('凭证类字段即使出现在导出里也不会进入投影', () {
      final root = Map<String, Object?>.from(sampleExportData());
      root['backupPassphrase'] = 'secret';
      (root['data']! as Map<String, Object?>)['backupPassphrase'] = 'secret';
      (root['data']! as Map<String, Object?>)['webdav'] = <String, Object?>{
        'url': 'https://dav.example',
        'password': 'p',
      };
      final snapshot = SyncProjection.fromExportData(root);
      final types = snapshot.entities.keys.map((key) => key.type).toSet();
      expect(types.contains('backupPassphrase'), isFalse);
      expect(types.contains('webdav'), isFalse);
      expect(
        snapshot.entities.values.any(
          (entity) => entity.payloadHash == computeSyncPayloadHash('secret'),
        ),
        isFalse,
      );
    });
  });
}
