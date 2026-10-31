import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/display_controller.dart';
import 'package:reaprime/src/notifications/native_notification.dart';
import 'package:reaprime/src/notifications/notification_actions.dart';
import 'package:reaprime/src/notifications/notification_center.dart';
import 'package:reaprime/src/notifications/notification_overlay.dart';
import 'package:reaprime/src/services/webview_log_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/update_dialog.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_de1_controller.dart';
import '../helpers/mock_settings_service.dart';

class _WebView extends StatefulWidget {
  const _WebView({super.key});

  @override
  State<_WebView> createState() => _WebViewState();
}

class _WebViewState extends State<_WebView> {
  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: Colors.green, child: SizedBox.expand());
}

void main() {
  late NotificationCenter center;
  late NotificationActions actions;
  var failSaves = false;
  final dismissals = <String>[];
  final phases = <String>[];

  setUp(() async {
    failSaves = false;
    center = NotificationCenter(save: (_) async => !failSaves);
    dismissals.clear();
    phases.clear();
    actions = NotificationActions(
      center: center,
      onOpenAccount: () {},
      launch: (_) async => true,
    );
    await center.settled;
  });
  tearDown(() {
    actions.dispose();
    center.dispose();
  });

  Future<void> publish({
    String id = 'condition',
    String? message,
    bool confirmed = true,
  }) async {
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      await center.publish(
        NativeNotification(
          namespace: NotificationNamespace.plugin,
          sourceId: 'plugin',
          sourceName: 'Plugin',
          id: id,
          message: message ?? 'Needs attention',
          actions: [
            NotificationAction(
              id: 'support',
              label: 'Support',
              type: NotificationActionType.openExternalUrl,
              url: Uri.parse('https://example.com/help'),
            ),
          ],
        ),
        binding: confirmed
            ? NotificationBinding(
                onAction: (_, phase) => phases.add(phase),
                onDismissed: (notice) async => dismissals.add(notice.id),
              )
            : null,
      );
      await center.settled;
    });
  }

  Future<void> mount(
    WidgetTester tester, {
    double textScale = 1,
    Brightness brightness = Brightness.light,
    Locale? locale,
  }) async {
    await tester.pumpWidget(
      ShadApp(
        locale: locale,
        supportedLocales: const [Locale('en'), Locale('de')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
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
          floatingActionButton: NotificationBell(
            center: center,
            actions: actions,
          ),
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: textScale > 1 ? 280 : 130,
              height: 130 * textScale,
              child: NotificationDestination(center: center, actions: actions),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tap(find.byType(FloatingActionButton));
      await center.settled;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.runAsync(() async {
      await tester.tap(target);
      await Future<void>.delayed(Duration.zero);
      await center.settled;
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  Finder dismissAllButton() => find.byWidgetPredicate(
    (widget) =>
        widget is IconButton && widget.tooltip == 'Dismiss all notifications',
  );

  Future<void> publishUpdate({bool confirmed = true}) async {
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      await center.publish(
        NativeNotification(
          namespace: NotificationNamespace.host,
          sourceId: 'app-update',
          sourceName: 'Decaid',
          id: '99.0.0',
          message: 'Update available: 99.0.0',
          actions: [
            NotificationAction(
              id: 'view',
              label: 'View',
              type: NotificationActionType.openExternalUrl,
              url: Uri.parse('https://example.com/release'),
            ),
          ],
        ),
        binding: NotificationBinding(
          confirmed: confirmed,
          onDismissed: (notice) async => dismissals.add('skip ${notice.id}'),
        ),
      );
    });
  }

  testWidgets(
    'localized close X does not dismiss notices or read later changes',
    (tester) async {
      await publish();
      await mount(tester, locale: const Locale('de'));
      await open(tester);
      final label = MaterialLocalizations.of(
        tester.element(find.byType(NotificationOverlay)),
      ).closeButtonTooltip;
      expect(label, isNot('Close'));
      expect(find.byTooltip(label), findsOneWidget);
      expect(find.byIcon(LucideIcons.x), findsOneWidget);
      await publish(id: 'arrival');
      await tester.pumpAndSettle();
      await tap(tester, find.byTooltip(label));
      expect(find.byType(NotificationOverlay), findsNothing);
      expect(center.value, hasLength(2));
      expect(center.unreadCount, 1);
      expect(dismissals, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final confirmed in [false, true]) {
    testWidgets(
      'trash controls distinguish version skipping, confirmed=$confirmed',
      (tester) async {
        await publish();
        await publishUpdate(confirmed: confirmed);
        await mount(tester);
        await open(tester);
        expect(find.byTooltip('Close'), findsOneWidget);
        expect(find.byIcon(LucideIcons.x), findsOneWidget);
        expect(find.byIcon(LucideIcons.trash2), findsNWidgets(3));
        expect(find.byTooltip('Dismiss notification'), findsOneWidget);
        expect(find.text('Support'), findsOneWidget);
        expect(find.text('View'), confirmed ? findsOneWidget : findsNothing);
        expect(
          find.text('Check for updates'),
          confirmed ? findsNothing : findsOneWidget,
        );
        await tap(tester, find.byTooltip('Skip version 99.0.0'));
        expect(find.byType(NotificationOverlay), findsOneWidget);
        expect(center.value.single.namespace, NotificationNamespace.plugin);
        expect(dismissals, ['skip 99.0.0']);
        await tap(tester, find.byTooltip('Dismiss notification'));
        expect(center.value, isEmpty);
        expect(dismissals, ['skip 99.0.0', 'condition']);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('unfamiliar plugin notices retain generic trash dismissal', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await center.publish(
        NativeNotification(
          namespace: NotificationNamespace.plugin,
          sourceId: 'app-update',
          sourceName: 'Unfamiliar Plugin',
          id: '99.0.0',
          message: 'An unfamiliar condition without an action',
          actions: const [],
        ),
        binding: NotificationBinding(
          onDismissed: (notice) async => dismissals.add(notice.id),
        ),
      );
    });
    await mount(tester);
    await open(tester);
    expect(find.byIcon(LucideIcons.trash2), findsNWidgets(2));
    expect(find.byTooltip('Skip version 99.0.0'), findsNothing);
    await tap(tester, find.byTooltip('Dismiss notification'));
    expect(center.value, isEmpty);
    expect(dismissals, ['99.0.0']);
    expect(find.byType(NotificationOverlay), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  for (final confirmed in [false, true]) {
    testWidgets(
      'dismiss all preserves per-notice behavior, confirmed=$confirmed',
      (tester) async {
        await publish();
        await publish(id: 'second');
        await publishUpdate(confirmed: confirmed);
        await mount(tester);
        await open(tester);
        await tap(tester, find.byTooltip('Dismiss all notifications'));
        expect(center.value, isEmpty);
        expect(dismissals, ['condition', 'second', 'skip 99.0.0']);
        expect(phases, isEmpty);
        expect(find.byType(NotificationOverlay), findsOneWidget);
        expect(find.text('No notifications'), findsOneWidget);
        expect(tester.widget<IconButton>(dismissAllButton()).onPressed, isNull);
        await publish(id: 'later');
        await tester.pumpAndSettle();
        expect(
          tester.widget<IconButton>(dismissAllButton()).onPressed,
          isNotNull,
        );
        await tap(tester, find.byTooltip('Close'));
        expect(center.value.single.id, 'later');
        expect(center.unreadCount, 1);
        expect(dismissals, ['condition', 'second', 'skip 99.0.0']);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('dismiss all preserves new arrivals and changed revisions', (
    tester,
  ) async {
    await publish();
    await publish(id: 'second');
    await mount(tester);
    await open(tester);
    await tester.runAsync(() async {
      tester.widget<IconButton>(dismissAllButton()).onPressed!();
      final replacement = center.publish(
        NativeNotification(
          namespace: NotificationNamespace.plugin,
          sourceId: 'plugin',
          sourceName: 'Plugin',
          id: 'second',
          message: 'Changed while dismissing',
          actions: const [],
        ),
      );
      final arrival = center.publish(
        NativeNotification(
          namespace: NotificationNamespace.plugin,
          sourceId: 'plugin',
          sourceName: 'Plugin',
          id: 'arrival',
          message: 'Arrived while dismissing',
          actions: const [],
        ),
      );
      await replacement;
      await arrival;
      await Future<void>.delayed(Duration.zero);
      await center.settled;
    });
    await tester.pumpAndSettle();
    expect(center.value.map((notice) => notice.id), ['second', 'arrival']);
    expect(center.value.first.message, 'Changed while dismissing');
    expect(center.unreadCount, 2);
    expect(dismissals, ['condition']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('dismiss all shows storage failures and allows retry', (
    tester,
  ) async {
    await publish();
    await publishUpdate();
    await mount(tester);
    await open(tester);
    failSaves = true;
    await tap(tester, find.byTooltip('Dismiss all notifications'));
    expect(center.value, hasLength(2));
    expect(dismissals, isEmpty);
    expect(find.text(center.error!), findsOneWidget);
    failSaves = false;
    await tap(tester, find.byTooltip('Dismiss all notifications'));
    expect(center.value, isEmpty);
    expect(center.error, isNull);
    expect(dismissals, ['condition', 'skip 99.0.0']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('full list scrolls within the height cap with fixed controls', (
    tester,
  ) async {
    await tester.runAsync(() async {
      for (var index = 0; index < 20; index++) {
        await center.publish(
          NativeNotification(
            namespace: NotificationNamespace.plugin,
            sourceId: 'plugin-${index ~/ 5}',
            sourceName: 'Plugin ${index ~/ 5}',
            id: '$index',
            message: 'Notification $index',
            actions: const [],
          ),
        );
      }
    });
    await publishUpdate();
    await mount(tester);
    await open(tester);
    final dialog = tester.getRect(
      find.descendant(
        of: find.byType(ShadDialog),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is ConstrainedBox && widget.constraints.maxWidth == 720,
        ),
      ),
    );
    expect(dialog.height, lessThanOrEqualTo(600 * .85));
    final close = tester.getRect(find.byTooltip('Close'));
    final dismissAll = tester.getRect(
      find.byTooltip('Dismiss all notifications'),
    );
    await tester.scrollUntilVisible(
      find.text('Update available: 99.0.0'),
      300,
      scrollable: find.descendant(
        of: find.byType(NotificationOverlay),
        matching: find.byType(Scrollable),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.byTooltip('Close')), close);
    expect(
      tester.getRect(find.byTooltip('Dismiss all notifications')),
      dismissAll,
    );
    expect(find.text('Notification 0'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'bell appears only for unread notices and dashboard keeps read and empty access',
    (tester) async {
      await mount(tester);
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.text('Notifications'), findsOneWidget);
      await publish();
      await publish(id: 'second');
      await tester.pumpAndSettle();
      expect(find.byTooltip('Notifications (2 unread)'), findsOneWidget);
      expect(
        tester.getRect(find.byType(FloatingActionButton)).bottom,
        lessThanOrEqualTo(tester.getRect(find.byType(Scaffold)).bottom - 80),
      );
      await open(tester);
      expect(center.unreadCount, 0);
      expect(find.byType(FloatingActionButton), findsNothing);
      await tap(tester, find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(center.value, hasLength(2));
      expect(dismissals, isEmpty);
      await tap(tester, find.text('Notifications'));
      await tester.pumpAndSettle();
      await tap(tester, find.byTooltip('Dismiss notification').first);
      await tester.pumpAndSettle();
      await tap(tester, find.byTooltip('Dismiss notification').first);
      await tester.pumpAndSettle();
      expect(find.text('No notifications'), findsOneWidget);
      expect(dismissals, ['condition', 'second']);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('arrivals and replacements while open remain unread', (
    tester,
  ) async {
    await publish();
    await mount(tester);
    await open(tester);
    await publish(id: 'arrival');
    await publish(message: 'Changed');
    await tester.pumpAndSettle();
    expect(center.unreadCount, 2);
    await tap(tester, find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(center.unreadCount, 2);
    await open(tester);
    expect(center.unreadCount, 0);
    await tester.pumpWidget(const SizedBox());
  });

  for (final close in ['back', 'escape', 'outside']) {
    testWidgets('$close closes only the overlay', (tester) async {
      await publish();
      await mount(tester);
      await open(tester);
      if (close == 'back') {
        await tester.binding.handlePopRoute();
      } else if (close == 'escape') {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      } else {
        await tester.tapAt(const Offset(3, 3));
      }
      await tester.pumpAndSettle();
      expect(find.byType(NotificationOverlay), findsNothing);
      expect(center.value, hasLength(1));
      expect(dismissals, isEmpty);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('closing the overlay preserves browser-return tracking', (
    tester,
  ) async {
    await publish();
    await mount(tester);
    await open(tester);
    await tap(tester, find.text('Support'));
    await tester.pumpAndSettle();
    await tap(tester, find.byTooltip('Close'));
    await tester.pumpAndSettle();
    actions.didChangeAppLifecycleState(AppLifecycleState.inactive);
    actions.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(phases, ['activated', 'returned']);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('restored actions are disabled pending confirmation', (
    tester,
  ) async {
    await publish(confirmed: false);
    await mount(tester);
    await open(tester);
    expect(find.text('Awaiting confirmation'), findsOneWidget);
    expect(
      tester.widget<ShadButton>(find.byType(ShadButton).last).enabled,
      isFalse,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('download confirmation replaces rather than stacks the list', (
    tester,
  ) async {
    var overlayPresentAtConfirmation = false;
    var downloadCalls = 0;
    var installCalls = 0;
    await tester.runAsync(() async {
      await center.publish(
        NativeNotification(
          namespace: NotificationNamespace.host,
          sourceId: 'app-update',
          sourceName: 'Decaid',
          id: '99.0.0',
          message: 'Update available: 99.0.0',
          actions: const [
            NotificationAction(
              id: 'download',
              label: 'Download',
              type: NotificationActionType.downloadUpdate,
            ),
          ],
        ),
        binding: NotificationBinding(
          onActivate: (_) async {
            overlayPresentAtConfirmation = find
                .byType(NotificationOverlay)
                .evaluate()
                .isNotEmpty;
            await showDialog<void>(
              context: tester.element(find.byType(Scaffold)),
              builder: (_) => UpdateDialog(
                updateInfo: UpdateInfo(
                  version: '99.0.0',
                  downloadUrl: 'https://example.com/app.apk',
                  releaseNotes: 'Changes',
                  isPrerelease: false,
                  tagName: 'v99.0.0',
                ),
                currentVersion: '0.9.0',
                onViewReleaseNotes: () {},
                onDownload: (_, _) async {
                  downloadCalls++;
                  return '/tmp/app.apk';
                },
                onInstall: (_) async {
                  installCalls++;
                  return false;
                },
              ),
            );
          },
        ),
      );
    });
    await mount(tester);
    await open(tester);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsOneWidget);
    expect(overlayPresentAtConfirmation, isFalse);
    expect(find.byType(NotificationOverlay), findsNothing);
    expect(downloadCalls, 0);
    expect(installCalls, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsNothing);
    expect(center.value.single.id, '99.0.0');
    expect(center.unreadCount, 0);
    expect(downloadCalls, 0);
    expect(installCalls, 0);
    await tester.pumpWidget(const SizedBox());
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'long notices fit narrow screens and large text in $brightness',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await publishUpdate();
        await publish(message: 'longtext' * 75);
        await mount(tester, textScale: 2, brightness: brightness);
        await open(tester);
        expect(tester.takeException(), isNull);
        final dialog = tester.getRect(
          find.descendant(
            of: find.byType(ShadDialog),
            matching: find.byWidgetPredicate(
              (widget) =>
                  widget is ConstrainedBox &&
                  widget.constraints.maxWidth == 720,
            ),
          ),
        );
        expect(dialog.width, lessThanOrEqualTo(320));
        expect(dialog.height, lessThanOrEqualTo(568 * .85));
        expect(find.byTooltip('Close'), findsOneWidget);
        expect(find.byTooltip('Dismiss all notifications'), findsOneWidget);
        expect(find.byTooltip('Skip version 99.0.0'), findsOneWidget);
        final heading = tester.getRect(find.text('Notifications').last);
        final dismissAll = tester.getRect(
          find.byTooltip('Dismiss all notifications'),
        );
        final close = tester.getRect(find.byTooltip('Close'));
        expect(heading.right, lessThanOrEqualTo(dismissAll.left));
        expect(dismissAll.right, lessThanOrEqualTo(close.left));
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'actual skin keeps WebView bounds, mount and existing Snackbar actions',
    (tester) async {
      final logs = WebViewLogService(logDirectoryPath: '.');
      final de1 = MockDe1Controller(controller: DeviceController(const []));
      final settings = SettingsController(MockSettingsService());
      final display = DisplayController(
        de1Controller: de1,
        settingsController: settings,
      );
      addTearDown(() {
        display.dispose();
        logs.dispose();
      });
      final webKey = GlobalKey();
      await tester.pumpWidget(
        ShadApp(
          builder: (context, child) => ScaffoldMessenger(child: child!),
          home: SkinView(
            settingsController: settings,
            webViewLogService: logs,
            deviceIp: '127.0.0.1',
            displayController: display,
            port: 43210,
            webView: _WebView(key: webKey),
            notificationCenter: center,
            notificationActions: actions,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      final state = webKey.currentState;
      final bounds = tester.getRect(find.byKey(webKey));
      final skin = tester.element(find.byType(SkinView));
      var originalAction = 0;
      ScaffoldMessenger.of(skin).showSnackBar(
        SnackBar(
          content: const Text('Skin exit instructions'),
          duration: const Duration(minutes: 1),
          action: SnackBarAction(
            label: 'Original action',
            onPressed: () => originalAction++,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await publish();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.getRect(find.byKey(webKey)), bounds);
      expect(webKey.currentState, same(state));
      await open(tester);
      expect(tester.getRect(find.byKey(webKey)), bounds);
      expect(webKey.currentState, same(state));
      await tap(tester, find.byTooltip('Close'));
      expect(find.text('Skin exit instructions'), findsOneWidget);
      await tester.tap(find.text('Original action'));
      expect(originalAction, 1);
      expect(webKey.currentState, same(state));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('notification controls have labels and accessible tap targets', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      await publish();
      await publishUpdate();
      await mount(tester);
      expect(find.bySemanticsLabel('Notifications (2)'), findsOneWidget);
      await open(tester);
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await tester.pumpWidget(const SizedBox());
    } finally {
      handle.dispose();
    }
  });
}
