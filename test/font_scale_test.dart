import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:verifin/app/models.dart';
import 'package:verifin/local_storage/local_storage.dart';
import 'package:verifin/main.dart';

import 'support/test_harness.dart';

void main() {
  useTestDatabases();

  test('字体大小偏好默认标准且可持久化', () async {
    final store = LocalKeyValueStore();
    final controller = await makeController(store);
    expect(controller.fontScale, AppFontScale.standard);

    controller.setFontScale(AppFontScale.large);
    expect(controller.fontScale, AppFontScale.large);

    final restarted = await makeController(store);
    expect(restarted.fontScale, AppFontScale.large);
  });

  testWidgets('应用根组件使用字体大小偏好调整文本缩放', (tester) async {
    final controller = await makeController();
    controller.setFontScale(AppFontScale.large);
    await tester.pumpWidget(VeriFinApp(controller: controller));
    await tester.pumpAndSettle();

    final mediaQuery = tester.widget<MediaQuery>(
      find.byKey(const Key('app_font_scale_media_query')),
    );
    expect(mediaQuery.data.textScaler.scale(14), closeTo(15.4, 0.01));
  });

  testWidgets('应用字体大小与系统无障碍文字缩放相乘', (tester) async {
    final controller = await makeController();
    controller.setFontScale(AppFontScale.large);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
        child: VeriFinApp(controller: controller),
      ),
    );
    await tester.pumpAndSettle();

    final mediaQuery = tester.widget<MediaQuery>(
      find.byKey(const Key('app_font_scale_media_query')),
    );
    expect(mediaQuery.data.textScaler.scale(14), closeTo(23.1, 0.01));
  });

  test('字体大小是设备偏好，不随备份覆盖', () async {
    final source = await makeController();
    source.setFontScale(AppFontScale.extraLarge);
    final backup = source.exportDataJson();

    final target = await makeController();
    target.setFontScale(AppFontScale.small);
    target.importDataJson(backup);
    expect(target.fontScale, AppFontScale.small);
    source.dispose();
    target.dispose();
  });

  testWidgets('设置页字体大小保存前只更新草稿', (tester) async {
    final controller = await pumpApp(tester);
    await tapBottomTab(tester, 3);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();

    await tester.tap(find.text('字体大小'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('大'));
    await tester.pumpAndSettle();
    expect(controller.fontScale, AppFontScale.standard);

    await tester.fling(firstVerticalScrollable(), const Offset(0, 1600), 1000);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('保存'));
    await tester.pumpAndSettle();
    expect(controller.fontScale, AppFontScale.large);
  });

  test('设置保存中途失败会回滚字体键，重启后仍使用旧字号', () async {
    final store = _FailFourthPreferenceWriteStore();
    final controller = await makeController(store);

    final saved = await controller.saveAppPreferencesDraft(
      themePreference: controller.themePreference,
      localePreference: controller.localePreference,
      fontScale: AppFontScale.large,
      hapticsEnabled: controller.hapticsEnabled,
      amountForceTwoDecimals: controller.amountForceTwoDecimals,
      moneyUnitStyle: controller.moneyUnitStyle,
      hideUnitInSingleCurrency: controller.hideUnitInSingleCurrency,
      fabActionMode: controller.fabActionMode,
      defaultAccountId: controller.defaultAccountId,
      autoSuggestEnabled: controller.autoSuggestEnabled,
      showRunningBalance: controller.showRunningBalance,
    );

    expect(saved, isFalse);
    expect(controller.fontScale, AppFontScale.standard);
    final restarted = await makeController(store);
    expect(restarted.fontScale, AppFontScale.standard);
    controller.dispose();
    restarted.dispose();
  });
}

class _FailFourthPreferenceWriteStore extends LocalKeyValueStore {
  var _writeCount = 0;
  var _failed = false;

  @override
  Future<void> writeAndFlush(String key, String value) async {
    _writeCount += 1;
    if (!_failed && _writeCount == 4) {
      _failed = true;
      throw StateError('simulated preference write failure');
    }
    await super.writeAndFlush(key, value);
  }

  @override
  Future<void> deleteAndFlush(String key) async {
    await super.deleteAndFlush(key);
  }
}
