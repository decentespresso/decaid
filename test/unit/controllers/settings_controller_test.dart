import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/main.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/settings/feature_flags.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/settings_service.dart';

import '../../helpers/mock_settings_service.dart';

class _SpySettingsService implements SettingsService {
  int setSimulatedDevicesCallCount = 0;
  int setEnableSimulatedWebViewsCallCount = 0;
  int setShowSkinExitInstructionsCallCount = 0;
  int setUpdateChannelCallCount = 0;
  int setFeatureFlagCallCount = 0;
  Set<SimulatedDevicesTypes> _simulatedDevices = {};
  bool _enableSimulatedWebViews = false;
  bool _showSkinExitInstructions = true;
  UpdateChannel _updateChannel = UpdateChannel.stable;
  final Map<String, bool?> _featureFlags = {};
  String? _preferredMachineId;
  String? _preferredScaleId;
  String? _preferredGrinderDeviceId;

  @override
  Future<Set<SimulatedDevicesTypes>> simulateDevices() async =>
      _simulatedDevices;
  @override
  Future<void> setSimulatedDevices(Set<SimulatedDevicesTypes> value) async {
    setSimulatedDevicesCallCount++;
    _simulatedDevices = value;
  }

  @override
  Future<bool> enableSimulatedWebViews() async => _enableSimulatedWebViews;
  @override
  Future<void> setEnableSimulatedWebViews(bool value) async {
    setEnableSimulatedWebViewsCallCount++;
    _enableSimulatedWebViews = value;
  }

  @override
  Future<bool> showSkinExitInstructions() async => _showSkinExitInstructions;
  @override
  Future<void> setShowSkinExitInstructions(bool value) async {
    setShowSkinExitInstructionsCallCount++;
    _showSkinExitInstructions = value;
  }

  @override
  Future<UpdateChannel> updateChannel() async => _updateChannel;
  @override
  Future<void> setUpdateChannel(UpdateChannel channel) async {
    setUpdateChannelCallCount++;
    _updateChannel = channel;
  }

  @override
  Future<bool?> featureFlag(FeatureFlag flag) async => _featureFlags[flag.name];
  @override
  Future<void> setFeatureFlag(FeatureFlag flag, bool value) async {
    setFeatureFlagCallCount++;
    _featureFlags[flag.name] = value;
  }

  @override
  Future<String?> preferredMachineId() async => _preferredMachineId;
  @override
  Future<void> setPreferredMachineId(String? machineId) async =>
      _preferredMachineId = machineId;
  @override
  Future<String?> preferredScaleId() async => _preferredScaleId;
  @override
  Future<void> setPreferredScaleId(String? scaleId) async =>
      _preferredScaleId = scaleId;
  @override
  Future<String?> preferredGrinderDeviceId() async => _preferredGrinderDeviceId;
  @override
  Future<void> setPreferredGrinderDeviceId(String? deviceId) async =>
      _preferredGrinderDeviceId = deviceId;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isMethod) return Future.value();
    if (invocation.isGetter) return null;
    return super.noSuchMethod(invocation);
  }
}

