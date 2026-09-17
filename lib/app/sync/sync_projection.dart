import 'dart:convert';

import 'sync_models.dart';

/// `exportDataJson()` 白名单到同步实体的规范化投影。
///
/// 设计约束（来自 `docs/superpowers/specs/2026-09-13-webdav-bidirectional-sync-design.md`
/// 「数据边界」）：
/// - **显式白名单**，不按整份 JSON 推断。新增/删除备份字段必须同步更新
///   [SyncProjection.exportKeys]，否则字段静默不同步；反之凭证类字段永远不会
///   因为「恰好也在导出里」而泄漏。
/// - **拆分粒度按实体**：预算 map 按键拆分、偏好按字段拆分，避免「改一个字段
///   覆盖整组无关偏好」。
/// - **删除必须显式**：[SyncProjection.diff] 对消失的实体产出 tombstone，绝不依赖
///   「远端某次扫描缺少文件」来推断删除。
/// - **派生字段不竞争**：`LedgerEntry.refundedBaseAmount` 由已到账退款重算，从
///   payload 中剔除，避免两个设备各带一份缓存值互相覆盖。
class SyncProjection {
  const SyncProjection._();

  /// 首版冻结的导出白名单，逐键与设计文档一致。
  ///
  /// 注意：`userWidgetDefinitions` 在清单中，但当前 `exportDataJson()` 并未输出该键
  /// （小组件定义存在设备本地 KV）。投影对缺失键是「不产生实体」而不是报错，
  /// 因此这里保留它以匹配清单；等导出补上该键时无需再改白名单。
  static const Set<String> exportKeys = <String>{
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
    'budgetPeriodKinds',
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
  };

  /// 按 `id` 拆分的列表类键：每个元素一个实体。
  ///
  /// `ledgerBooks` 单列，因为它是账本本身——作用域归 `global`，其余实体的
  /// `bookId` 才决定归属账本。
  static const Map<String, String> _listEntityTypes = <String, String>{
    'ledgerBooks': 'ledgerBook',
    'entries': 'entries',
    'accounts': 'accounts',
    'accountGroups': 'accountGroups',
    'categories': 'categories',
    'tags': 'tags',
    'attachments': 'attachments',
    'recurringRules': 'recurringRules',
    'exchangeRates': 'exchangeRates',
    'homePanels': 'homePanels',
    'reportPanels': 'reportPanels',
    'userWidgetDefinitions': 'userWidgetDefinitions',
  };

  /// 列表类实体里作用域为 `global` 的键（其余按 `ledger`）。
  static const Set<String> _globalScopedListKeys = <String>{'ledgerBooks'};

  /// 按 map 键拆分的键：每个键一个实体，值即 payload。
  static const Set<String> _mapPerKeyKeys = <String>{
    'monthlyBudgets',
    'categoryBudgets',
    'dailyBudgets',
    'budgetCycleStartDays',
    'budgetPeriodKinds',
    'defaultAccountIds',
  };

  /// 顺序数组：`{容器键: [id, …]}`，每个位置一个 position token 实体。
  ///
  /// 模型里没有持久化的顺序字段（列表顺序即真相），因此投影阶段从当前顺序生成
  /// token。并发移动时两侧保留各自的 order 版本，由冲突决议决定最终顺序；
  /// 这与「依赖列表顺序不能依赖当前数组位置」的要求一致——payload 里带上了该项的
  /// id，而不只是一个裸下标。
  static const Set<String> _orderKeys = <String>{
    'assetAccountOrders',
    'assetSectionOrders',
  };

  /// 标量/对象键：整键一个 `singleton` 实体。
  static const Set<String> _singletonKeys = <String>{
    'activeBookId',
    'profile',
    'themePreference',
    'assetCoverUrl',
    'hapticsEnabled',
    'assetAccountViewMode',
    'collapsedAssetSections',
    'fabActionMode',
    'amountForceTwoDecimals',
    'currencyFractionStyle',
    'moneyUnitStyle',
    'hideUnitInSingleCurrency',
    'autoSuggestEnabled',
    'showRunningBalance',
    'homeTrendConfig',
  };

