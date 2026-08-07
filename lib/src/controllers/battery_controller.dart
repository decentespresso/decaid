import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/charging_logic.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:rxdart/rxdart.dart';

class BatteryController {
  final De1Controller _de1Controller;
  final DeviceController _deviceController;
  final SettingsController _settingsController;
  final Battery _battery = Battery();
  final Logger _log = Logger("Battery");

  late Timer _checkTimer;
  bool _wasCharging = false;

  bool? _lastAppliedCharge;
  DateTime? _lastChargeWrite;

  static const Duration _dischargeReassertInterval = Duration(minutes: 5);

  final BehaviorSubject<ChargingState> _stateSubject =
      BehaviorSubject<ChargingState>();

  Stream<ChargingState> get chargingState => _stateSubject.stream;
  ChargingState? get currentChargingState => _stateSubject.valueOrNull;

  BatteryController({
    required De1Controller de1Controller,
    required DeviceController deviceController,
    required SettingsController settingsController,
  }) : _de1Controller = de1Controller,
       _deviceController = deviceController,
       _settingsController = settingsController {
    _checkTimer = Timer.periodic(const Duration(seconds: 60), (_) => _tick());
    _tick();
  }

  Future<void> _tick() async {
    try {
      if (_deviceController.isScanning) {
        _log.fine('Skipping USB charger mode update during BLE scan');
        return;
      }
      final de1 = _de1Controller.connectedDe1OrNull;
      if (de1 == null) {
        _log.fine('No machine connected, skipping USB charger mode update');
        _lastAppliedCharge = null;
        return;
      }

      final batteryPercent = await _battery.batteryLevel;
      final now = DateTime.now();

      final chargingMode = _settingsController.chargingMode;
      final nightModeEnabled = _settingsController.nightModeEnabled;

      NightModeConfig? nightConfig;
      if (nightModeEnabled) {
        nightConfig = NightModeConfig(
          sleepTimeMinutes: _settingsController.nightModeSleepTime,
          morningTimeMinutes: _settingsController.nightModeMorningTime,
        );
      }

      final decision = decide(
        batteryPercent: batteryPercent,
        currentTime: now,
        chargingMode: chargingMode,
        nightModeConfig: nightConfig,
        wasCharging: _wasCharging,
      );

      _wasCharging = decision.shouldCharge;

      _log.fine(
        'Battery: $batteryPercent%, '
        'phase: ${decision.nightPhase.name}, '
        'charge: ${decision.shouldCharge}, '
        'reason: ${decision.reason}',
      );

      if (shouldWriteChargerMode(
        shouldCharge: decision.shouldCharge,
        lastApplied: _lastAppliedCharge,
        now: now,
        lastWrite: _lastChargeWrite,
        reassertInterval: _dischargeReassertInterval,
      )) {
        try {
          await de1.setUsbChargerMode(decision.shouldCharge);
          _lastAppliedCharge = decision.shouldCharge;
          _lastChargeWrite = now;
        } catch (e) {
          _log.warning('Failed to set USB charger mode', e);
        }
      }

      _stateSubject.add(
        ChargingState(
          mode: chargingMode,
          nightModeEnabled: nightModeEnabled,
          currentPhase: decision.nightPhase,
          batteryPercent: batteryPercent,
          usbChargerOn: decision.shouldCharge,
          isEmergency: decision.reason == 'emergency',
        ),
      );
    } catch (e, st) {
      _log.warning('Battery check failed', e, st);
    }
  }

  void dispose() {
    _checkTimer.cancel();
    _stateSubject.close();
  }
}