void main() {
  test(
    'direct preference writers cannot persist a USB session identity',
    () async {
      final store = MockSettingsService();
      final controller = SettingsController(store);
      await controller.setPreferredMachineId('usb-2e8a-a-KNOWN');
      for (final id in [
        'usb-2e8a-a-unknown',
        'usb-2e8a-a-unknown-7',
        'usb-session-7',
      ]) {
        await controller.setPreferredMachineId(id);
        expect(controller.preferredMachineId, 'usb-2e8a-a-KNOWN');
        expect(await store.preferredMachineId(), 'usb-2e8a-a-KNOWN');
      }
      await controller.setPreferredMachineId(null);
      expect(await store.preferredMachineId(), isNull);
      controller.dispose();
    },
  );

  test('scale preference ignores ephemeral USB identities', () async {
    final store = MockSettingsService();
    final controller = SettingsController(store);
    await controller.setPreferredScaleId('usb-2e8a-a-KNOWN');

    await controller.setPreferredScaleId('usb-2e8a-a-unknown-7');

    expect(controller.preferredScaleId, 'usb-2e8a-a-KNOWN');
    expect(await store.preferredScaleId(), 'usb-2e8a-a-KNOWN');
    controller.dispose();
  });

  test('loads and persists preferred grinder device ID', () async {
    final service = MockSettingsService();
    await service.setPreferredGrinderDeviceId('grinder-one');
    final controller = SettingsController(service);

    await controller.loadSettings();
    expect(controller.preferredGrinderDeviceId, 'grinder-one');

    await controller.setPreferredGrinderDeviceId('grinder-two');
    expect(controller.preferredGrinderDeviceId, 'grinder-two');
    expect(await service.preferredGrinderDeviceId(), 'grinder-two');
  });

  group('SettingsController.enableSimulatedDevicesForSession', () {
    test('sets simulatedDevices in memory', () {
      final spy = _SpySettingsService();
      final controller = SettingsController(spy);

      controller.enableSimulatedDevicesForSession({
        SimulatedDevicesTypes.machine,
        SimulatedDevicesTypes.scale,
      });

      expect(controller.simulatedDevices, {
        SimulatedDevicesTypes.machine,
        SimulatedDevicesTypes.scale,
      });
    });

    test('notifies listeners', () {
      final spy = _SpySettingsService();
      final controller = SettingsController(spy);
      var notified = false;
      controller.addListener(() => notified = true);

      controller.enableSimulatedDevicesForSession({
        SimulatedDevicesTypes.machine,
      });

      expect(notified, isTrue);
    });

    test('does NOT call setSimulatedDevices on the service (no persist)', () {
      final spy = _SpySettingsService();
      final controller = SettingsController(spy);

      controller.enableSimulatedDevicesForSession({
        SimulatedDevicesTypes.scale,
      });

      expect(spy.setSimulatedDevicesCallCount, 0);
    });

    test('overwrites previous in-memory value', () {
      final spy = _SpySettingsService();
      final controller = SettingsController(spy);

      controller.enableSimulatedDevicesForSession({
        SimulatedDevicesTypes.machine,
      });
      controller.enableSimulatedDevicesForSession({
        SimulatedDevicesTypes.scale,
      });

      expect(controller.simulatedDevices, {SimulatedDevicesTypes.scale});
    });

    test('can clear simulated devices', () {
      final spy = _SpySettingsService();
      final controller = SettingsController(spy);

      controller.enableSimulatedDevicesForSession({
        SimulatedDevicesTypes.machine,
        SimulatedDevicesTypes.scale,
      });
      controller.enableSimulatedDevicesForSession({});

      expect(controller.simulatedDevices, isEmpty);
    });

    test('sets preferred machine ID to MockDe1 when machine enabled', () {
      final spy = _SpySettingsService();
      final controller = SettingsController(spy);

      controller.enableSimulatedDevicesForSession({
        SimulatedDevicesTypes.machine,
      });

      expect(controller.preferredMachineId, 'MockDe1');
    });

    test('sets preferred scale ID to MockScale when scale enabled', () {
      final spy = _SpySettingsService();
      final controller = SettingsController(spy);

      controller.enableSimulatedDevicesForSession({
        SimulatedDevicesTypes.scale,
      });

      expect(controller.preferredScaleId, 'MockScale');
    });

    test('does NOT set preferred machine ID when only scale enabled', () {
      final spy = _SpySettingsService();
      final controller = SettingsController(spy);

      controller.enableSimulatedDevicesForSession({
        SimulatedDevicesTypes.scale,
      });

      expect(controller.preferredMachineId, isNull);
    });

    test('clears preferred IDs when called with empty set', () {
      final spy = _SpySettingsService();
      final controller = SettingsController(spy);

      controller.enableSimulatedDevicesForSession({
        SimulatedDevicesTypes.machine,
        SimulatedDevicesTypes.scale,
      });
      expect(controller.preferredMachineId, 'MockDe1');
      expect(controller.preferredScaleId, 'MockScale');

      controller.enableSimulatedDevicesForSession({});

      expect(controller.preferredMachineId, isNull);
      expect(controller.preferredScaleId, isNull);
    });

    test('clears preferred scale ID when only machine re-enabled', () {
      final spy = _SpySettingsService();
      final controller = SettingsController(spy);

      controller.enableSimulatedDevicesForSession({
        SimulatedDevicesTypes.machine,
        SimulatedDevicesTypes.scale,
      });
      controller.enableSimulatedDevicesForSession({
        SimulatedDevicesTypes.machine,
      });

      expect(controller.preferredMachineId, 'MockDe1');
      expect(controller.preferredScaleId, isNull);
    });
  });

  group('SettingsController.setEnableSimulatedWebViews', () {
    test('persists and updates the in-memory value', () async {
      final spy = _SpySettingsService();
      final controller = SettingsController(spy);

      await controller.setEnableSimulatedWebViews(true);

      expect(controller.enableSimulatedWebViews, isTrue);
      expect(spy.setEnableSimulatedWebViewsCallCount, 1);
    });

    test('notifies listeners on change', () async {
      final spy = _SpySettingsService();
      final controller = SettingsController(spy);
      var notified = false;
      controller.addListener(() => notified = true);

      await controller.setEnableSimulatedWebViews(true);

      expect(notified, isTrue);
    });

    test('is a no-op when the value is unchanged', () async {
      final spy = _SpySettingsService();
      final controller = SettingsController(spy);
      var notified = false;
      controller.addListener(() => notified = true);

      await controller.setEnableSimulatedWebViews(false);

      expect(spy.setEnableSimulatedWebViewsCallCount, 0);
      expect(notified, isFalse);
    });
  });

  group('SettingsController.setShowSkinExitInstructions', () {
    test('persists and updates the in-memory value', () async {
      final spy = _SpySettingsService();
      final controller = SettingsController(spy);

      await controller.setShowSkinExitInstructions(false);

      expect(controller.showSkinExitInstructions, isFalse);
      expect(spy.setShowSkinExitInstructionsCallCount, 1);
    });

    test('notifies listeners on change', () async {
      final spy = _SpySettingsService();
      final controller = SettingsController(spy);
      var notified = false;
      controller.addListener(() => notified = true);

      await controller.setShowSkinExitInstructions(false);

      expect(notified, isTrue);
    });

    test('is a no-op when the value is unchanged', () async {
      final spy = _SpySettingsService();
      final controller = SettingsController(spy);
      var notified = false;
      controller.addListener(() => notified = true);

      await controller.setShowSkinExitInstructions(true);

      expect(spy.setShowSkinExitInstructionsCallCount, 0);
      expect(notified, isFalse);
    });
  });

  group('SettingsController.setUpdateChannel', () {
    test('loads the persisted channel', () async {
      final settings = MockSettingsService();
      await settings.setUpdateChannel(UpdateChannel.beta);
      final controller = SettingsController(settings);

      await controller.loadSettings();

      expect(controller.updateChannel, UpdateChannel.beta);
    });

    test('persists, updates, and notifies on change', () async {
      final spy = _SpySettingsService();
      final controller = SettingsController(spy);
      var notified = false;
      controller.addListener(() => notified = true);

      await controller.setUpdateChannel(UpdateChannel.beta);

      expect(controller.updateChannel, UpdateChannel.beta);
      expect(spy.setUpdateChannelCallCount, 1);
      expect(notified, isTrue);
    });

    test('is a no-op when unchanged', () async {
      final spy = _SpySettingsService();
      final controller = SettingsController(spy);
      var notified = false;
      controller.addListener(() => notified = true);

      await controller.setUpdateChannel(UpdateChannel.stable);

      expect(spy.setUpdateChannelCallCount, 0);
      expect(notified, isFalse);
    });
  });

  group('SettingsController.setFeatureFlag', () {
    test('returns default value when not yet stored', () {
      final spy = _SpySettingsService();
      final controller = SettingsController(spy);

      expect(
        controller.isFeatureFlagEnabled(FeatureFlag.stepExitArbiter),
        isTrue,
      );
    });

    test('persists and updates the in-memory value', () async {
      final spy = _SpySettingsService();
      final controller = SettingsController(spy);

      await controller.setFeatureFlag(FeatureFlag.stepExitArbiter, false);

      expect(
        controller.isFeatureFlagEnabled(FeatureFlag.stepExitArbiter),
        isFalse,
      );
      expect(spy.setFeatureFlagCallCount, 1);
    });

    test('notifies listeners on change', () async {
      final spy = _SpySettingsService();
      final controller = SettingsController(spy);
      var notified = false;
      controller.addListener(() => notified = true);

      await controller.setFeatureFlag(FeatureFlag.stepExitArbiter, false);

      expect(notified, isTrue);
    });

    test('is a no-op when the value is unchanged', () async {
      final spy = _SpySettingsService();
      final controller = SettingsController(spy);

      await controller.setFeatureFlag(FeatureFlag.stepExitArbiter, false);
      spy.setFeatureFlagCallCount = 0;
      var notified = false;
      controller.addListener(() => notified = true);

      await controller.setFeatureFlag(FeatureFlag.stepExitArbiter, false);

      expect(spy.setFeatureFlagCallCount, 0);
      expect(notified, isFalse);
    });
  });

  group('shot upload startup preparation', () {
    Future<SettingsController> settingsWithSeen(bool seen) async {
      final service = MockSettingsService();
      await service.setShotUploadStepSeen(seen);
      final settings = SettingsController(service);
      await settings.loadSettings();
      return settings;
    }

    setUp(() {
      SharedPreferences.resetStatic();
    });

    test('only true legacy AutoUpload migrates an unseen user', () async {
      for (final raw in [
        null,
        '{bad',
        '[]',
        'null',
        '"true"',
        'false',
        '{"AutoUpload":1}',
        '{"AutoUpload":"true"}',
        '{"AutoUpload":false}',
      ]) {
        SharedPreferences.setMockInitialValues(
          raw == null
              ? <String, Object>{}
              : {'plugin.settings.shot-upload.reaplugin': raw},
        );
        final settings = await settingsWithSeen(false);
        await prepareShotUploadStartup(
          settings,
          forceOnboarding: false,
          bypassOnboarding: false,
        );
        expect(settings.shotUploadStepSeen, isFalse, reason: '$raw');
      }

      SharedPreferences.setMockInitialValues({
        'plugin.settings.shot-upload.reaplugin':
            '{"AutoUpload":true,"autoload":false}',
      });
      final settings = await settingsWithSeen(false);
      await prepareShotUploadStartup(
        settings,
        forceOnboarding: false,
        bypassOnboarding: false,
      );
      expect(settings.shotUploadStepSeen, isTrue);
    });

    test(
      'seen state survives restart and force/bypass are deterministic',
      () async {
        SharedPreferences.setMockInitialValues({});
        final service = MockSettingsService();
        await service.setShotUploadStepSeen(false);
        final first = SettingsController(service);
        await first.loadSettings();
        await prepareShotUploadStartup(
          first,
          forceOnboarding: false,
          bypassOnboarding: true,
        );
        final second = SettingsController(service);
        await second.loadSettings();
        expect(second.shotUploadStepSeen, isTrue);

        await prepareShotUploadStartup(
          second,
          forceOnboarding: true,
          bypassOnboarding: false,
        );
        expect(second.shotUploadStepSeen, isFalse);
        await prepareShotUploadStartup(
          second,
          forceOnboarding: true,
          bypassOnboarding: true,
        );
        expect(second.shotUploadStepSeen, isFalse);
      },
    );

    test(
      'migration does not alter an existing answer or plugin flags',
      () async {
        SharedPreferences.setMockInitialValues({
          'plugin.settings.shot-upload.reaplugin':
              '{"AutoUpload":true,"autoload":false}',
        });
        final service = MockSettingsService();
        await service.setShotUploadStepSeen(true);
        await service.setShotUploadOptIn(true);
        final settings = SettingsController(service);
        await settings.loadSettings();
        await prepareShotUploadStartup(
          settings,
          forceOnboarding: false,
          bypassOnboarding: false,
        );
        expect(settings.shotUploadStepSeen, isTrue);
        expect(settings.shotUploadOptIn, isTrue);
        expect(await persistedShotUploadAutoUploadEnabled(), isTrue);
      },
    );
  });

  group('shot upload onboarding preferences', () {
    test('loads both keys from the settings service', () async {
      final service = MockSettingsService();
      await service.setShotUploadStepSeen(true);
      await service.setShotUploadOptIn(true);
      final controller = SettingsController(service);

      await controller.loadSettings();

      expect(controller.shotUploadStepSeen, isTrue);
      expect(controller.shotUploadOptIn, isTrue);
    });

    test('persists the answer and the seen flag', () async {
      final spy = _ShotUploadSpy();
      final controller = SettingsController(spy);
      await controller.loadSettings();
      await controller.setShotUploadStepSeen(false);
      spy.calls.clear();

      await controller.setShotUploadOptIn(true);
      await controller.setShotUploadStepSeen(true);

      expect(spy.calls, ['optIn:true', 'seen:true']);
      expect(controller.shotUploadOptIn, isTrue);
      expect(controller.shotUploadStepSeen, isTrue);
    });

    test('persists a pending decision and completion together', () async {
      final spy = _ShotUploadSpy();
      final controller = SettingsController(spy);
      await controller.loadSettings();

      await controller.setShotUploadDecision(false);

      expect(spy.calls, ['decision:false']);
      expect(controller.shotUploadStepSeen, isTrue);
      expect(controller.shotUploadPendingDecision, isFalse);
    });

    test(
      'a consumed decision is not replayed by a reconstructed controller',
      () async {
        final spy = _ShotUploadSpy();
        final first = SettingsController(spy);
        await first.loadSettings();
        await first.setShotUploadDecision(true);
        await first.clearShotUploadPendingDecision();

        final second = SettingsController(spy);
        await second.loadSettings();

        expect(second.shotUploadStepSeen, isTrue);
        expect(second.shotUploadPendingDecision, isNull);
      },
    );

    test('a failed persist leaves the in-memory value retryable', () async {
      final spy = _ShotUploadSpy();
      final controller = SettingsController(spy);
      await controller.loadSettings();
      spy.failWrites = true;

      await expectLater(
        controller.setShotUploadOptIn(true),
        throwsA(isA<Exception>()),
      );
      expect(controller.shotUploadOptIn, isFalse);

      spy.failWrites = false;
      await controller.setShotUploadOptIn(true);

      expect(controller.shotUploadOptIn, isTrue);
      expect(spy.calls, ['optIn:true', 'optIn:true']);
    });
  });
}

class _ShotUploadSpy extends MockSettingsService {
  final List<String> calls = [];
  bool failWrites = false;

  @override
  Future<void> setShotUploadDecision(bool value) async {
    calls.add('decision:$value');
    if (failWrites) throw Exception('write failed');
    return super.setShotUploadDecision(value);
  }

  @override
  Future<void> clearShotUploadPendingDecision() async {
    calls.add('clear');
    if (failWrites) throw Exception('write failed');
    return super.clearShotUploadPendingDecision();
  }

  @override
  Future<void> setShotUploadOptIn(bool value) async {
    calls.add('optIn:$value');
    if (failWrites) throw Exception('write failed');
    return super.setShotUploadOptIn(value);
  }

  @override
  Future<void> setShotUploadStepSeen(bool value) async {
    calls.add('seen:$value');
    if (failWrites) throw Exception('write failed');
    return super.setShotUploadStepSeen(value);
  }
}