  /// 派生字段：由整批已到账退款重算，不作为可竞争字段同步。
  static const Set<String> _derivedEntryFields = <String>{'refundedBaseAmount'};

  /// 从 `exportDataJson()` 产出的文本解析出根对象。
  ///
  /// 与 `exportDataJson()` 成对：调用方拿到字符串就直接传进来，不必自己
  /// `jsonDecode` 再确认它是不是 `Map`。格式不对时抛 [FormatException]。
  static Map<String, Object?> decodeExportData(String rawJson) {
    final Object? decoded;
    try {
      decoded = jsonDecode(rawJson);
    } on FormatException {
      throw const FormatException('导出数据不是合法 JSON');
    }
    if (decoded is! Map) {
      throw const FormatException('导出数据根节点不是对象');
    }
    return Map<String, Object?>.from(decoded);
  }

  /// 把导出根对象投影为规范化实体快照。
  ///
  /// 接受两种形状：完整导出（`{'data': {…}}`）与直接的 `data` 内容。这对测试与
  /// 后续「只传 data 段」的调用方都友好，且判定只看键名不看层级深度。
  static SyncProjectionSnapshot fromExportData(Map<String, Object?> root) {
    final data = _dataSection(root);
    final entities = <SyncEntityKey, SyncProjectedEntity>{};

    void add(SyncEntityKey key, Object? payload) {
      final normalized = normalizeValue(payload);
      entities[key] = SyncProjectedEntity(
        key: key,
        payload: normalized,
        payloadHash: computeSyncPayloadHash(normalized),
      );
    }

    for (final entry in data.entries) {
      final key = entry.key;
      if (!exportKeys.contains(key)) {
        continue;
      }
      final value = entry.value;

      if (_singletonKeys.contains(key)) {
        add(SyncEntityKey(scope: 'global', type: key, id: _singletonId), value);
        continue;
      }

      if (_mapPerKeyKeys.contains(key)) {
        if (value is! Map) {
          continue;
        }
        for (final item in value.entries) {
          final mapKey = item.key.toString();
          if (mapKey.isEmpty) {
            continue;
          }
          add(
            SyncEntityKey(scope: 'global', type: key, id: mapKey),
            item.value,
          );
        }
        continue;
      }

      if (_orderKeys.contains(key)) {
        if (value is! Map) {
          continue;
        }
        for (final container in value.entries) {
          final containerKey = container.key.toString();
          final rawList = container.value;
          if (rawList is! List) {
            continue;
          }
          for (var index = 0; index < rawList.length; index++) {
            add(
              SyncEntityKey(
                scope: 'global',
                type: key,
                id: '$containerKey:$index',
              ),
              <String, Object?>{
                'container': containerKey,
                'position': index,
                'id': rawList[index],
              },
            );
          }
        }
        continue;
      }

      final listType = _listEntityTypes[key];
      if (listType != null) {
        if (value is! List) {
          continue;
        }
        var index = 0;
        for (final item in value) {
          final id = _itemId(item) ?? '$key#$index';
          index++;
          add(
            SyncEntityKey(
              scope: _globalScopedListKeys.contains(key) ? 'global' : 'ledger',
              type: listType,
              id: id,
            ),
            _sanitize(key, item),
          );
        }
        continue;
      }

      // 白名单内但未归类的键：按标量处理，宁可多同步一个字段也不要静默丢弃。
      add(SyncEntityKey(scope: 'global', type: key, id: _singletonId), value);
    }

    return SyncProjectionSnapshot(entities: entities);
  }

