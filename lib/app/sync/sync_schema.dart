import '../currency_catalog.dart';
import '../models.dart';
import '../home_metrics.dart';
import '../widget_config.dart';

/// Remote data is protocol input, not a legacy backup. Reject incomplete or
/// coercible payloads before tolerant model decoders can invent defaults.
abstract final class SyncSchema {
  static void validateIncoming(String type, Object? payload) {
    Never invalid() => throw FormatException('Invalid sync schema: $type');
    final key = type == 'ledgerBook' ? 'ledgerBooks' : type;
    const objects = {
      'ledgerBooks',
      'accounts',
      'accountGroups',
      'categories',
      'tags',
      'attachments',
      'entries',
      'recurringRules',
      'exchangeRates',
      'profile',
      'homeTrendConfig',
      'homePanels',
      'reportPanels',
      'userWidgetDefinitions',
    };
    if (objects.contains(key)) {
      if (payload is! Map) invalid();
      validate(key, Map<String, Object?>.from(payload));
      return;
    }
    const booleans = {
      'hapticsEnabled',
      'amountForceTwoDecimals',
      'hideUnitInSingleCurrency',
      'autoSuggestEnabled',
      'showRunningBalance',
    };
    if (booleans.contains(key)) {
      if (payload is! bool) invalid();
      return;
    }
    final enums = <String, Iterable<String>>{
      'themePreference': ThemePreference.values.map((e) => e.name),
      'assetAccountViewMode': AssetAccountViewMode.values.map((e) => e.name),
      'fabActionMode': FabActionMode.values.map((e) => e.name),
      'currencyFractionStyle': CurrencyFractionStyle.values.map((e) => e.name),
      'moneyUnitStyle': MoneyUnitStyle.values.map((e) => e.name),
      'budgetPeriodKinds': BudgetPeriodKind.values.map((e) => e.name),
    };
    if (enums.containsKey(key)) {
      if (!enums[key]!.contains(payload)) invalid();
      return;
    }
    if ({'activeBookId', 'assetCoverUrl', 'defaultAccountIds'}.contains(key)) {
      if (payload is! String) invalid();
      return;
    }
    if (key == 'collapsedAssetSections') {
      if (payload is! List || !payload.every((v) => v is String)) invalid();
      return;
    }
    if (key == 'budgetCycleStartDays') {
      if (payload is! int || payload < 1 || payload > 28) invalid();
      return;
    }
    if ({'monthlyBudgets', 'categoryBudgets', 'dailyBudgets'}.contains(key)) {
      if (payload is! num || !payload.isFinite || payload < 0) invalid();
      return;
    }
    if ({'assetAccountOrders', 'assetSectionOrders'}.contains(key)) {
      if (payload is! Map ||
          payload['container'] is! String ||
          payload['id'] is! String ||
          payload['position'] is! int ||
          (payload['position'] as int) < 0) {
        invalid();
      }
      return;
    }
    invalid();
  }

