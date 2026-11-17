import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/launcher/launcher_view.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/scan_filter.dart';
import 'package:reaprime/src/onboarding_feature/onboarding_controller.dart';
import 'package:reaprime/src/onboarding_feature/onboarding_view.dart';
import 'package:reaprime/src/onboarding_feature/steps/initialization_step.dart';
import 'package:reaprime/src/onboarding_feature/widgets/startup_discovery_recovery.dart';
import 'package:reaprime/src/services/app_startup_coordinator.dart';
import 'package:rxdart/rxdart.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

OnboardingStep _setup(String id, {bool show = true}) => OnboardingStep(
  id: id,
  shouldShow: () async => show,
  builder: (controller) =>
      TextButton(onPressed: controller.advance, child: Text(id)),
);

Widget _view(OnboardingController controller, {Key? key}) => ShadApp(
  home: OnboardingView(key: key, controller: controller),
);

Widget _startupApp({
  required GlobalKey<NavigatorState> navigatorKey,
  required AppStartupCoordinator coordinator,
  required Widget home,
}) => ShadApp(
  navigatorKey: navigatorKey,
  home: home,
  onGenerateRoute: (settings) {
    if (settings.name != LauncherView.routeName) return null;
    return MaterialPageRoute<void>(
      settings: settings,
      builder: (_) => StartupDiscoveryRecovery(
        startupCoordinator: coordinator,
        child: const Scaffold(body: Text('launcher')),
      ),
    );
  },
);

class _MountCounter extends StatefulWidget {
  final VoidCallback onMount;
  final String label;

  const _MountCounter({required this.onMount, required this.label});

  @override
  State<_MountCounter> createState() => _MountCounterState();
}

class _MountCounterState extends State<_MountCounter> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) => Text(widget.label);
}

class _StartupDiscoveryService extends DeviceDiscoveryService {
  _StartupDiscoveryService(this.name, {this.failuresBeforeSuccess = 0});

  final String name;
  int failuresBeforeSuccess;
  int initializeCalls = 0;
  int scanCalls = 0;
  int deviceSubscriptions = 0;
  Completer<void>? retryGate;

  late final _devices = BehaviorSubject<List<Device>>.seeded(
    const <Device>[],
    onListen: () => deviceSubscriptions++,
  );

  @override
  Stream<List<Device>> get devices => _devices.stream;

  @override
  Future<void> initialize() async {
    initializeCalls++;
    final gate = retryGate;
    if (gate != null && initializeCalls > 1) await gate.future;
    if (failuresBeforeSuccess > 0) {
      failuresBeforeSuccess--;
      throw StateError('$name discovery unavailable');
    }
  }

  @override
  Future<void> scanForDevices({ScanFilter? filter}) async {
    scanCalls++;
  }

  Future<void> close() => _devices.close();
}

