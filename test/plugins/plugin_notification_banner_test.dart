import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:reaprime/src/plugins/plugin_notification_banner.dart';
import 'package:reaprime/src/plugins/plugin_notifications.dart';
import 'package:shadcn_ui/shadcn_ui.dart' show ShadApp;
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _Launcher extends Fake
    with MockPlatformInterfaceMixin
    implements UrlLauncherPlatform {
  final launches = <({String url, LaunchOptions options})>[];
  bool succeeds = true;
  Completer<bool>? result;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launches.add((url: url, options: options));
    if (result != null) return result!.future;
    return succeeds;
  }
}

void main() {
  late PluginNotificationCenter center;
  late _Launcher launcher;
  final actions = <String>[];
  final dismissals = <String>[];
  var accountOpens = 0;

  setUp(() {
    center = PluginNotificationCenter();
    actions.clear();
    dismissals.clear();
    accountOpens = 0;
    launcher = _Launcher();
    final original = UrlLauncherPlatform.instance;
    UrlLauncherPlatform.instance = launcher;
    addTearDown(() => UrlLauncherPlatform.instance = original);
  });
  tearDown(() => center.dispose());

  void show(String plugin, {bool account = false}) {
    center.show(
      pluginId: plugin,
      pluginName: 'Plugin $plugin',
      payload: {
        'id': 'condition',
        'message': '$plugin needs attention',
        'action': {
          'id': 'help',
          'label': account ? 'Account' : 'Help',
          'type': account ? 'openDecentAccount' : 'openExternalUrl',
          if (!account) 'url': 'https://example.com/help',
        },
      },
      canOpenAccount: true,
      onAction: (event) => actions.add('$plugin:${event['phase']}'),
      onDismissed: (event) => dismissals.add('$plugin:${event['id']}'),
    );
  }

  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => PluginNotificationBanner(
        center: center,
        onOpenAccount: () => accountOpens++,
        child: child!,
      ),
      home: const Scaffold(body: Text('Existing Decaid content')),
    ),
  );

  testWidgets('renders above the ShadApp navigator used by Decaid', (
    tester,
  ) async {
    await tester.pumpWidget(
      ScaffoldMessenger(
        child: ShadApp(
          builder: (context, child) => PluginNotificationBanner(
            center: center,
            onOpenAccount: () => accountOpens++,
            child: child!,
          ),
          home: const Scaffold(body: Text('Existing Decaid content')),
        ),
      ),
    );
    show('first');
    await tester.pumpAndSettle();
    expect(find.text('first needs attention'), findsOneWidget);
    expect(find.text('Existing Decaid content'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('plugin notices coexist with existing snackbars and each other', (
    tester,
  ) async {
    await mount(tester);
    final appContext = tester.element(find.byType(Scaffold));
    expect(
      Overlay.of(appContext, rootOverlay: true),
      Navigator.of(appContext).overlay,
    );
    final messenger = ScaffoldMessenger.of(
      tester.element(find.byType(Scaffold)),
    );
    var originalAction = 0;
    messenger.showSnackBar(
      SnackBar(
        content: const Text('Update available'),
        duration: const Duration(days: 1),
        action: SnackBarAction(
          label: 'Install',
          onPressed: () => originalAction++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    show('first');
    show('second');
    await tester.pumpAndSettle();
    expect(find.text('Update available'), findsOneWidget);
    expect(find.text('first needs attention'), findsOneWidget);
    expect(find.text('second needs attention'), findsOneWidget);
    await tester.tap(find.byTooltip('Dismiss notification from Plugin first'));
    await tester.pumpAndSettle();
    expect(find.text('first needs attention'), findsNothing);
    expect(find.text('second needs attention'), findsOneWidget);
    expect(find.text('Update available'), findsOneWidget);
    expect(dismissals, ['first:condition']);
    await tester.tap(find.text('Install'));
    expect(originalAction, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'external link return is targeted and only follows leaving the app',
    (tester) async {
      await mount(tester);
      show('first');
      await tester.pumpAndSettle();
      expect(find.text('example.com'), findsOneWidget);
      await tester.tap(find.text('Help'));
      await tester.pump();
      expect(launcher.launches.single.url, 'https://example.com/help');
      expect(
        launcher.launches.single.options.mode,
        PreferredLaunchMode.externalApplication,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(actions, ['first:activated']);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(actions, ['first:activated', 'first:returned']);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      expect(actions.length, 2);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant({TargetPlatform.iOS}),
  );

  testWidgets('dismissed notices cannot deliver stale browser returns', (
    tester,
  ) async {
    await mount(tester);
    show('first');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Help'));
    await tester.pump();
    await tester.tap(find.byTooltip('Dismiss notification from Plugin first'));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(actions, ['first:activated']);
    expect(dismissals, ['first:condition']);
    await tester.pumpWidget(const SizedBox());
  });

  for (final succeeds in [false, true]) {
    testWidgets(
      'a return during a pending launch waits for success=$succeeds',
      (tester) async {
        await mount(tester);
        show('first');
        launcher.result = Completer<bool>();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Help'));
        await tester.pump();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        expect(actions, ['first:activated']);
        launcher.result!.complete(succeeds);
        await tester.pumpAndSettle();
        expect(actions, [
          'first:activated',
          succeeds ? 'first:returned' : 'first:failed',
        ]);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'account navigation and failed launches report approved outcomes',
    (tester) async {
      await mount(tester);
      show('first', account: true);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Account'));
      expect(accountOpens, 1);
      expect(actions, ['first:activated']);
      center.dismiss('first');
      launcher.succeeds = false;
      show('second');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Help'));
      await tester.pumpAndSettle();
      expect(actions.last, 'second:failed');
      expect(find.text('Could not open link'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('long notices fit a small viewport without hiding app content', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester);
    center.show(
      pluginId: 'first',
      pluginName: 'First',
      payload: {'id': 'condition', 'message': 'longtext' * 75},
      canOpenAccount: false,
      onAction: (_) {},
    );
    await tester.pumpAndSettle();
    expect(find.text('Existing Decaid content'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
