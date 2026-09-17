import '../../data/ledger_repository.dart';
import '../ledger_data_validation.dart';
import '../models.dart';
import 'sync_schema.dart';

/// Strict remote materialization. Unlike backup import this never seeds or
/// repairs missing references, because an invalid batch must be rejected whole.
abstract final class SyncLedgerReducer {
  static LedgerDataSnapshot parse(Map<String, Object?> data) {
    SyncSchema.validatePreferences(data);
    List<T> list<T>(String key, T Function(Map<String, Object?>) parse) {
      final value = data[key];
      if (value is! List) throw FormatException('Invalid sync list: $key');
      final ids = <String>{};
      return value.map((item) {
        if (item is! Map ||
            item['id'] is! String ||
            (item['id'] as String).isEmpty ||
            !ids.add(item['id'] as String)) {
          throw FormatException('Invalid sync identity: $key');
        }
        final json = Map<String, Object?>.from(item);
        SyncSchema.validate(key, json);
        return parse(json);
      }).toList();
    }

    Map<String, double> budget(String key) {
      final value = data[key];
      if (value is! Map) throw FormatException('Invalid sync budget: $key');
      return value.map((k, v) {
        if (k is! String || k.isEmpty || v is! num || !v.isFinite || v < 0) {
          throw FormatException('Invalid sync budget: $key');
        }
        return MapEntry(k, v.toDouble());
      });
    }

    final books = list('ledgerBooks', LedgerBook.fromJson);
    final accounts = list('accounts', Account.fromJson);
    final groups = list('accountGroups', AccountGroup.fromJson);
    final categories = list('categories', Category.fromJson);
    final tags = list('tags', Tag.fromJson);
    final attachments = list('attachments', Attachment.fromJson);
    var entries = list('entries', LedgerEntry.fromJson);
    final rules = list('recurringRules', RecurringRule.fromJson);
    final rates = list('exchangeRates', ExchangeRate.fromJson);
    final refunds = <String, double>{};
    for (final entry in entries) {
      if (entry.type == EntryType.refund &&
          entry.settledAt != null &&
          entry.refundOf != null) {
        refunds.update(
          entry.refundOf!,
          (v) => v + entry.baseAmount,
          ifAbsent: () => entry.baseAmount,
        );
      }
    }
    entries = entries
        .map(
          (e) => e.copyWith(
            refundedBaseAmount: (refunds[e.id] ?? 0)
                .clamp(0.0, e.baseAmount)
                .toDouble(),
          ),
        )
        .toList();
    final issue = validateLedgerEntries(
      books: books,
      accounts: accounts,
      entries: entries,
    );
    if (issue != null) {
      throw FormatException('Invalid sync ledger: ${issue.code.name}');
    }
    final bookIds = books.map((b) => b.id).toSet();
    final categoryIds = categories.map((c) => c.id).toSet();
    final tagIds = tags.map((t) => t.id).toSet();
    final entryIds = entries.map((e) => e.id).toSet();
    final accountsById = {for (final a in accounts) a.id: a};
    final groupsById = {for (final g in groups) g.id: g};
    void require(bool condition) {
      if (!condition) throw const FormatException('Invalid sync reference');
    }

    if (data.containsKey('activeBookId')) {
      require(bookIds.contains(data['activeBookId']));
    }
    for (final field in [
      'hapticsEnabled',
      'amountForceTwoDecimals',
      'hideUnitInSingleCurrency',
      'autoSuggestEnabled',
      'showRunningBalance',
    ]) {
      if (data.containsKey(field)) require(data[field] is bool);
    }
    final enums = <String, Set<String>>{
      'themePreference': ThemePreference.values.map((v) => v.name).toSet(),
      'assetAccountViewMode': AssetAccountViewMode.values
          .map((v) => v.name)
          .toSet(),
      'fabActionMode': FabActionMode.values.map((v) => v.name).toSet(),
      'currencyFractionStyle': CurrencyFractionStyle.values
          .map((v) => v.name)
          .toSet(),
      'moneyUnitStyle': MoneyUnitStyle.values.map((v) => v.name).toSet(),
    };
    for (final field in enums.entries) {
      if (data.containsKey(field.key)) {
        require(field.value.contains(data[field.key]));
      }
    }
    for (final field in [
      'budgetCycleStartDays',
      'budgetPeriodKinds',
      'defaultAccountIds',
    ]) {
      final value = data[field];
      require(value is Map);
      for (final item in (value as Map).entries) {
        require(bookIds.contains(item.key));
        switch (field) {
          case 'budgetCycleStartDays':
            require(
              item.value is int &&
                  (item.value as int) >= 1 &&
                  (item.value as int) <= 28,
            );
          case 'budgetPeriodKinds':
            require(BudgetPeriodKind.values.any((v) => v.name == item.value));
          case 'defaultAccountIds':
            require(
              item.value == '' || accountsById[item.value]?.bookId == item.key,
            );
        }
      }
    }

    for (final g in groups) {
      require(bookIds.contains(g.bookId));
    }
    for (final a in accounts) {
      require(
        a.initialBalance.isFinite &&
            (a.groupId == null || groupsById[a.groupId]?.bookId == a.bookId),
      );
    }
    final categoriesById = {for (final c in categories) c.id: c};
    for (final c in categories) {
      final seen = <String>{c.id};
      var parent = c.parentId;
      while (parent != null) {
        require(categoryIds.contains(parent) && seen.add(parent));
        parent = categoriesById[parent]!.parentId;
      }
    }
    for (final e in entries) {
      require(categoryIds.contains(e.categoryId));
      require(e.tagIds.every(tagIds.contains));
      require(
        e.accountId.isEmpty || accountsById[e.accountId]?.bookId == e.bookId,
      );
      require(
        e.toAccountId == null ||
            accountsById[e.toAccountId]?.bookId == e.bookId,
      );
    }
    for (final a in attachments) {
      require(entryIds.contains(a.entryId));
    }
    for (final r in rules) {
      require(
        bookIds.contains(r.bookId) &&
            categoryIds.contains(r.categoryId) &&
            r.amount.isFinite &&
            r.amount > 0,
      );
      require(
        r.accountId.isEmpty || accountsById[r.accountId]?.bookId == r.bookId,
      );
      require(
        r.toAccountId == null ||
            accountsById[r.toAccountId]?.bookId == r.bookId,
      );
    }
    for (final r in rates) {
      require(
        books.any(
              (b) =>
                  b.id == r.bookId && b.baseCurrencyCode == r.baseCurrencyCode,
            ) &&
            r.currencyCode != r.baseCurrencyCode &&
            r.rateToBase.isFinite &&
            r.rateToBase > 0,
      );
    }
    final monthly = budget('monthlyBudgets');
    final categoryBudgets = budget('categoryBudgets');
    final daily = budget('dailyBudgets');
    for (final key in monthly.keys) {
      require(bookIds.any((id) => key.startsWith('$id:')));
    }
    for (final key in categoryBudgets.keys) {
      require(
        bookIds.any((id) => key.startsWith('$id:')) &&
            categoryIds.any((id) => key.endsWith(':$id')),
      );
    }
    for (final key in daily.keys) {
      require(bookIds.contains(key));
    }
    return LedgerDataSnapshot(
      books: books,
      accounts: accounts,
      accountGroups: groups,
      categories: categories,
      tags: tags,
      attachments: attachments,
      entries: entries,
      recurringRules: rules,
      exchangeRates: rates,
      monthlyBudgets: monthly,
      categoryBudgets: categoryBudgets,
      dailyBudgets: daily,
    );
  }
}
