import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/onboarding_feature/onboarding_controller.dart';
import 'package:reaprime/src/onboarding_feature/onboarding_view.dart';
import 'package:reaprime/src/onboarding_feature/steps/initialization_step.dart';
import 'package:reaprime/src/services/app_startup_coordinator.dart';
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
            builder: (_) {
              scans++;
              return const Text('scan mounted');
            },
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
