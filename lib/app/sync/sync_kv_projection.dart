import 'dart:convert';

/// 把「远端单个实体片段」合并进「本地某个 KV 偏好键的完整值」，产出可以直接
/// `writeAndFlush` 进 [LocalKeyValueStore] 的字符串。
///
/// 背景：[SyncProjection.fromExportData] 把 profile/主题/面板/资产排序/默认账户/
/// 小组件定义等偏好拆成一个个独立实体（单值一个、map 每键一个、列表每项一个、
/// 排序数组每个位置一个），这样远端 diff 才能精确到字段级。但本地这些偏好各自
/// 只有**一个** KV 键存整份数据（如 `verifin.default_account.v1` 存整个
/// `Map<bookId, accountId>`）——应用一个远端片段前必须先读出本地当前的完整值、
/// 把这一个片段的改动叠上去，再整份写回，不能只写片段本身（那会把同键下其余
/// 未变的部分覆盖掉）。
///
/// 只覆盖 Task 6 范围内点名的类别（profile/主题/面板/排序/默认账户/FAB/金额/
/// 小组件定义）；[storageKeyFor] 对不在表里的类型返回 null，调用方据此判断
/// 「这不是一个走 KV journal 的类型」而不是把它当错误处理——SQLite 落库的账目类
/// 实体（entries/accounts/…）走的是另一条路径，本模块不关心。
abstract final class SyncKvProjection {
  /// 同步实体 `type` → 本地 [LocalKeyValueStore] 键。仅覆盖 Task 6 范围内的类别；
  /// 键名取自 `veri_fin_controller.dart` 的 `_xxxKey` 常量（此处用字面量而非引用，
  /// 避免本模块反向依赖控制器文件）。
  static const Map<String, String> storageKeys = <String, String>{
    'profile': 'verifin.profile.v1',
    'themePreference': 'verifin.theme.v1',
    'fabActionMode': 'verifin.fab_action.v1',
    'amountForceTwoDecimals': 'verifin.amount_format.v1',
    'homePanels': 'verifin.home_panels.v1',
    'reportPanels': 'verifin.report_panels.v1',
    'assetAccountOrders': 'verifin.asset_account_order.v1',
    'assetSectionOrders': 'verifin.asset_section_order.v1',
    'defaultAccountIds': 'verifin.default_account.v1',
    'userWidgetDefinitions': 'verifin.widget_definitions.v1',
  };

  /// 单值类型（新值整体替换旧值，不需要拿旧值来合并）。
  static const Set<String> _singletonTypes = <String>{
    'profile',
    'themePreference',
    'fabActionMode',
    'amountForceTwoDecimals',
  };

  /// map-per-key 类型：整份值是 `Map<String, Object?>`，片段的 `entity.id` 是键。
  static const Set<String> _mapPerKeyTypes = <String>{'defaultAccountIds'};

  /// 顺序类型：整份值是 `Map<containerKey, List<id>>`，片段的 `entity.id` 编码为
  /// `"container:position"`，payload 形如 `{'container':…, 'position':…, 'id':…}`
  /// （与 [SyncProjection.fromExportData] 的 `_orderKeys` 分支互为逆运算）。
  static const Set<String> _orderTypes = <String>{
    'assetAccountOrders',
    'assetSectionOrders',
  };

  /// 列表类型：整份值是 `List<Map>`，片段按 `id` 字段定位。
  static const Set<String> _listTypes = <String>{
    'homePanels',
    'reportPanels',
    'userWidgetDefinitions',
  };

  static String? storageKeyFor(String entityType) => storageKeys[entityType];

  /// 是否是本模块认识的 KV 偏好类型（决定要不要为这条事件生成 journal 行）。
  static bool isKvPreferenceType(String entityType) =>
      storageKeys.containsKey(entityType);