void main() {
  test('pending entry hook does not expose unpublished scan step', () async {
    final ready = Completer<void>();
    final controller = OnboardingController(
      steps: [_setup('permissions'), _setup('scan')],
      onStepEntered: (step) =>
          step.id == 'scan' ? ready.future : Future<void>.value(),
    );
    await controller.initialize();
    controller.advance();
    expect(controller.currentStep.id, 'permissions');
    ready.complete();
    await Future<void>.value();
    expect(controller.currentStep.id, 'scan');
    controller.dispose();
  });

  for (final permissions in [true, false]) {
    testWidgets(
      'production boundary preserves setup and consent before startup with permissions shown=$permissions',
      (tester) async {
        final ready = Completer<void>();
        var devices = 0;
        var plugins = 0;
        var scans = 0;
        final coordinator = AppStartupCoordinator(
          initializeDevices: () {
            devices++;
            return ready.future;
          },
          initializeWebUI: () async {},
          initializePlugins: () async {
            plugins++;
          },
          isAndroid: false,
        );
        final controller = createStartupOnboardingController(
          startupCoordinator: coordinator,
          steps: [
            _setup('welcome'),
            _setup('shot-upload'),
            _setup('permissions', show: permissions),
            createInitializationStep(startupCoordinator: coordinator),
            OnboardingStep(
              id: 'scan',
              shouldShow: () async => true,
              builder: (_) {
                scans++;
                return const Text('scan mounted');
              },
            ),
          ],
        );
        await controller.initialize();
        await tester.pumpWidget(_view(controller));
        await tester.pump();
        expect(devices, 0);
        expect(plugins, 0);
        await tester.tap(find.text('welcome'));
        await tester.pump();
        expect(devices, 0);
        await tester.tap(find.text('shot-upload'));
        await tester.pump();
        if (permissions) {
          expect(devices, 0);
          expect(plugins, 0);
          await tester.tap(find.text('permissions'));
          await tester.pump();
        }
        expect(devices, 1);
        expect(scans, 0);
        ready.complete();
        await tester.pump();
        await tester.pump();
        expect(scans, 1);
        expect(plugins, 1);
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        coordinator.dispose();
      },
    );
  }

  test(
    'production boundary starts core even if loading widget never mounts',
    () async {
      var calls = 0;
      final coordinator = AppStartupCoordinator(
        initializeDevices: () async {
          calls++;
        },
        initializeWebUI: () async {},
        isAndroid: false,
      );
      final controller = createStartupOnboardingController(
        startupCoordinator: coordinator,
        steps: [
          _setup('permissions'),
          createInitializationStep(startupCoordinator: coordinator),
          _setup('scan'),
        ],
      );
      await controller.initialize();
      expect(calls, 0);
      controller.advance();
      await coordinator.initializationFuture;
      expect(calls, 1);
      controller.dispose();
      coordinator.dispose();
    },
  );

  testWidgets(
    'omitted initialization cannot mount scan while pending or failed and can explicitly recover',
    (tester) async {
      final ready = Completer<void>();
      var calls = 0;
      var scans = 0;
      final plugin = Completer<void>();
      final coordinator = AppStartupCoordinator(
        initializeDevices: () {
          calls++;
          return calls == 1 ? ready.future : Future<void>.value();
        },
        initializeWebUI: () async {},
        initializePlugins: () => plugin.future,
        isAndroid: false,
      );
      final controller = createStartupOnboardingController(
        startupCoordinator: coordinator,
        steps: [
          OnboardingStep(
            id: 'scan',
            shouldShow: () async => true,
            builder: (_) =>
                _MountCounter(onMount: () => scans++, label: 'scan mounted'),
          ),
        ],
      );
      await controller.initialize();
      await tester.pumpWidget(_view(controller));
      await tester.pump();
      expect(scans, 0);
      ready.completeError(StateError('device startup failed'));
      await tester.pump();
      expect(scans, 0);
      expect(find.textContaining('device startup failed'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(scans, 1);
      expect(calls, 2);
      expect(
        coordinator.state.optionalTasks['plugins'],
        AppStartupTaskStatus.pending,
      );
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      coordinator.dispose();
      plugin.complete();
    },
  );

  testWidgets(
    'partial discovery failure advances and keeps recovery available without remounting scan',
    (tester) async {
      final flaky = _StartupDiscoveryService(
        'serial',
        failuresBeforeSuccess: 1,
      );
      final healthy = _StartupDiscoveryService('ble');
      final deviceController = DeviceController([flaky, healthy]);
      final coordinator = AppStartupCoordinator(
        deviceController: deviceController,
        initializeWebUI: () async {},
        isAndroid: false,
      );
      var scans = 0;
      final controller = createStartupOnboardingController(
        startupCoordinator: coordinator,
        steps: [
          createInitializationStep(startupCoordinator: coordinator),
          OnboardingStep(
            id: 'scan',
            shouldShow: () async => true,
            builder: (_) =>
                _MountCounter(onMount: () => scans++, label: 'scan mounted'),
          ),
        ],
      );
      await controller.initialize();
      await tester.pumpWidget(_view(controller));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(scans, 1);
      expect(find.text('scan mounted'), findsOneWidget);
      expect(flaky.initializeCalls, 1);
      expect(healthy.initializeCalls, 1);

      expect(
        find.textContaining('serial discovery unavailable'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();

      expect(flaky.initializeCalls, 2);
      expect(healthy.initializeCalls, 1);
      expect(scans, 1);
      expect(find.text('Retry'), findsNothing);
      expect(flaky.scanCalls, 0);
      expect(healthy.scanCalls, 0);

      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      coordinator.dispose();
      deviceController.dispose();
      await flaky.close();
      await healthy.close();
    },
  );

  testWidgets(
    'partial discovery failure survives scan completion into the launcher and retry clears only the device notice',
    (tester) async {
      final flaky = _StartupDiscoveryService(
        'serial',
        failuresBeforeSuccess: 1,
      );
      final healthy = _StartupDiscoveryService('ble');
      final deviceController = DeviceController([flaky, healthy]);
      final coordinator = AppStartupCoordinator(
        deviceController: deviceController,
        initializeWebUI: () async =>
            throw StateError('webui skin storage unavailable'),
        initializePlugins: () async =>
            throw StateError('plugin registry offline'),
        refreshRemoteSkins: () async =>
            throw StateError('remote skins unreachable'),
        isAndroid: false,
      );
      var scans = 0;
      final controller = createStartupOnboardingController(
        startupCoordinator: coordinator,
        steps: [
          createInitializationStep(startupCoordinator: coordinator),
          OnboardingStep(
            id: 'scan',
            shouldShow: () async => true,
            builder: (_) =>
                _MountCounter(onMount: () => scans++, label: 'scan mounted'),
          ),
        ],
      );
      await controller.initialize();
      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        _startupApp(
          navigatorKey: navigatorKey,
          coordinator: coordinator,
          home: OnboardingView(controller: controller),
        ),
      );
      await tester.pumpAndSettle();

      expect(scans, 1);
      expect(find.text('scan mounted'), findsOneWidget);
      expect(flaky.initializeCalls, 1);
      expect(healthy.initializeCalls, 1);
      expect(flaky.deviceSubscriptions, 0);
      expect(healthy.deviceSubscriptions, 1);

      navigatorKey.currentState!.pushNamedAndRemoveUntil(
        LauncherView.routeName,
        (_) => false,
      );
      await tester.pumpAndSettle();

      expect(find.text('launcher'), findsOneWidget);
      expect(find.text('scan mounted'), findsNothing);
      expect(find.text('Some device services did not start.'), findsOneWidget);
      expect(
        find.textContaining('serial discovery unavailable'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Retry'))
            .onPressed,
        isNotNull,
      );
      expect(flaky.initializeCalls, 1);
      expect(healthy.initializeCalls, 1);
      expect(healthy.deviceSubscriptions, 1);
      expect(flaky.scanCalls, 0);
      expect(healthy.scanCalls, 0);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(flaky.initializeCalls, 2);
      expect(flaky.deviceSubscriptions, 1);
      expect(healthy.initializeCalls, 1);
      expect(healthy.deviceSubscriptions, 1);
      expect(flaky.scanCalls, 0);
      expect(healthy.scanCalls, 0);
      expect(scans, 1);
      expect(find.text('launcher'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(find.text('Some device services did not start.'), findsNothing);
      expect(find.textContaining('serial discovery unavailable'), findsNothing);
      expect(coordinator.state.discoveryRecoveryRequired, isFalse);
      expect(
        coordinator.state.reasons.where(
          (reason) => reason.contains('Device service initialization failed'),
        ),
        isEmpty,
      );
      for (final retained in [
        'webui skin storage unavailable',
        'plugin registry offline',
        'remote skins unreachable',
      ]) {
        expect(
          coordinator.state.reasons.where(
            (reason) => reason.contains(retained),
          ),
          isNotEmpty,
          reason: '$retained should stay as an unrelated diagnostic',
        );
      }

      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      coordinator.dispose();
      deviceController.dispose();
      await flaky.close();
      await healthy.close();
    },
  );

  testWidgets(
    'optional plugin, remote skin and local webui failures add no discovery retry banner',
    (tester) async {
      final healthy = _StartupDiscoveryService('ble');
      final deviceController = DeviceController([healthy]);
      final coordinator = AppStartupCoordinator(
        deviceController: deviceController,
        initializeWebUI: () async => throw StateError('webui skin offline'),
        initializePlugins: () async =>
            throw StateError('plugin registry offline'),
        refreshRemoteSkins: () async =>
            throw StateError('remote skins unreachable'),
        isAndroid: false,
      );
      await coordinator.ensureInitialized();
      expect(coordinator.state.discoveryRecoveryRequired, isFalse);

      final navigatorKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        _startupApp(
          navigatorKey: navigatorKey,
          coordinator: coordinator,
          home: const Scaffold(body: Text('onboarding')),
        ),
      );
      navigatorKey.currentState!.pushNamedAndRemoveUntil(
        LauncherView.routeName,
        (_) => false,
      );
      await tester.pumpAndSettle();

      expect(find.text('launcher'), findsOneWidget);
      expect(find.text('Some device services did not start.'), findsNothing);
      expect(find.text('Retry'), findsNothing);
      expect(coordinator.state.discoveryRecovery, isNull);
      for (final diagnostic in [
        'webui skin offline',
        'plugin registry offline',
        'remote skins unreachable',
      ]) {
        expect(
          coordinator.state.reasons.where(
            (reason) => reason.contains(diagnostic),
          ),
          isNotEmpty,
          reason: '$diagnostic should stay observable',
        );
      }
      expect(healthy.initializeCalls, 1);
      expect(healthy.deviceSubscriptions, 1);
      expect(healthy.scanCalls, 0);

      await tester.pumpWidget(const SizedBox());
      coordinator.dispose();
      deviceController.dispose();
      await healthy.close();
    },
  );

  testWidgets(
    'all relevant discovery failures block scan and keep explicit retry',
    (tester) async {
      final broken = _StartupDiscoveryService(
        'serial',
        failuresBeforeSuccess: 1,
      );
      final deviceController = DeviceController([broken]);
      final coordinator = AppStartupCoordinator(
        deviceController: deviceController,
        initializeWebUI: () async {},
        isAndroid: false,
      );
      var scans = 0;
      final controller = createStartupOnboardingController(
        startupCoordinator: coordinator,
        steps: [
          createInitializationStep(startupCoordinator: coordinator),
          OnboardingStep(
            id: 'scan',
            shouldShow: () async => true,
            builder: (_) =>
                _MountCounter(onMount: () => scans++, label: 'scan mounted'),
          ),
        ],
      );
      await controller.initialize();
      await tester.pumpWidget(_view(controller));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(scans, 0);
      expect(
        find.textContaining('serial discovery unavailable'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();

      expect(broken.initializeCalls, 2);
      expect(scans, 1);
      expect(find.text('scan mounted'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      coordinator.dispose();
      deviceController.dispose();
      await broken.close();
    },
  );

  testWidgets('recovery notice coalesces while a retry is pending', (
    tester,
  ) async {
    final flaky = _StartupDiscoveryService('serial', failuresBeforeSuccess: 1);
    final retryGate = Completer<void>();
    flaky.retryGate = retryGate;
    final healthy = _StartupDiscoveryService('ble');
    final deviceController = DeviceController([flaky, healthy]);
    final coordinator = AppStartupCoordinator(
      deviceController: deviceController,
      initializeWebUI: () async {},
      isAndroid: false,
    );
    var scans = 0;
    final controller = createStartupOnboardingController(
      startupCoordinator: coordinator,
      steps: [
        createInitializationStep(startupCoordinator: coordinator),
        OnboardingStep(
          id: 'scan',
          shouldShow: () async => true,
          builder: (_) =>
              _MountCounter(onMount: () => scans++, label: 'scan mounted'),
        ),
      ],
    );
    await controller.initialize();
    await tester.pumpWidget(_view(controller));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(scans, 1);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Retry'))
          .onPressed,
      isNotNull,
    );

    await tester.tap(find.text('Retry'));
    await tester.pump();

    expect(flaky.initializeCalls, 2);
    expect(find.text('scan mounted'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Retry'))
          .onPressed,
      isNull,
    );

    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(flaky.initializeCalls, 2);

    retryGate.complete();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(flaky.initializeCalls, 2);
    expect(scans, 1);
    expect(find.text('Retry'), findsNothing);
    expect(flaky.scanCalls, 0);
    expect(healthy.scanCalls, 0);

    await tester.pumpWidget(const SizedBox());
    controller.dispose();
    coordinator.dispose();
    deviceController.dispose();
    await flaky.close();
    await healthy.close();
  });

  testWidgets(
    'keyed onboarding relaunch shares owner without repeating core or optional work',
    (tester) async {
      var devices = 0;
      var webUI = 0;
      var plugins = 0;
      var foreground = 0;
      var scans = 0;
      final coordinator = AppStartupCoordinator(
        initializeDevices: () async {
          devices++;
        },
        initializeWebUI: () async {
          webUI++;
        },
        initializePlugins: () async {
          plugins++;
        },
        startForeground: () async {
          foreground++;
          return true;
        },
        isAndroid: true,
      );
      OnboardingController flow() => createStartupOnboardingController(
        startupCoordinator: coordinator,
        steps: [
          createInitializationStep(startupCoordinator: coordinator),
          OnboardingStep(
            id: 'scan',
            shouldShow: () async => true,
            builder: (_) =>
                _MountCounter(onMount: () => scans++, label: 'scan mounted'),
          ),
        ],
      );
      final first = flow();
      await first.initialize();
      await tester.pumpWidget(_view(first, key: UniqueKey()));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      final second = flow();
      await second.initialize();
      await tester.pumpWidget(_view(second, key: UniqueKey()));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(devices, 1);
      expect(webUI, 1);
      expect(plugins, 1);
      expect(foreground, 1);
      expect(scans, 2);
      await tester.pumpWidget(const SizedBox());
      first.dispose();
      second.dispose();
      coordinator.dispose();
    },
  );
}
