import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/auxiliary_scale_registry.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/models/device/device_scanner.dart';
import 'package:reaprime/src/models/device/machine.dart';
import 'package:reaprime/src/models/device/transport/data_transport.dart';
import 'package:reaprime/src/settings/scale_power_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';

import '../helpers/mock_de1_controller.dart';
import '../helpers/mock_device_discovery_service.dart';
import '../helpers/mock_device_scanner.dart';
import '../helpers/mock_scale_controller.dart';
import '../helpers/mock_settings_service.dart';
import '../helpers/test_de1.dart';
import '../helpers/test_usb_hds.dart';

class _Harness {
  final FakeAsync time;
  final scanner = MockDeviceScanner();
  final scales = MockScaleController();
  final store = MockSettingsService();
  final machine = TestDe1();
  final devices = <TestUsbHds>[];
  late final settings = SettingsController(store);
  late final de1 = MockDe1Controller(
    controller: DeviceController([MockDeviceDiscoveryService()]),
  );
  late final manager = ConnectionManager(
    deviceScanner: scanner,
    de1Controller: de1,
    scaleController: scales,
    settingsController: settings,
  );

  _Harness(this.time) {
    settings.loadSettings();
    time.flushMicrotasks();
    settings.setPreferredScaleId('usb-hds:any');
    time.flushMicrotasks();
    manager.snapshotStalenessTimeout = const Duration(minutes: 10);
    de1.de1Subject.add(machine);
    time.flushMicrotasks();
  }

  TestUsbHds scale([String id = 'usb-1a86-7522-unknown-1004']) {
    final scale = TestUsbHds(deviceId: id);
    devices.add(scale);
    return scale;
  }

  void elapse(Duration duration) {
    time.elapse(duration);
    time.flushMicrotasks();
  }

