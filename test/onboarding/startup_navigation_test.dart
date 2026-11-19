import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/app.dart';
import 'package:reaprime/src/launcher/launcher_view.dart';
import 'package:reaprime/src/onboarding_feature/startup_navigation_guard.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/settings_view.dart';
import 'package:reaprime/src/skin_feature/skin_view.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';

import '../helpers/mock_settings_service.dart';

const _onboardingRoute = '/onboarding';

class _Storage extends WebUIStorage {
  _Storage() : super(SettingsController(MockSettingsService()));

  @override
  WebUISkin get defaultSkin =>
      WebUISkin(id: 'local', name: 'Local', path: '/local');
}

class _Service extends WebUIService {
  final ready = Completer<void>();
  int serveCalls = 0;

  @override
  Future<void> serveFolderAtPath(String path, {int port = 3000}) {
    serveCalls++;
    return ready.future;
  }
}

class _RouteRecorder extends NavigatorObserver {
  final List<Route<dynamic>> pushed = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route);
  }
}

Widget _app({
  Key? key,
  required GlobalKey<NavigatorState> navigatorKey,
  required List<NavigatorObserver> observers,
  void Function(BuildContext owner)? onOwner,
}) => MaterialApp(
  key: key,
  navigatorKey: navigatorKey,
  navigatorObservers: observers,
  builder: (context, child) {
    onOwner?.call(context);
    return child!;
  },
  initialRoute: _onboardingRoute,
  routes: {
    _onboardingRoute: (_) => const Scaffold(body: Text('onboarding')),
    LauncherView.routeName: (_) => const Scaffold(body: Text('launcher')),
    SettingsView.routeName: (context) {
      final arguments = ModalRoute.of(context)?.settings.arguments;
      return Scaffold(body: Text('settings $arguments'));
    },
    SkinView.routeName: (_) => const Scaffold(body: Text('skin')),
  },
);

