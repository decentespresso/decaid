import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/skin_selector/skin_selector_page.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:reaprime/src/widgets/page_action_menu.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import 'helpers/mock_settings_service.dart';

class _FakeWebUIService extends Fake implements WebUIService {
  @override
  bool get isServing => false;
}

class _FakeWebUIStorage extends Fake implements WebUIStorage {
  _FakeWebUIStorage(this._version, {this.updateCompletion});

  String _version;
  final Future<void>? updateCompletion;
  int updateCount = 0;

  WebUISkin get _skin => WebUISkin(
    id: 'streamline.js',
    name: 'Streamline',
    path: '/tmp/streamline.js',
    version: _version,
    isBundled: false,
  );

  @override
  List<WebUISkin> get installedSkins => [_skin];

  @override
  WebUISkin? get defaultSkin => _skin;

  @override
  WebUISkin? getSkin(String id) => id == _skin.id ? _skin : null;

  @override
  Future<void> updateAllSkins() async {
    updateCount++;
    if (updateCompletion != null) await updateCompletion;
    _version = '0.2.3';
  }
}

void main() {
  Future<void> pumpView(WidgetTester tester, _FakeWebUIStorage storage) async {
    await tester.pumpWidget(
      ShadApp(
        home: ScaffoldMessenger(
          child: SkinSelectorPage(
            settingsController: SettingsController(MockSettingsService()),
            webUIService: _FakeWebUIService(),
            webUIStorage: storage,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('skin updates show progress and reject duplicate checks', (
    tester,
  ) async {
    final completion = Completer<void>();
    final storage = _FakeWebUIStorage(
      '0.2.2',
      updateCompletion: completion.future,
    );
    await pumpView(tester, storage);
    expect(find.byType(PageActionMenu), findsOneWidget);
    await tester.tap(find.byTooltip('Skin actions'));
    await tester.pumpAndSettle();
    final startCheck = tester
        .widget<MenuItemButton>(
          find.widgetWithText(MenuItemButton, 'Check for updates'),
        )
        .onPressed!;
    await tester.tap(find.text('Check for updates'));
    startCheck();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(storage.updateCount, 1);
    expect(find.text('Check for updates'), findsNothing);
    final progress = find.descendant(
      of: find.byType(AppBar),
      matching: find.byType(CircularProgressIndicator),
    );
    expect(progress, findsOneWidget);
    final indicator = tester.widget<CircularProgressIndicator>(progress);
    expect(indicator.semanticsLabel, 'Checking for skin updates');
    expect(
      indicator.color,
      ShadTheme.of(tester.element(progress)).colorScheme.primary,
    );
    expect(tester.getSize(progress), const Size(28, 28));

    await tester.tap(find.byTooltip('Skin actions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      tester
          .widget<MenuItemButton>(
            find.widgetWithText(MenuItemButton, 'Check for updates'),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Check for updates'));
    expect(storage.updateCount, 1);

    completion.complete();
    await tester.pumpAndSettle();
    expect(progress, findsNothing);
    expect(find.byIcon(LucideIcons.settings), findsOneWidget);
    expect(find.textContaining('0.2.3'), findsOneWidget);
    expect(
      tester
          .widget<MenuItemButton>(
            find.widgetWithText(MenuItemButton, 'Check for updates'),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('failed skin checks clear progress and allow retry', (
    tester,
  ) async {
    final completion = Completer<void>();
    final storage = _FakeWebUIStorage(
      '0.2.2',
      updateCompletion: completion.future,
    );
    await pumpView(tester, storage);
    await tester.tap(find.byTooltip('Skin actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check for updates'));
    await tester.pump();
    completion.completeError(StateError('offline'));
    await tester.pumpAndSettle();

    expect(find.byIcon(LucideIcons.settings), findsOneWidget);
    expect(
      find.textContaining('Failed to check for skin updates'),
      findsOneWidget,
    );
    expect(find.textContaining('0.2.2'), findsOneWidget);
    await tester.tap(find.byTooltip('Skin actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();
    expect(storage.updateCount, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('skin check completion after leaving the page is safe', (
    tester,
  ) async {
    final completion = Completer<void>();
    final storage = _FakeWebUIStorage(
      '0.2.2',
      updateCompletion: completion.future,
    );
    await pumpView(tester, storage);
    await tester.tap(find.byTooltip('Skin actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check for updates'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    completion.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'skins list refreshes to the new version after "Check for updates" '
    '(issues #370, #503)',
    (tester) async {
      final storage = _FakeWebUIStorage('0.2.2');

      await pumpView(tester, storage);

      expect(find.textContaining('0.2.2'), findsOneWidget);
      expect(find.textContaining('0.2.3'), findsNothing);

      await tester.tap(find.byTooltip('Skin actions'));
      await tester.pumpAndSettle();
      final updateButton = find.text('Check for updates');
      await tester.ensureVisible(updateButton);
      await tester.tap(updateButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(storage.updateCount, 1);
      expect(find.textContaining('0.2.3'), findsOneWidget);
      expect(find.textContaining('0.2.2'), findsNothing);
    },
  );
}