  /// Inverse of the whitelist projection. Fold a complete batch before parsing
  /// references: a transaction may reference an account created later in it.
  static Map<String, Object?> applyVersions(
    Map<String, Object?> current,
    Iterable<SyncEntityVersion> versions,
  ) {
    final data = Map<String, Object?>.from(_dataSection(current));
    final entities = Map<SyncEntityKey, SyncProjectedEntity>.of(
      fromExportData(data).entities,
    );
    final changedTypes = <String>{};
    for (final version in versions) {
      final key = version.entity;
      final exportKey = key.type == 'ledgerBook' ? 'ledgerBooks' : key.type;
      if (!exportKeys.contains(exportKey)) {
        throw FormatException('Unsupported sync entity type: ${key.type}');
      }
      changedTypes.add(exportKey);
      if (version.deleted) {
        entities.remove(key);
      } else {
        if (_listEntityTypes.containsKey(exportKey) &&
            (version.payload is! Map ||
                (version.payload as Map)['id'] != key.id)) {
          throw const FormatException('Sync entity identity mismatch');
        }
        entities[key] = SyncProjectedEntity(
          key: key,
          payload: version.payload,
          payloadHash: version.payloadHash,
        );
      }
    }
    for (final exportKey in changedTypes) {
      final type = _listEntityTypes[exportKey] ?? exportKey;
      final items = entities.values.where((e) => e.key.type == type).toList();
      if (_listEntityTypes.containsKey(exportKey)) {
        data[exportKey] = items.map((e) => e.payload).toList();
      } else if (_mapPerKeyKeys.contains(exportKey)) {
        data[exportKey] = <String, Object?>{
          for (final e in items) e.key.id: e.payload,
        };
      } else if (_orderKeys.contains(exportKey)) {
        final containers = <String, Map<int, Object?>>{};
        for (final item in items) {
          final payload = item.payload;
          if (payload is! Map ||
              payload['container'] is! String ||
              payload['position'] is! int ||
              payload['id'] is! String ||
              (payload['position'] as int) < 0 ||
              item.key.id != '${payload['container']}:${payload['position']}') {
            throw const FormatException('Invalid sync order');
          }
          containers.putIfAbsent(
            payload['container'] as String,
            () => {},
          )[payload['position'] as int] = payload['id'];
        }
        data[exportKey] = <String, Object?>{
          for (final entry in containers.entries)
            entry.key: (entry.value.keys.toList()..sort())
                .map((position) => entry.value[position])
                .toList(),
        };
      } else {
        if (items.isEmpty) {
          data.remove(exportKey);
        } else {
          data[exportKey] = items.single.payload;
        }
      }
    }
    return data;
  }

  /// 比较两份投影，产出本地变更。
  ///
  /// 顺序确定：先 upsert（按实体键排序）后 delete（按实体键排序）。删除排在后面
  /// 是为了让同一批内「先建后删」的语义在事件流里保持可读；两者不冲突，因为 key
  /// 互斥（一个实体不可能同时新增与消失）。
  ///
  /// 传入 [batchId] 时同一批差异共用一个批次；不传则每批一个随机批次 id。
  static List<SyncLocalMutation> diff(
    SyncProjectionSnapshot before,
    SyncProjectionSnapshot after, {
    String? batchId,
  }) {
    final batch = batchId ?? 'local-${_randomId()}';

    final upserts = <SyncLocalMutation>[];
    for (final entry in after.entities.entries) {
      final previous = before.entities[entry.key];
      if (previous != null && previous.payloadHash == entry.value.payloadHash) {
        continue;
      }
      upserts.add(
        SyncLocalMutation(
          entity: entry.key,
          operation: SyncOperationKind.upsert,
          payload: entry.value.payload,
          batchId: batch,
        ),
      );
    }

    final deletes = <SyncLocalMutation>[];
    for (final key in before.entities.keys) {
      if (after.entities.containsKey(key)) {
        continue;
      }
      deletes.add(
        SyncLocalMutation(
          entity: key,
          operation: SyncOperationKind.delete,
          payload: null,
          batchId: batch,
        ),
      );
    }

    upserts.sort((a, b) => _compareKeys(a.entity, b.entity));
    deletes.sort((a, b) => _compareKeys(a.entity, b.entity));
    return <SyncLocalMutation>[...upserts, ...deletes];
  }

