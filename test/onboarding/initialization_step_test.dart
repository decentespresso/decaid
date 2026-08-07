import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/onboarding_feature/onboarding_controller.dart';
import 'package:reaprime/src/onboarding_feature/steps/initialization_step.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/services/storage/hive_store_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_de1_controller.dart';
import '../helpers/mock_settings_service.dart';

/// WebUIStorage fake: fast local init, no default skin (so the serve step is
/// skipped), and a remote-download that never completes — so the test can
/// assert the critical path does NOT await it.
class _FakeWebUIStorage extends WebUIStorage {
  bool? initDownloadRemote;
  bool downloadRescanCalled = false;

  _FakeWebUIStorage(super.settings);

  @override
  Future<void> initialize({bool downloadRemote = true}) async {
    initDownloadRemote = downloadRemote;
  }

  @override
  WebUISkin? get defaultSkin => null;

  @override
  Future<void> downloadRemoteSkinsAndRescan() {
    downloadRescanCalled = true;
    return Completer<void>().future; // never completes
  }
}

/// Plugin loader fake whose initialize() never completes — so the test can
/// assert the critical path kicks it off without awaiting.
class _FakePluginLoaderService extends PluginLoaderService {
  bool initCalled = false;

  _FakePluginLoaderService()
    : super(kvStore: HiveStoreService(defaultNamespace: 'test-plugins'));

  @override
  Future<void> initialize() {
    initCalled = true;
    return Completer<void>().future; // never completes
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
    final settings = SettingsController(MockSettingsService());
    await settings.loadSettings();

    final storage = _FakeWebUIStorage(settings);
    final plugins = _FakePluginLoaderService();
    final onboarding = _TrackingOnboardingController();
    await onboarding.initialize();

    final step = createInitializationStep(
      deviceController: DeviceController([]),
      de1Controller: MockDe1Controller(controller: DeviceController([])),
      pluginLoaderService: plugins,
      webUIStorage: storage,
      webUIService: WebUIService(),
    );

    await tester.pumpWidget(
      ShadApp(home: Scaffold(body: step.builder(onboarding))),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Critical path completed and advanced even though the deferred work
    // (plugin init + remote download) never completes.
    expect(onboarding.advanceCallCount, 1);
    // Remote download was NOT awaited on the critical path...
    expect(storage.initDownloadRemote, isFalse);
    expect(storage.downloadRescanCalled, isTrue);
    expect(plugins.initCalled, isTrue);
  });
}