  static void validate(String type, Map<String, Object?> value) {
    Never invalid(String field) =>
        throw FormatException('Invalid sync schema: $type.$field');
    void strings(List<String> keys) {
      for (final key in keys) {
        if (value[key] is! String) invalid(key);
      }
    }

    void numbers(List<String> keys) {
      for (final key in keys) {
        final v = value[key];
        if (v is! num || !v.isFinite) invalid(key);
      }
    }

    void booleans(List<String> keys) {
      for (final key in keys) {
        if (value[key] is! bool) invalid(key);
      }
    }

    void choice(String key, Iterable<String> values) {
      if (!values.contains(value[key])) invalid(key);
    }

    void currency(String key) {
      if (value[key] is! String ||
          !CurrencyCatalog.isSupported(value[key] as String) ||
          value[key] != (value[key] as String).toUpperCase()) {
        invalid(key);
      }
    }

    void date(String key, {bool dayOnly = false}) {
      final raw = value[key];
      if (raw is! String) invalid(key);
      final parts = RegExp(
        r'^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)?$',
      ).firstMatch(raw);
      if (parts == null ||
          (!dayOnly && parts.group(4) == null) ||
          (dayOnly && parts.group(4) != null)) {
        invalid(key);
      }
      final y = int.parse(parts.group(1)!),
          m = int.parse(parts.group(2)!),
          d = int.parse(parts.group(3)!);
      final normalized = DateTime(y, m, d);
      if (normalized.year != y ||
          normalized.month != m ||
          normalized.day != d ||
          DateTime.tryParse(raw) == null) {
        invalid(key);
      }
      if (parts.group(4) != null &&
          (int.parse(parts.group(4)!) > 23 ||
              int.parse(parts.group(5)!) > 59 ||
              int.parse(parts.group(6)!) > 59)) {
        invalid(key);
      }
    }

    if (!['profile', 'homeTrendConfig', 'widgetBackground'].contains(type)) {
      strings(['id']);
    }
    switch (type) {
      case 'ledgerBooks':
        strings(['name', 'baseCurrencyCode']);
        booleans(['isDefault']);
        date('createdAt');
        currency('baseCurrencyCode');
        choice(
          'currencySetupStatus',
          CurrencySetupStatus.values.map((e) => e.name),
        );
      case 'accounts':
        strings([
          'bookId',
          'name',
          'iconCode',
          'note',
          'currencyCode',
          'cardLast4',
          'cardNumber',
        ]);
        numbers(['initialBalance']);
        booleans(['includeInAssets', 'hidden', 'cardLast4Follows']);
        currency('currencyCode');
        choice('type', AccountType.values.map((e) => e.name));
        for (final key in ['statementDay', 'dueDay']) {
          final day = value[key];
          if (day != null && (day is! int || day < 1 || day > 31)) invalid(key);
        }
      case 'accountGroups':
        strings(['bookId', 'name']);
        numbers(['sortOrder']);
        if (value['sortOrder'] is! int) invalid('sortOrder');
      case 'categories':
        strings(['label', 'iconCode']);
        choice('type', EntryType.values.map((e) => e.storageValue));
      case 'tags':
        strings(['label']);
      case 'attachments':
        strings(['entryId', 'dataUrl']);
      case 'entries':
        strings(['bookId', 'categoryId', 'accountId', 'note', 'currencyCode']);
        numbers(['amount', 'baseAmount']);
        currency('currencyCode');
        choice('type', EntryType.values.map((e) => e.storageValue));
        choice('conversionSource', ConversionSource.values.map((e) => e.name));
        date('occurredAt');
        if (value['settledAt'] != null) date('settledAt');
        if (value.containsKey('tagIds') &&
            (value['tagIds'] is! List ||
                !(value['tagIds'] as List).every((v) => v is String))) {
          invalid('tagIds');
        }
      case 'recurringRules':
        strings(['bookId', 'categoryId', 'accountId', 'note', 'currencyCode']);
        numbers(['amount', 'baseAmount']);
        booleans(['active']);
        currency('currencyCode');
        choice('type', EntryType.values.map((e) => e.storageValue));
        choice('ratePolicy', RecurringRatePolicy.values.map((e) => e.name));
        choice(
          'frequency',
          RecurringFrequency.values.map((e) => e.storageValue),
        );
        date('startDate');
        date('nextRunDate');
      case 'exchangeRates':
        strings(['bookId', 'currencyCode', 'baseCurrencyCode']);
        numbers(['rateToBase']);
        currency('currencyCode');
        currency('baseCurrencyCode');
        choice('source', ExchangeRateSource.values.map((e) => e.name));
        date('effectiveDate', dayOnly: true);
        date('createdAt');
        date('updatedAt');
      case 'profile':
        strings(['nickname', 'bio', 'avatarDataUrl']);
        for (final key in ['birthday', 'city', 'occupation']) {
          if (value.containsKey(key)) strings([key]);
        }
        if (value.containsKey('gender')) {
          choice('gender', ProfileGender.values.map((v) => v.name));
        }
        if (value['birthday'] is String &&
            (value['birthday'] as String).isNotEmpty) {
          date('birthday', dayOnly: true);
        }
      case 'homeTrendConfig':
        strings(['title']);
        for (final key in ['big', 'pill', 'card1', 'card2', 'card3']) {
          choice(key, HomeMetric.values.map((v) => v.name));
        }
        choice('series', HomeTrendSeries.values.map((v) => v.name));
      case 'homePanels':
      case 'reportPanels':
        booleans(['enabled']);
        choice(
          'id',
          (type == 'homePanels' ? homePanelSpecs : reportPanelSpecs).map(
            (v) => v.id,
          ),
        );
      case 'userWidgetDefinitions':
        strings(['name']);
        choice('template', WidgetTemplate.values.map((v) => v.name));
        choice('size', supportedWidgetSizes.map((v) => v.name));
        choice('dateRange', WidgetDateRange.values.map((v) => v.name));
        choice('action', WidgetAction.values.map((v) => v.name));
        booleans(['hideAmounts']);
        for (final key in ['bookId', 'accountId', 'categoryId', 'tagId']) {
          if (value[key] != null) strings([key]);
        }
        if (value['primaryMetric'] != null) {
          choice('primaryMetric', WidgetMetric.values.map((v) => v.name));
        }
        if (value['chartMetric'] != null) {
          choice('chartMetric', WidgetChartMetric.values.map((v) => v.name));
        }
        final secondary = value['secondaryMetrics'];
        if (secondary is! List ||
            !secondary.every(
              (item) => WidgetMetric.values.any((v) => v.name == item),
            )) {
          invalid('secondaryMetrics');
        }
        final background = value['background'];
        if (background is! Map) invalid('background');
        validate('widgetBackground', Map<String, Object?>.from(background));
      case 'widgetBackground':
        choice('kind', WidgetBackgroundKind.values.map((v) => v.name));
        if (value['value'] != null) strings(['value']);
        numbers(['overlayOpacity']);
        final opacity = value['overlayOpacity'] as num;
        if (opacity < 0 || opacity > 1) invalid('overlayOpacity');
    }
    for (final key in ['parentId', 'groupId', 'toAccountId', 'refundOf']) {
      if (value[key] != null && value[key] is! String) invalid(key);
    }
    for (final key in [
      'accountAmount',
      'toAccountAmount',
      'fee',
      'creditLimit',
      'refundedBaseAmount',
    ]) {
      if (value[key] != null) numbers([key]);
    }
    for (final key in ['reimbursable']) {
      if (value.containsKey(key)) booleans([key]);
    }
  }