void main() {
  testWidgets(
    'pending startup serving stays on Settings opened while serving',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      final guard = StartupNavigationGuard();
      await tester.pumpWidget(
        _app(navigatorKey: navigatorKey, observers: [guard]),
      );
      final navigator = navigatorKey.currentState!;
      navigator.pushNamedAndRemoveUntil(LauncherView.routeName, (_) => false);
      await tester.pumpAndSettle();
      expect(find.text('launcher'), findsOneWidget);

      final service = _Service();
      var opens = 0;
      final opening = openStartupSkin(
        service: service,
        storage: _Storage(),
        isCurrent: () =>
            navigator.mounted &&
            identical(navigator, navigatorKey.currentState),
        navigationGuard: guard,
        openSkin: () {
          opens++;
          SkinView.open(navigator);
        },
      );
      await tester.pump();
      expect(service.serveCalls, 1);
      expect(opens, 0);

      navigator.pushNamed(SettingsView.routeName, arguments: 'v0.2.4');
      await tester.pumpAndSettle();
      expect(find.text('settings v0.2.4'), findsOneWidget);

      service.ready.complete();
      await opening;
      await tester.pumpAndSettle();

      expect(find.text('settings v0.2.4'), findsOneWidget);
      expect(find.text('skin'), findsNothing);
      expect(find.text('launcher'), findsNothing);
      expect(opens, 0);
    },
  );

  testWidgets(
    'Settings opened and closed while serving still blocks the automatic skin',
    (tester) async {
      final navigatorKey = GlobalKey<NavigatorState>();
      final guard = StartupNavigationGuard();
      await tester.pumpWidget(
        _app(navigatorKey: navigatorKey, observers: [guard]),
      );
      final navigator = navigatorKey.currentState!;
      navigator.pushNamedAndRemoveUntil(LauncherView.routeName, (_) => false);
      await tester.pumpAndSettle();

      final service = _Service();
      var opens = 0;
      final opening = openStartupSkin(
        service: service,
        storage: _Storage(),
        isCurrent: () =>
            navigator.mounted &&
            identical(navigator, navigatorKey.currentState),
        navigationGuard: guard,
        openSkin: () {
          opens++;
          SkinView.open(navigator);
        },
      );
      await tester.pump();

      navigator.pushNamed(SettingsView.routeName, arguments: 'v0.2.4');
      await tester.pumpAndSettle();
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.text('launcher'), findsOneWidget);

      service.ready.complete();
      await opening;
      await tester.pumpAndSettle();

      expect(opens, 0);
      expect(find.text('launcher'), findsOneWidget);
      expect(find.text('skin'), findsNothing);
    },
  );

  testWidgets('unchanged launcher opens the startup skin once', (tester) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final guard = StartupNavigationGuard();
    await tester.pumpWidget(
      _app(navigatorKey: navigatorKey, observers: [guard]),
    );
    final navigator = navigatorKey.currentState!;
    navigator.pushNamedAndRemoveUntil(LauncherView.routeName, (_) => false);

    final service = _Service();
    var opens = 0;
    final opening = openStartupSkin(
      service: service,
      storage: _Storage(),
      isCurrent: () =>
          navigator.mounted && identical(navigator, navigatorKey.currentState),
      navigationGuard: guard,
      openSkin: () {
        opens++;
        SkinView.open(navigator);
      },
    );
    await tester.pump();
    expect(service.serveCalls, 1);
    expect(opens, 0);

    service.ready.complete();
    await opening;
    await tester.pumpAndSettle();

    expect(opens, 1);
    expect(find.text('skin'), findsOneWidget);
    expect(find.text('onboarding'), findsNothing);
  });

  testWidgets('removing a route below the launcher keeps startup ownership', (
    tester,
  ) async {
    final navigatorKey = GlobalKey<NavigatorState>();
    final guard = StartupNavigationGuard();
    final recorder = _RouteRecorder();
    await tester.pumpWidget(
      _app(navigatorKey: navigatorKey, observers: [guard, recorder]),
    );
    final navigator = navigatorKey.currentState!;
    navigator.pushNamedAndRemoveUntil(
      LauncherView.routeName,
      ModalRoute.withName(_onboardingRoute),
    );
    await tester.pumpAndSettle();
    expect(guard.topRoute?.settings.name, LauncherView.routeName);

    final lease = guard.lease();
    final generation = guard.generation;
    expect(guard.owns(lease), isTrue);

    final onboardingRoute = recorder.pushed.singleWhere(
      (route) => route.settings.name == _onboardingRoute,
    );
    navigator.removeRoute(onboardingRoute);
    await tester.pumpAndSettle();

    expect(guard.generation, generation);
    expect(guard.owns(lease), isTrue);
    expect(guard.topRoute?.settings.name, LauncherView.routeName);
  });

  for (final restart in [false, true]) {
    testWidgets(
      'pending startup skin is abandoned after owner ${restart ? 'restart' : 'disposal'}',
      (tester) async {
        final navigatorKey = GlobalKey<NavigatorState>();
        final guard = StartupNavigationGuard();
        BuildContext? owner;
        await tester.pumpWidget(
          _app(
            key: UniqueKey(),
            navigatorKey: navigatorKey,
            observers: [guard],
            onOwner: (context) => owner = context,
          ),
        );
        final oldOwner = owner!;
        final navigator = navigatorKey.currentState!;
        navigator.pushNamedAndRemoveUntil(LauncherView.routeName, (_) => false);
        await tester.pumpAndSettle();

        final service = _Service();
        var opens = 0;
        final opening = openStartupSkin(
          service: service,
          storage: _Storage(),
          isCurrent: () =>
              oldOwner.mounted &&
              navigator.mounted &&
              identical(navigator, navigatorKey.currentState),
          navigationGuard: guard,
          openSkin: () => opens++,
        );
        await tester.pump();
        if (restart) {
          await tester.pumpWidget(
            _app(
              key: UniqueKey(),
              navigatorKey: navigatorKey,
              observers: [guard],
              onOwner: (context) => owner = context,
            ),
          );
        } else {
          await tester.pumpWidget(const SizedBox());
        }
        expect(oldOwner.mounted, isFalse);

        service.ready.complete();
        await opening;
        await tester.pumpAndSettle();

        expect(opens, 0);
        expect(find.text('skin'), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
