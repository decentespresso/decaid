import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:reaprime/src/notifications/native_notification.dart';
import 'package:reaprime/src/notifications/notification_actions.dart';
import 'package:reaprime/src/notifications/notification_center.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _Launcher extends Fake
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
  TestWidgetsFlutterBinding.ensureInitialized();
  late NotificationCenter center;
  late NotificationActions actions;
  late Completer<bool> launch;
  final phases = <String>[];
  final action = NotificationAction(
    id: 'support',
    label: 'Support',
    type: NotificationActionType.openExternalUrl,
    url: Uri.parse('https://example.com/'),
  );
  final notice = NativeNotification(
    namespace: NotificationNamespace.plugin,
    sourceId: 'plugin',
    sourceName: 'Plugin',
    id: 'pause',
    message: 'Paused',
    actions: [action],
  );

  setUp(() async {
    phases.clear();
    launch = Completer<bool>();
    center = NotificationCenter();
    actions = NotificationActions(
      center: center,
      onOpenAccount: () {},
      launch: (_) => launch.future,
    );
    await center.publish(
      notice,
      binding: NotificationBinding(onAction: (_, phase) => phases.add(phase)),
    );
  });
  tearDown(() {
    actions.dispose();
    center.dispose();
  });

  testWidgets('default link actions use the external browser on iOS', (
    tester,
  ) async {
    final original = UrlLauncherPlatform.instance;
    final launcher = _Launcher();
    UrlLauncherPlatform.instance = launcher;
    try {
      actions.dispose();
      actions = NotificationActions(center: center, onOpenAccount: () {});
      await actions.activate(center.value.single, action);
      expect(launcher.launches.single.url, action.url.toString());
      expect(
        launcher.launches.single.options.mode,
        PreferredLaunchMode.externalApplication,
      );
      expect(phases, ['activated']);
    } finally {
      UrlLauncherPlatform.instance = original;
    }
  }, variant: TargetPlatformVariant({TargetPlatform.iOS}));

  test(
    'account actions navigate without opening an external browser',
    () async {
      var accountOpens = 0;
      actions.dispose();
      actions = NotificationActions(
        center: center,
        onOpenAccount: () => accountOpens++,
        launch: (_) async =>
            throw StateError('Account actions stay in the app'),
      );
      const account = NotificationAction(
        id: 'account',
        label: 'Sign In',
        type: NotificationActionType.openDecentAccount,
      );
      await center.publish(
        NativeNotification(
          namespace: notice.namespace,
          sourceId: notice.sourceId,
          sourceName: notice.sourceName,
          id: notice.id,
          message: notice.message,
          actions: const [account],
        ),
        binding: NotificationBinding(onAction: (_, phase) => phases.add(phase)),
      );
      await actions.activate(center.value.single, account);
      expect(accountOpens, 1);
      expect(phases, ['activated']);
    },
  );

  test(
    'read and popup closure cannot cancel a successful browser return',
    () async {
      final opening = actions.activate(center.value.single, action);
      await center.markRead(center.value);
      actions.didChangeAppLifecycleState(AppLifecycleState.inactive);
      actions.didChangeAppLifecycleState(AppLifecycleState.resumed);
      launch.complete(true);
      await opening;
      expect(phases, ['activated', 'returned']);
      actions.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(phases, ['activated', 'returned']);
    },
  );

  test('failed launch cannot report return and can be retried', () async {
    final opening = actions.activate(center.value.single, action);
    actions.didChangeAppLifecycleState(AppLifecycleState.inactive);
    actions.didChangeAppLifecycleState(AppLifecycleState.resumed);
    launch.complete(false);
    await opening;
    expect(phases, ['activated', 'failed']);
    expect(actions.errorFor(center.value.single), isNotNull);
  });

  for (final retire in [false, true]) {
    test(
      'download handoff prevents reentry and honors retirement=$retire',
      () async {
        const download = NotificationAction(
          id: 'download',
          label: 'Download',
          type: NotificationActionType.downloadUpdate,
        );
        var preparations = 0;
        var confirmations = 0;
        final closing = Completer<void>();
        await center.publish(
          NativeNotification(
            namespace: NotificationNamespace.host,
            sourceId: 'app-update',
            sourceName: 'Decaid',
            id: '99.0.0',
            message: 'Update available: 99.0.0',
            actions: const [download],
          ),
          binding: NotificationBinding(
            onActivate: (_) async => confirmations++,
          ),
        );
        final current = center.value.last;
        Future<void> prepare() {
          preparations++;
          return closing.future;
        }

        final opening = actions.activate(
          current,
          download,
          beforeDownload: prepare,
        );
        await actions.activate(current, download, beforeDownload: prepare);
        expect(preparations, 1);
        expect(confirmations, 0);
        expect(actions.busy, isTrue);
        if (retire) {
          center.retireSource(NotificationNamespace.host, 'app-update');
        }
        closing.complete();
        await opening;
        expect(confirmations, retire ? 0 : 1);
        expect(actions.busy, isFalse);
      },
    );
  }

  for (final retirement in ['replacement', 'removal', 'reload']) {
    test('$retirement invalidates a pending launch and return', () async {
      final opening = actions.activate(center.value.single, action);
      if (retirement == 'replacement') {
        await center.publish(
          NativeNotification(
            namespace: notice.namespace,
            sourceId: notice.sourceId,
            sourceName: notice.sourceName,
            id: notice.id,
            message: 'Changed',
            actions: [action],
          ),
          binding: NotificationBinding(),
        );
      } else if (retirement == 'removal') {
        await center.removeSource(NotificationNamespace.plugin, 'plugin');
      } else {
        center.retireSource(NotificationNamespace.plugin, 'plugin');
        await center.publish(notice, binding: NotificationBinding());
      }
      launch.complete(true);
      await opening;
      actions.didChangeAppLifecycleState(AppLifecycleState.hidden);
      actions.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(phases, ['activated']);
    });
  }
}
