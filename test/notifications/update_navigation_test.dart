import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/app.dart';
import 'package:reaprime/src/launcher/launcher_view.dart';
import 'package:reaprime/src/notifications/native_notification.dart';
import 'package:reaprime/src/notifications/notification_actions.dart';
import 'package:reaprime/src/notifications/notification_center.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/settings/settings_view.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';

class _SettingsPage extends StatefulWidget {
  const _SettingsPage();

  @override
  State<_SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<_SettingsPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Updater'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('Settings'));
}

void main() {
  for (final fromSkin in [false, true]) {
    testWidgets(
      'update View routes from skin=$fromSkin through the launcher once',
      (tester) async {
        final navigator = GlobalKey<NavigatorState>();
        final update = UpdateInfo(
          version: '99.0.0',
          downloadUrl: 'https://example.com/update.apk',
          releaseNotes: 'Changes',
          isPrerelease: false,
          tagName: 'v99.0.0',
        );
        final opened = <UpdateInfo>[];
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            initialRoute: LauncherView.routeName,
            onGenerateRoute: (route) {
              if (route.name == SettingsView.routeName) {
                opened.add(route.arguments! as UpdateInfo);
              }
              return MaterialPageRoute<void>(
                settings: route,
                builder: (_) => route.name == SettingsView.routeName
                    ? const _SettingsPage()
                    : Scaffold(
                        body: Text(
                          route.name == SkinView.routeName
                              ? 'Skin'
                              : 'Dashboard',
                        ),
                      ),
              );
            },
          ),
        );
        await tester.pumpAndSettle();
        if (fromSkin) {
          navigator.currentState!.pushNamed(SkinView.routeName);
          await tester.pumpAndSettle();
        }

        final center = NotificationCenter();
        final launched = <Uri>[];
        final actions = NotificationActions(
          center: center,
          onOpenAccount: () {},
          launch: (url) async {
            launched.add(url);
            return true;
          },
        );
        addTearDown(actions.dispose);
        addTearDown(center.dispose);
        const action = NotificationAction(
          id: 'view',
          label: 'View',
          type: NotificationActionType.downloadUpdate,
        );
        await tester.runAsync(
          () => center.publish(
            NativeNotification(
              namespace: NotificationNamespace.host,
              sourceId: 'app-update',
              sourceName: 'Decaid',
              id: update.version,
              message: 'Update available',
              actions: const [action],
            ),
            binding: NotificationBinding(
              onActivate: (_) =>
                  openAppUpdateSettings(navigator.currentState!, update),
            ),
          ),
        );
        final notice = center.value.single;
        final opening = actions.activate(notice, action);
        await actions.activate(notice, action);
        await tester.pumpAndSettle();

        expect(find.text('Settings'), findsOneWidget);
        expect(find.text('Skin', skipOffstage: false), findsNothing);
        expect(find.text('Dashboard', skipOffstage: false), findsOneWidget);
        expect(opened, [same(update)]);
        expect(find.text('Updater'), findsOneWidget);
        expect(actions.busy, isFalse);
        await opening;

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(find.text('Settings'), findsOneWidget);

        final pluginAction = NotificationAction(
          id: 'help',
          label: 'Help',
          type: NotificationActionType.openExternalUrl,
          url: Uri.parse('https://example.com/help'),
        );
        await tester.runAsync(
          () => center.publish(
            NativeNotification(
              namespace: NotificationNamespace.plugin,
              sourceId: 'example',
              sourceName: 'Example',
              id: 'help',
              message: 'Help available',
              actions: [pluginAction],
            ),
            binding: NotificationBinding(),
          ),
        );
        await actions.activate(center.value.last, pluginAction);
        expect(launched, [pluginAction.url]);
        expect(actions.busy, isFalse);

        final reopening = actions.activate(notice, action);
        await actions.activate(notice, action);
        await tester.pumpAndSettle();
        await reopening;
        expect(opened, [same(update), same(update)]);
        expect(find.text('Updater'), findsOneWidget);
        expect(actions.busy, isFalse);

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.text('Dashboard'), findsOneWidget);
        expect(actions.busy, isFalse);
      },
    );
  }
}
