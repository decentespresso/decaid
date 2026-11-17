import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/settings/advanced_page.dart';
import 'package:reaprime/src/settings/feature_flags.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../../helpers/mock_settings_service.dart';

class _DelayedSettingsService extends MockSettingsService {
  final firstSave = Completer<void>();
  final started = Completer<void>();
  final bool failFirst;
  List<bool> attempts = [];

  _DelayedSettingsService({this.failFirst = false});

  @override
  Future<void> setFeatureFlag(FeatureFlag flag, bool value) async {
    final isFirst = attempts.isEmpty;
    attempts = [...attempts, value];
    if (isFirst) {
      started.complete();
      await firstSave.future;
      if (failFirst) throw StateError('Settings unavailable');
    }
    await super.setFeatureFlag(flag, value);
  }
}

void main() {
  for (final flag in FeatureFlag.values) {
    test('pending $flag save preserves a later reversal', () async {
      final service = _DelayedSettingsService();
      final settings = SettingsController(service);
      addTearDown(settings.dispose);
      await settings.loadSettings();
      final initial = settings.isFeatureFlagEnabled(flag);

      final first = settings.setFeatureFlag(flag, !initial);
      await service.started.future;
      final last = settings.setFeatureFlag(flag, initial);
      expect(settings.isFeatureFlagEnabled(flag), initial);
      service.firstSave.complete();
      await Future.wait([first, last]);

      expect(service.attempts, [!initial, initial]);
      expect(settings.isFeatureFlagEnabled(flag), initial);
      expect(await service.featureFlag(flag), initial);
    });
  }

  test('duplicate pending selections only save once', () async {
    final service = _DelayedSettingsService();
    final settings = SettingsController(service);
    addTearDown(settings.dispose);
    await settings.loadSettings();
    const flag = FeatureFlag.androidTextureLayerComposition;

    final first = settings.setFeatureFlag(flag, true);
    await service.started.future;
    final duplicate = settings.setFeatureFlag(flag, true);
    service.firstSave.complete();
    await Future.wait([first, duplicate]);

    expect(service.attempts, [true]);
    expect(settings.isFeatureFlagEnabled(flag), isTrue);
  });

  test('a failed pending save does not prevent a queued retry', () async {
    final service = _DelayedSettingsService(failFirst: true);
    final settings = SettingsController(service);
    addTearDown(settings.dispose);
    await settings.loadSettings();
    const flag = FeatureFlag.androidTextureLayerComposition;
    var notifications = 0;
    settings.addListener(() => notifications++);

    final failure = expectLater(
      settings.setFeatureFlag(flag, true),
      throwsStateError,
    );
    await service.started.future;
    final retry = settings.setFeatureFlag(flag, true);
    expect(settings.isFeatureFlagEnabled(flag), isFalse);
    service.firstSave.complete();
    await Future.wait([failure, retry]);

    expect(service.attempts, [true, true]);
    expect(settings.isFeatureFlagEnabled(flag), isTrue);
    expect(await service.featureFlag(flag), isTrue);
    expect(notifications, 1);
  });

  testWidgets('the selector retains the last choice while a save is pending', (
    tester,
  ) async {
    final service = _DelayedSettingsService();
    final settings = SettingsController(service);
    addTearDown(settings.dispose);
    await settings.loadSettings();
    await tester.pumpWidget(ShadApp(home: AdvancedPage(controller: settings)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('HC (default)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TLHC (HC fallback)').last);
    await tester.pumpAndSettle();
    expect(service.attempts, [true]);
    await tester.tap(find.text('HC (default)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('HC (default)').last);
    await tester.pumpAndSettle();
    service.firstSave.complete();
    await tester.pumpAndSettle();

    final dropdown = find.byWidgetPredicate(
      (widget) => widget is DropdownButton<bool>,
    );
    expect(tester.widget<DropdownButton<bool>>(dropdown).value, isFalse);
    expect(
      await service.featureFlag(FeatureFlag.androidTextureLayerComposition),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));
}