  /// 合并一个远端片段到 [currentValue]（该 KV 键当前的**已解码**完整值，取自
  /// `SyncProjectionSource.exportDataForSync()` 对应键；从未出现过时为 null，
  /// 按空集合/空表处理），返回写入 [LocalKeyValueStore] 时应使用的确切字符串。
  ///
  /// 返回 null 表示 [entityType] 不在本模块范围内，调用方不应生成 journal 行。
  static String? mergeToStorageValue({
    required String entityType,
    required String entityId,
    required Object? currentValue,
    required Object? payload,
    required bool deleted,
  }) {
    if (_singletonTypes.contains(entityType)) {
      return _encodeSingleton(entityType, payload, deleted, currentValue);
    }
    if (_mapPerKeyTypes.contains(entityType)) {
      final map = _asStringMap(currentValue);
      if (deleted) {
        map.remove(entityId);
      } else {
        map[entityId] = payload;
      }
      return jsonEncode(map);
    }
    if (_orderTypes.contains(entityType)) {
      final containers = _asOrderContainers(currentValue);
      final separator = entityId.indexOf(':');
      if (separator <= 0) {
        // 片段 id 格式不对：保守起见原样返回当前值，不引入损坏数据。
        return jsonEncode(containers);
      }
      final containerKey = entityId.substring(0, separator);
      final position = int.tryParse(entityId.substring(separator + 1));
      if (position == null || position < 0) {
        return jsonEncode(containers);
      }
      final list = containers.putIfAbsent(containerKey, () => <Object?>[]);
      if (deleted) {
        if (position < list.length) {
          list.removeAt(position);
        }
      } else {
        final id = payload is Map ? payload['id'] : null;
        while (list.length <= position) {
          list.add(null);
        }
        list[position] = id;
      }
      // 清理占位 null（片段乱序到达时可能留下的空位），避免把 null 写进顺序列表。
      list.removeWhere((item) => item == null);
      return jsonEncode(containers);
    }
    if (_listTypes.contains(entityType)) {
      final list = _asMapList(currentValue);
      final index = list.indexWhere((item) => item['id'] == entityId);
      if (deleted) {
        if (index >= 0) {
          list.removeAt(index);
        }
      } else if (payload is Map) {
        final normalized = Map<String, Object?>.from(
          payload.cast<String, Object?>(),
        );
        if (index >= 0) {
          list[index] = normalized;
        } else {
          list.add(normalized);
        }
      }
      return jsonEncode(list);
    }
    return null;
  }

  static String _encodeSingleton(
    String entityType,
    Object? payload,
    bool deleted,
    Object? currentValue,
  ) {
    // 单值字段没有「删除」语义（都有非空默认值）；远端若真送来 delete，保留本地
    // 当前值而不是清空——清空一个主题/头像字段没有对应的"未设置"合法状态。
    final value = deleted ? currentValue : payload;
    switch (entityType) {
      case 'profile':
        return jsonEncode(value);
      case 'amountForceTwoDecimals':
        return (value == true).toString();
      case 'themePreference':
      case 'fabActionMode':
      default:
        return value?.toString() ?? '';
    }
  }

  static Map<String, Object?> _asStringMap(Object? value) {
    if (value is Map) {
      return Map<String, Object?>.from(value.cast<String, Object?>());
    }
    return <String, Object?>{};
  }

  static Map<String, List<Object?>> _asOrderContainers(Object? value) {
    final result = <String, List<Object?>>{};
    if (value is Map) {
      for (final entry in value.cast<Object?, Object?>().entries) {
        if (entry.value is List) {
          result[entry.key.toString()] = List<Object?>.of(entry.value as List);
        }
      }
    }
    return result;
  }

  static List<Map<String, Object?>> _asMapList(Object? value) {
    if (value is List) {
      return <Map<String, Object?>>[
        for (final item in value)
          if (item is Map)
            Map<String, Object?>.from(item.cast<String, Object?>()),
      ];
    }
    return <Map<String, Object?>>[];
  }
}
