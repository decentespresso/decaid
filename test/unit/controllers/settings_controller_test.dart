import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/settings/feature_flags.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/settings_service.dart';

import '../../helpers/mock_settings_service.dart';

/// Spy settings service that tracks calls to setSimulatedDevices.
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

  // Unimplemented stubs. These methods aren't exercised by simulate-device
  // tests but are required by the SettingsService interface.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isMethod) return Future.value();
    if (invocation.isGetter) return null;
    return super.noSuchMethod(invocation);
  }
}

void main() {
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

      // Without calling loadSettings, the in-memory map is empty.
      // isFeatureFlagEnabled falls back to defaultFeatureFlagValues.
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

      // Set to false first so the in-memory map has a value.
      await controller.setFeatureFlag(FeatureFlag.stepExitArbiter, false);
      spy.setFeatureFlagCallCount = 0;
      var notified = false;
      controller.addListener(() => notified = true);

      await controller.setFeatureFlag(FeatureFlag.stepExitArbiter, false);

      expect(spy.setFeatureFlagCallCount, 0);
      expect(notified, isFalse);
    });
  });
}
