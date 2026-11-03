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
  final phases = <String>[];

  setUp(() {
    center = NotificationCenter();
    phases.clear();
    actions = NotificationActions(
      center: center,
      onOpenAccount: () {},
      launch: (_) async => true,
    );
  });
  tearDown(() {
    actions.dispose();
    center.dispose();
  });

  Future<void> publish({
    String id = 'condition',
    String? message,
    bool confirmed = true,
    String source = 'plugin',
  }) async {
    await TestWidgetsFlutterBinding.instance.runAsync(
      () => center.publish(
        NativeNotification(
          namespace: NotificationNamespace.plugin,
          sourceId: source,
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
            ? NotificationBinding(onAction: (_, phase) => phases.add(phase))
            : null,
      ),
    );
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

  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.runAsync(() async {
      await tester.tap(target);
      await Future<void>.delayed(Duration.zero);
      await center.settled;
    });
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) =>
      tap(tester, find.text('Notifications'));

  testWidgets(
    'localized close X only closes and preserves later unread arrivals',
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
      expect(find.byIcon(LucideIcons.trash2), findsNothing);
      await publish(id: 'arrival');
      await tester.pumpAndSettle();
      await tap(tester, find.byTooltip(label));
      expect(find.byType(NotificationOverlay), findsNothing);
      expect(center.value, hasLength(2));
      expect(center.unreadCount, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'full center scrolls within the height cap with a fixed close control',
    (tester) async {
      for (var i = 0; i < 20; i++) {
        await publish(
          id: '$i',
          source: 'plugin-${i ~/ 5}',
          message: 'Notification $i',
        );
      }
      await mount(tester);
      await open(tester);
      final dialog = tester.getRect(
        find.descendant(
          of: find.byType(ShadDialog),
          matching: find.byWidgetPredicate(
            (w) => w is ConstrainedBox && w.constraints.maxWidth == 720,
          ),
        ),
      );
      expect(dialog.height, lessThanOrEqualTo(600 * .85));
      final close = tester.getRect(find.byTooltip('Close'));
      await tester.scrollUntilVisible(
        find.text('Notification 19'),
        300,
        scrollable: find.descendant(
          of: find.byType(NotificationOverlay),
          matching: find.byType(Scrollable),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(tester.getRect(find.byTooltip('Close')), close);
      expect(find.byIcon(LucideIcons.trash2), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'launcher retains read conditions and empty access without a bell',
    (tester) async {
      await mount(tester);
      expect(find.byType(FloatingActionButton), findsNothing);
      await open(tester);
      expect(find.text('No notifications'), findsOneWidget);
      await tap(tester, find.byTooltip('Close'));
      await publish();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Notifications (1 unread)'), findsOneWidget);
      await open(tester);
      expect(center.unreadCount, 0);
      expect(find.byType(FloatingActionButton), findsNothing);
      await tap(tester, find.byTooltip('Close'));
      await open(tester);
      expect(find.text('Needs attention'), findsOneWidget);
      expect(find.text('Support'), findsOneWidget);
      await tester.runAsync(
        () => center.removeSource(NotificationNamespace.plugin, 'plugin'),
      );
      await tester.pumpAndSettle();
      expect(find.text('No notifications'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

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
    await tap(tester, find.byTooltip('Close'));
    actions.didChangeAppLifecycleState(AppLifecycleState.inactive);
    actions.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(phases, ['activated', 'returned']);
    expect(center.value, hasLength(1));
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

  testWidgets('download confirmation replaces rather than stacks the center', (
    tester,
  ) async {
    var overlayPresent = false;
    var downloads = 0;
    await tester.runAsync(
      () => center.publish(
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
            overlayPresent = find
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
                  downloads++;
                  return '/tmp/app.apk';
                },
                onInstall: (_) async => false,
              ),
            );
          },
        ),
      ),
    );
    await mount(tester);
    await open(tester);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.byType(UpdateDialog), findsOneWidget);
    expect(overlayPresent, isFalse);
    expect(downloads, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(center.value.single.id, '99.0.0');
    expect(center.unreadCount, 0);
    expect(downloads, 0);
    await tester.pumpWidget(const SizedBox());
  });

  for (final brightness in Brightness.values) {
    for (final compact in [false, true]) {
      testWidgets(
        'long text fits narrow large-text $brightness compact=$compact',
        (tester) async {
          tester.view.physicalSize = const Size(320, 568);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await publish(message: 'longtext' * 75);
          await mount(tester, textScale: 2, brightness: brightness);
          await tap(
            tester,
            compact
                ? find.byType(FloatingActionButton)
                : find.text('Notifications'),
          );
          expect(tester.takeException(), isNull);
          final dialog = tester.getRect(
            find.descendant(
              of: find.byType(ShadDialog),
              matching: find.byWidgetPredicate(
                (w) =>
                    w is ConstrainedBox &&
                    w.constraints.maxWidth == (compact ? 480 : 720),
              ),
            ),
          );
          expect(dialog.width, lessThanOrEqualTo(320));
          expect(dialog.height, lessThanOrEqualTo(568 * .85));
          expect(find.byTooltip('Close'), findsOneWidget);
          expect(find.byIcon(LucideIcons.trash2), findsNothing);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  testWidgets(
    'skin keeps WebView bounds, mount and existing Snackbar actions',
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
      var originalAction = 0;
      ScaffoldMessenger.of(tester.element(find.byType(SkinView))).showSnackBar(
        SnackBar(
          content: const Text('Skin exit instructions'),
          duration: const Duration(minutes: 1),
          action: SnackBarAction(
            label: 'Original action',
            onPressed: () => originalAction++,
          ),
        ),
      );
      await publish();
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.getRect(find.byKey(webKey)), bounds);
      expect(webKey.currentState, same(state));
      await tester.runAsync(() async {
        await tester.tap(find.byType(FloatingActionButton));
        await center.settled;
      });
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.getRect(find.byKey(webKey)), bounds);
      expect(webKey.currentState, same(state));
      await tester.tap(find.byTooltip('Close'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Skin exit instructions'), findsOneWidget);
      await tester.tap(find.text('Original action'));
      expect(originalAction, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final compact in [false, true]) {
    testWidgets(
      'controls have labels and accessible tap targets compact=$compact',
      (tester) async {
        final handle = tester.ensureSemantics();
        try {
          await publish();
          await mount(tester);
          await tap(
            tester,
            compact
                ? find.byType(FloatingActionButton)
                : find.text('Notifications'),
          );
          await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
          await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
          await tester.pumpWidget(const SizedBox());
        } finally {
          handle.dispose();
        }
      },
    );
  }
}