  static void validatePreferences(Map<String, Object?> data) {
    Never invalid(String key) =>
        throw FormatException('Invalid sync schema: $key');
    for (final key in ['activeBookId', 'assetCoverUrl']) {
      if (data.containsKey(key) && data[key] is! String) invalid(key);
    }
    for (final key in ['profile', 'homeTrendConfig']) {
      if (!data.containsKey(key)) continue;
      final value = data[key];
      if (value is! Map) invalid(key);
      validate(key, Map<String, Object?>.from(value));
    }
    for (final key in ['homePanels', 'reportPanels', 'userWidgetDefinitions']) {
      if (!data.containsKey(key)) continue;
      final value = data[key];
      if (value is! List) invalid(key);
      final ids = <String>{};
      for (final item in value) {
        if (item is! Map ||
            item['id'] is! String ||
            !ids.add(item['id'] as String)) {
          invalid(key);
        }
        validate(key, Map<String, Object?>.from(item));
      }
    }
    final collapsed = data['collapsedAssetSections'];
    if (data.containsKey('collapsedAssetSections') &&
        (collapsed is! List || !collapsed.every((v) => v is String))) {
      invalid('collapsedAssetSections');
    }
    for (final key in ['assetAccountOrders', 'assetSectionOrders']) {
      if (!data.containsKey(key)) continue;
      final value = data[key];
      if (value is! Map) invalid(key);
      for (final item in value.entries) {
        if (item.key is! String ||
            item.value is! List ||
            !(item.value as List).every((v) => v is String)) {
          invalid(key);
        }
      }
    }
  }
}
