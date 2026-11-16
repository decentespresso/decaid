import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/onboarding_feature/onboarding_controller.dart';
import 'package:reaprime/src/onboarding_feature/steps/initialization_step.dart';
import 'package:reaprime/src/services/app_startup_coordinator.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

class _FakeWebUIStorage {
  bool? initDownloadRemote;
  bool downloadRescanCalled = false;

  Future<void> initialize({bool downloadRemote = true}) async {
    initDownloadRemote = downloadRemote;
  }

  Future<void> downloadRemoteSkinsAndRescan() {
    downloadRescanCalled = true;
    return Completer<void>().future;
  }
}

class _FakePluginLoaderService {
  bool initCalled = false;

  Future<void> initialize() {
    initCalled = true;
    return Completer<void>().future;
  }
}

class _TrackingOnboardingController extends OnboardingController {
  int advanceCallCount = 0;

  _TrackingOnboardingController()
    : super(
        steps: [
          OnboardingStep(
            id: 'initialization',
            shouldShow: () async => true,
            builder: (_) => const SizedBox(),
          ),
          OnboardingStep(
            id: 'next',
            shouldShow: () async => true,
            builder: (_) => const SizedBox(),
          ),
        ],
      );

  @override
  void advance() {
    advanceCallCount++;
    super.advance();
  }
}

void main() {
  testWidgets('advances without awaiting plugin init or remote skin download', (
    tester,
  ) async {
    final storage = _FakeWebUIStorage();
    final plugins = _FakePluginLoaderService();
    final onboarding = _TrackingOnboardingController();
    await onboarding.initialize();

    final coordinator = AppStartupCoordinator(
      initializeDevices: () async {},
      initializeWebUI: () => storage.initialize(downloadRemote: false),
      initializePlugins: plugins.initialize,
      refreshRemoteSkins: storage.downloadRemoteSkinsAndRescan,
      isAndroid: false,
    );
    final step = createInitializationStep(startupCoordinator: coordinator);

    await tester.pumpWidget(
      ShadApp(home: Scaffold(body: step.builder(onboarding))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(onboarding.advanceCallCount, 1);
    expect(storage.initDownloadRemote, isFalse);
    expect(storage.downloadRescanCalled, isTrue);
    expect(plugins.initCalled, isTrue);
    await tester.pumpWidget(const SizedBox());
    onboarding.dispose();
    coordinator.dispose();
  });

  testWidgets('remount reuses startup and cannot advance the next step twice', (
    tester,
  ) async {
    final ready = Completer<void>();
    var calls = 0;
    final coordinator = AppStartupCoordinator(
      initializeDevices: () {
        calls++;
        return ready.future;
      },
      initializeWebUI: () async {},
      isAndroid: false,
    );
    final onboarding = _TrackingOnboardingController();
    await onboarding.initialize();
    final step = createInitializationStep(startupCoordinator: coordinator);
    Widget view() => ShadApp(home: Scaffold(body: step.builder(onboarding)));
    await tester.pumpWidget(view());
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(view());
    ready.complete();
    await tester.pump();
    expect(calls, 1);
    expect(onboarding.advanceCallCount, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(view());
    await tester.pump();
    expect(onboarding.advanceCallCount, 1);
    await tester.pumpWidget(const SizedBox());
    onboarding.dispose();
    coordinator.dispose();
  });

  testWidgets('disposed loading UI cannot advance on late completion', (
    tester,
  ) async {
    final ready = Completer<void>();
    final coordinator = AppStartupCoordinator(
      initializeDevices: () => ready.future,
      initializeWebUI: () async {},
      isAndroid: false,
    );
    final onboarding = _TrackingOnboardingController();
    await onboarding.initialize();
    final step = createInitializationStep(startupCoordinator: coordinator);
    await tester.pumpWidget(
      ShadApp(home: Scaffold(body: step.builder(onboarding))),
    );
    await tester.pumpWidget(const SizedBox());
    ready.complete();
    await tester.pump();
    expect(onboarding.advanceCallCount, 0);
    onboarding.dispose();
    coordinator.dispose();
  });

  testWidgets(
    'failed core shows explicit retry and advances once after recovery',
    (tester) async {
      var calls = 0;
      final coordinator = AppStartupCoordinator(
        initializeDevices: () async {
          if (++calls == 1) throw StateError('adapter failed');
        },
        initializeWebUI: () async {},
        isAndroid: false,
      );
      final onboarding = _TrackingOnboardingController();
      await onboarding.initialize();
      final step = createInitializationStep(startupCoordinator: coordinator);
      await tester.pumpWidget(
        ShadApp(home: Scaffold(body: step.builder(onboarding))),
      );
      await tester.pump();
      expect(find.textContaining('adapter failed'), findsOneWidget);
      expect(onboarding.advanceCallCount, 0);
      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(onboarding.advanceCallCount, 1);
      expect(calls, 2);
      await tester.pumpWidget(const SizedBox());
      onboarding.dispose();
      coordinator.dispose();
    },
  );
}