  void dispose() {
    manager.dispose();
    settings.dispose();
    scales.dispose();
    scales.connectionStateSubject.close();
    de1.de1Subject.close();
    machine.dispose();
    scanner.dispose();
    for (final device in devices) {
      device.dispose();
    }
    time.flushMicrotasks();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void run(void Function(_Harness) body) {
    fakeAsync((time) {
      final harness = _Harness(time);
      try {
        body(harness);
      } finally {
        harness.dispose();
      }
    });
  }

  test(
    'connecting serial-less HDS persists a family preference across reload',
    () {
      run((h) {
        h.settings.setPreferredScaleId(null);
        h.time.flushMicrotasks();
        h.manager.connectScale(h.scale());
        h.time.flushMicrotasks();
        expect(h.settings.preferredScaleId, 'usb-hds:any');
        final reloaded = SettingsController(h.store);
        reloaded.loadSettings();
        h.time.flushMicrotasks();
        expect(reloaded.preferredScaleId, 'usb-hds:any');
        reloaded.dispose();
      });
    },
  );

  for (final scaleOnly in [false, true]) {
    test(
      'family scan waits for late matches before selection (scaleOnly=$scaleOnly)',
      () {
        run((h) {
          h.scanner.scanCompleter = Completer<void>();
          h.manager.connect(scaleOnly: scaleOnly);
          h.elapse(Duration.zero);
          h.scanner.addDevice(h.scale());
          h.elapse(Duration.zero);
          expect(h.scales.connectCalls, isEmpty);
          expect(h.scanner.stopScanCallCount, 0);
          h.scanner.addDevice(h.scale('usb-1a86-7522-unknown-1005'));
          h.scanner.completeScan();
          h.elapse(Duration.zero);
          expect(h.scales.connectCalls, isEmpty);
          expect(
            h.manager.currentStatus.pendingAmbiguity,
            AmbiguityReason.scalePicker,
          );
          expect(h.manager.scaleReconnectScheduled, isFalse);
          h.manager.selectScale(h.devices.last);
          h.elapse(Duration.zero);
          expect(h.scales.lastConnectedScale, same(h.devices.last));
          expect(h.settings.preferredScaleId, 'usb-hds:any');
        });
      },
    );
  }

  for (final powerMode in [
    ScalePowerMode.disconnect,
    ScalePowerMode.displayOff,
  ]) {
    test(
      'wake family recovery retries USB scanning after reattachment ($powerMode)',
      () {
        run((h) {
          h.scanner.supportsWatch = true;
          h.settings.setScalePowerMode(powerMode);
          h.time.flushMicrotasks();
          h.machine.emitStateAndSubstate(
            MachineState.sleeping,
            MachineSubstate.idle,
          );
          h.time.flushMicrotasks();
          expect(h.manager.supportsBackgroundScaleWatch, isFalse);
          h.machine.emitStateAndSubstate(
            MachineState.idle,
            MachineSubstate.idle,
          );
          h.time.flushMicrotasks();
          h.elapse(const Duration(milliseconds: 2999));
          expect(h.scanner.scanCallCount, 0);
          h.elapse(const Duration(milliseconds: 1));
          expect(h.scanner.scanCallCount, 1);
          expect(h.manager.scaleReconnectScheduled, isTrue);
          final reattached = h.scale('usb-1a86-7522-unknown-2009');
          h.scanner.addDevice(reattached);
          h.elapse(const Duration(seconds: 10));
          expect(h.scanner.scanCallCount, 2);
          expect(h.scales.lastConnectedScale, same(reattached));
          expect(h.manager.scaleReconnectScheduled, isFalse);
          expect(h.scanner.startWatchCallCount, 0);
          expect(h.settings.preferredScaleId, 'usb-hds:any');
        });
      },
    );
  }

  test(
    'explicit scan supersedes family recovery without duplicate connections',
    () {
      run((h) {
        final scale = h.scale();
        h.scanner.addDevice(scale);
        h.scanner.scanCompleter = Completer<void>();
        var recoveryComplete = false;
        var explicitComplete = false;
        h.manager.connect(scaleOnly: true).then((_) => recoveryComplete = true);
        h.elapse(Duration.zero);
        expect(h.scales.connectCalls, isEmpty);
        h.manager
            .requestExternalScan(
              connect: true,
              connectPreferredScaleEarly: true,
            )
            .then((_) => explicitComplete = true);
        h.elapse(Duration.zero);
        h.scanner.completeScan();
        h.elapse(Duration.zero);
        expect(recoveryComplete, isTrue);
        expect(explicitComplete, isTrue);
        expect(h.scanner.scanCallCount, 2);
        expect(h.scales.connectCalls, [same(scale)]);
        expect(h.manager.scaleReconnectScheduled, isFalse);
        expect(h.settings.preferredScaleId, 'usb-hds:any');
      });
    },
  );

  test('family auto selection excludes a reserved auxiliary HDS', () {
    run((h) {
      final auxiliary = h.scale();
      final primary = h.scale('usb-1a86-7522-unknown-1005');
      h.manager.connectScale(auxiliary, role: ScaleConnectionRole.auxiliary);
      h.time.flushMicrotasks();
      expect(
        h.manager.auxiliaryScaleRegistry.isReserved(auxiliary.deviceId),
        isTrue,
      );
      h.scanner.addDevice(auxiliary);
      h.scanner.addDevice(primary);
      h.manager.connect(scaleOnly: true);
      h.elapse(Duration.zero);
      expect(h.scales.lastConnectedScale, same(primary));
      expect(
        h.manager.auxiliaryScaleRegistry.isReserved(auxiliary.deviceId),
        isTrue,
      );
      expect(h.settings.preferredScaleId, 'usb-hds:any');
    });
  });

  for (final transport in [TransportType.serial, TransportType.unknown]) {
    test('family does not auto-select from failed $transport discovery', () {
      run((h) {
        h.scanner.addDevice(h.scale());
        h.scanner.scanFailures = [
          ServiceScanFailure(
            serviceName: 'USB serial',
            transportType: transport,
            error: StateError('Partial USB enumeration'),
            stackTrace: StackTrace.current,
          ),
        ];
        h.manager.connect(scaleOnly: true);
        h.elapse(Duration.zero);
        expect(h.scales.connectCalls, isEmpty);
        expect(h.manager.scaleReconnectScheduled, isTrue);
      });
    });
  }

  test('family does not auto-select from a timed-out discovery', () {
    run((h) {
      h.scanner.addDevice(h.scale());
      h.scanner.scanTerminationReason = ScanTerminationReason.timedOut;
      h.manager.connect();
      h.elapse(Duration.zero);
      expect(h.scales.connectCalls, isEmpty);
      expect(h.manager.scaleReconnectScheduled, isTrue);
    });
  });
}
