import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:reaprime/src/plugins/shot_upload_notifications.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _RecordingUrlLauncher extends Fake
    with MockPlatformInterfaceMixin
    implements UrlLauncherPlatform {
  final launches = <({String url, LaunchOptions options})>[];

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launches.add((url: url, options: options));
    return true;
  }
}

void main() {
  late StreamController<Map<String, dynamic>> events;
  var signIns = 0;
  var support = 0;
  var refreshes = 0;
  var ownershipRefreshes = 0;

  setUp(() {
    events = StreamController<Map<String, dynamic>>.broadcast();
    signIns = 0;
    support = 0;
    refreshes = 0;
    ownershipRefreshes = 0;
  });
  tearDown(() => events.close());

  test(
    'iOS Support uses an external browser rather than in-app Safari',
    () async {
      final original = UrlLauncherPlatform.instance;
      final launcher = _RecordingUrlLauncher();
      UrlLauncherPlatform.instance = launcher;
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() {
        UrlLauncherPlatform.instance = original;
        debugDefaultTargetPlatformOverride = null;
      });
      await openShotUploadSupport();
      expect(
        launcher.launches.single.url,
        'https://decentespresso.com/support/',
      );
      expect(
        launcher.launches.single.options.mode,
        PreferredLaunchMode.externalApplication,
      );
    },
  );

  Future<void> mount(
    WidgetTester tester, {
    Future<void> Function()? refreshAccount,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ShotUploadNotifications(
          events: events.stream,
          onSignIn: () => signIns++,
          onSupport: () => support++,
          refreshOwnership: () => ownershipRefreshes++,
          refreshAccount: refreshAccount ?? () async => refreshes++,
          child: const SizedBox(),
        ),
      ),
    ),
  );

  void pause(
    String reason, {
    String? serial,
    String plugin = 'shot-upload.reaplugin',
  }) {
    events.add({
      'pluginId': plugin,
      'event': 'uploadPaused',
      'payload': {'reason': reason, 'serialNumber': serial},
    });
  }

  testWidgets(
    'shows an unlinked serial with a support action and rechecks on return',
    (tester) async {
      await mount(tester);
      pause('unlinked_serial', serial: '6262');
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.textContaining("serial 6262"), findsOneWidget);
      expect(find.textContaining("isn't linked"), findsOneWidget);
      await tester.tap(find.text('Support'));
      expect(support, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(refreshes, 1);
      expect(ownershipRefreshes, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'authentication pause asks for sign-in without a false ownership message',
    (tester) async {
      await mount(tester);
      pause('authentication');
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.textContaining('Please sign in'), findsOneWidget);
      expect(find.textContaining("isn't linked"), findsNothing);
      await tester.tap(find.text('Sign In'));
      expect(signIns, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('upload pause takes priority over a persistent update banner', (
    tester,
  ) async {
    await mount(tester);
    final context = tester.element(find.byType(ShotUploadNotifications));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Update available'),
        duration: Duration(days: 1),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Update available'), findsOneWidget);
    pause('authentication');
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('Update available'), findsNothing);
    expect(find.textContaining('Please sign in'), findsOneWidget);
    expect(find.text('Sign In'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('ignores unrelated plugins and malformed notices', (
    tester,
  ) async {
    await mount(tester);
    pause('unlinked_serial', serial: '6262', plugin: 'other.reaplugin');
    pause('unlinked_serial');
    pause('unknown', serial: '6262');
    await tester.pump();
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(const SizedBox());
    expect(events.hasListener, isFalse);
  });

  testWidgets(
    'support return invalidates ownership before a failed host refresh',
    (tester) async {
      await mount(
        tester,
        refreshAccount: () async {
          expect(ownershipRefreshes, 1);
          refreshes++;
          throw StateError('temporarily offline');
        },
      );
      pause('unlinked_serial', serial: '6262');
      await tester.pump();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Support'));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(ownershipRefreshes, 1);
      expect(refreshes, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
