import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/notifications/native_notification.dart';
import 'package:reaprime/src/notifications/notification_actions.dart';
import 'package:reaprime/src/notifications/notification_center.dart';
import 'package:reaprime/src/notifications/notification_overlay.dart';
import 'package:reaprime/src/notifications/update_notifications.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/update_check_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_settings_service.dart';

class _Updater extends AndroidUpdater {
  _Updater() : super(owner: 'unused', repo: 'unused');

  int checks = 0;
  bool fail = false;
  UpdateInfo? next;
  Completer<UpdateInfo?>? pending;

  @override
  Future<UpdateInfo?> checkForUpdate(
    String currentVersion, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async {
    checks++;
    if (fail) throw StateError('Offline');
    return pending?.future ?? next;
  }
}

void main() {
  late NotificationCenter center;
  late NotificationActions actions;
  late MockSettingsService settings;
  late _Updater updater;
  late UpdateCheckService service;
  UpdateNotifications? updates;
  var downloads = 0;

  UpdateInfo update(String version) => UpdateInfo(
    version: version,
    downloadUrl: 'https://example.com/app.apk',
    releaseNotes: 'Changes',
    isPrerelease: false,
    tagName: 'v$version',
  );

  setUp(() {
    center = NotificationCenter();
    settings = MockSettingsService();
    updater = _Updater()..next = update('99.0.0');
    service = UpdateCheckService(
      settingsService: settings,
      webUIStorage: WebUIStorage(SettingsController(settings)),
      updater: updater,
      platformIsAndroid: false,
      platformIsMacOS: false,
      externallyManaged: false,
    );
    actions = NotificationActions(
      center: center,
      onOpenAccount: () {},
      updateCheckService: service,
      launch: (_) async => throw StateError('Checking must not open a browser'),
    );
    updates = null;
    downloads = 0;
  });

  tearDown(() async {
    await updates?.dispose();
    actions.dispose();
    service.dispose();
    center.dispose();
  });

  Future<void> mount(
    WidgetTester tester, {
    NotificationNamespace namespace = NotificationNamespace.host,
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    await tester.runAsync(() async {
      final release = Uri.parse(
        'https://github.com/decentespresso/decaid/releases/tag/v99.0.0',
      );
      await center.publish(
        NativeNotification(
          namespace: namespace,
          sourceId: UpdateNotifications.sourceId,
          sourceName: 'Decaid',
          id: '99.0.0',
          message: 'Update available: 99.0.0',
          actions: [
            NotificationAction(
              id: 'view',
              label: 'View',
              type: NotificationActionType.openExternalUrl,
              url: release,
            ),
            if (namespace == NotificationNamespace.host)
              NotificationAction(
                id: 'download',
                label: 'Download',
                type: NotificationActionType.openExternalUrl,
                url: release,
              ),
          ],
        ),
      );
      await center.markRead(center.value);
      updates = UpdateNotifications(
        center: center,
        service: service,
        onDownload: (_) async => downloads++,
      );
      await updates!.settled;
    });
    await tester.pumpWidget(
      ShadApp(
        themeMode: brightness == Brightness.dark
            ? ThemeMode.dark
            : ThemeMode.light,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(
          body: Center(
            child: ShadButton(
              onPressed: () => showNotifications(
                tester.element(find.byType(Scaffold)),
                center,
                actions,
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.runAsync(() async {
      await tester.tap(find.text('Open'));
      await center.settled;
    });
    await tester.pumpAndSettle();
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(Duration.zero);
      await updates!.settled;
      await center.settled;
    });
    await tester.pumpAndSettle();
  }

  Future<void> clickCheck(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Check for updates'));
    await tester.pumpAndSettle();
    expect(find.text('Check for updates').hitTestable(), findsOneWidget);
    await tester.runAsync(() async {
      await tester.tap(find.text('Check for updates'));
      await Future<void>.delayed(Duration.zero);
    });
    await tester.pump();
  }

  testWidgets(
    'manual checking replaces restored actions and enables them once',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.runAsync(() async {
          updater.pending = Completer<UpdateInfo?>();
        });
        await mount(tester);
        expect(updater.checks, 0);
        expect(find.text('Check for updates'), findsOneWidget);
        expect(find.text('View'), findsNothing);
        expect(find.text('Download'), findsNothing);
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await clickCheck(tester);
        expect(find.text('Checking...'), findsOneWidget);
        expect(
          tester
              .widget<ShadButton>(
                find.widgetWithText(ShadButton, 'Checking...'),
              )
              .enabled,
          isFalse,
        );
        await tester.runAsync(() => service.requestCheck());
        expect(updater.checks, 1);
        updater.pending!.complete(updater.next);
        await tester.pump();
        await settle(tester);
        expect(find.text('Check for updates'), findsNothing);
        expect(find.text('View'), findsOneWidget);
        expect(find.text('Download'), findsOneWidget);
        expect(center.isConfirmed(center.value.single), isTrue);
        expect(center.unreadCount, 0);
        expect(downloads, 0);
        await tester.pumpWidget(const SizedBox());
      } finally {
        handle.dispose();
      }
    },
  );

  testWidgets('a failed check retains the notice and offers a working retry', (
    tester,
  ) async {
    updater.fail = true;
    await mount(tester);
    await clickCheck(tester);
    await settle(tester);
    expect(
      find.text('Could not check for updates. Please try again.'),
      findsOneWidget,
    );
    expect(find.text('Check for updates'), findsOneWidget);
    expect(find.text('View'), findsNothing);
    expect(center.isConfirmed(center.value.single), isFalse);
    expect(center.unreadCount, 0);
    updater.fail = false;
    await clickCheck(tester);
    await settle(tester);
    expect(updater.checks, 2);
    expect(find.text('View'), findsOneWidget);
    expect(
      find.text('Could not check for updates. Please try again.'),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox());
  });

  for (final version in <String?>[null, '100.0.0']) {
    testWidgets('manual check reconciles the saved update with $version', (
      tester,
    ) async {
      updater.next = version == null ? null : update(version);
      await mount(tester);
      await clickCheck(tester);
      await settle(tester);
      if (version == null) {
        expect(find.text('No notifications'), findsOneWidget);
        expect(center.value, isEmpty);
      } else {
        expect(center.value.single.id, version);
        expect(center.unreadCount, 1);
        expect(find.text('View'), findsOneWidget);
      }
      expect(await settings.skippedVersion(), isNull);
      expect(downloads, 0);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('closing the list does not cancel an in-flight manual check', (
    tester,
  ) async {
    await tester.runAsync(() async {
      updater.pending = Completer<UpdateInfo?>();
    });
    await mount(tester);
    await clickCheck(tester);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      updater.pending!.complete(updater.next);
    });
    await settle(tester);
    expect(find.byType(NotificationOverlay), findsNothing);
    expect(center.isConfirmed(center.value.single), isTrue);
    expect(center.unreadCount, 0);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('plugin notices cannot acquire the host update-check control', (
    tester,
  ) async {
    await mount(tester, namespace: NotificationNamespace.plugin);
    expect(find.text('Check for updates'), findsNothing);
    expect(find.text('View'), findsOneWidget);
    expect(updater.checks, 0);
    await tester.pumpWidget(const SizedBox());
  });

  for (final brightness in Brightness.values) {
    testWidgets('manual check fits narrow, large-text layouts in $brightness', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester, textScale: 2, brightness: brightness);
      expect(find.text('Check for updates'), findsOneWidget);
      expect(tester.takeException(), isNull);
      updater.fail = true;
      await clickCheck(tester);
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Check for updates'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