  /// 规范化任意导出值：map 键排序、数字归一到可比较表示、列表递归。
  ///
  /// 目的不是「好看」，而是让**语义相同**的两份数据得到同一个 hash。JSON 里 int 1
  /// 与 double 1.0 在 Dart 中是 `1 == 1.0` 但 `1.toString() != '1.0'.toString()`，
  /// 若直接沿用原始表示，一次「读了再写」就会让每个数值字段都看起来变过，
  /// 把静默重写放大成整库重传。
  static Object? normalizeValue(Object? value) {
    if (value == null) {
      return null;
    }
    if (value is num) {
      return _normalizeNumber(value);
    }
    if (value is Map) {
      final map = value.cast<Object?, Object?>();
      final keys = map.keys.cast<String>().toList()..sort();
      return <String, Object?>{
        for (final key in keys) key: normalizeValue(map[key]),
      };
    }
    if (value is Iterable) {
      return <Object?>[for (final item in value) normalizeValue(item)];
    }
    if (value is bool || value is String) {
      return value;
    }
    // 未预期的类型（枚举、日期对象等）：退化为字符串，保证 hash 可计算而不是抛错。
    return value.toString();
  }

  /// 数值归一到规范 JSON。整数写成不带小数点的形式，与 `jsonEncode(1.0) == '1.0'`
  /// 的差异正是必须消除的那一处。
  static Object _normalizeNumber(num value) {
    if (value is int) {
      return value;
    }
    if (value == value.roundToDouble() && value.abs() < 1e15) {
      return value.toInt();
    }
    return value.toDouble();
  }

  /// 剔除派生字段。当前只有交易条目的 `refundedBaseAmount`。
  static Object? _sanitize(String exportKey, Object? item) {
    if (exportKey != 'entries' || item is! Map) {
      return item;
    }
    return <String, Object?>{
      for (final entry in item.entries)
        if (!_derivedEntryFields.contains(entry.key.toString()))
          entry.key.toString(): entry.value,
    };
  }

  static String? _itemId(Object? item) {
    if (item is! Map) {
      return null;
    }
    final raw = item['id'];
    if (raw == null) {
      return null;
    }
    final id = raw.toString();
    return id.isEmpty ? null : id;
  }

  /// 取数据段：完整导出用 `data`，否则认为传入的就是 data 内容。
  static Map<String, Object?> _dataSection(Map<String, Object?> root) {
    final data = root['data'];
    if (data is Map &&
        data.cast<Object?, Object?>().keys.any(
          (key) => exportKeys.contains('$key'),
        )) {
      return Map<String, Object?>.from(data);
    }
    if (root.keys.any(exportKeys.contains)) {
      return root;
    }
    // 既没有 data 段也没有任何白名单键：空投影比抛错更合适——「没有可同步内容」
    // 是合法状态（全新未播种的库），不该让调用方去区分这种边界。
    return const <String, Object?>{};
  }

  static int _compareKeys(SyncEntityKey a, SyncEntityKey b) {
    final byScope = a.scope.compareTo(b.scope);
    if (byScope != 0) return byScope;
    final byType = a.type.compareTo(b.type);
    if (byType != 0) return byType;
    return a.id.compareTo(b.id);
  }

  static String _randomId() {
    final now = DateTime.now().microsecondsSinceEpoch;
    return '$now-${_sequence++}';
  }

  static int _sequence = 0;

  /// 标量实体的固定 id。
  static const String _singletonId = 'singleton';
}

/// 一次投影的不可变快照。
class SyncProjectionSnapshot {
  const SyncProjectionSnapshot({
    required Map<SyncEntityKey, SyncProjectedEntity> entities,
    // ignore: prefer_initializing_formals — 私有字段不能作具名初始化形参。
  }) : _entities = entities;

  final Map<SyncEntityKey, SyncProjectedEntity> _entities;

  /// 实体键 → 投影实体（只读视图）。
  Map<SyncEntityKey, SyncProjectedEntity> get entities =>
      Map<SyncEntityKey, SyncProjectedEntity>.unmodifiable(_entities);

  /// 按键取实体；不存在返回 null。
  SyncProjectedEntity? entity(SyncEntityKey key) => _entities[key];

  /// 键 → payload hash，供与 `sync_shadow` 直接比较。
  Map<SyncEntityKey, String> get payloadHashes => <SyncEntityKey, String>{
    for (final entry in _entities.entries) entry.key: entry.value.payloadHash,
  };

  bool get isEmpty => _entities.isEmpty;
}
