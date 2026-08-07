import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/services/serial/serial_reconcile.dart';

TrackedPortSnapshot _port(
  String path, {
  bool hds = false,
  bool present = true,
  ConnectionState state = ConnectionState.connected,
}) => TrackedPortSnapshot(
  path: path,
  isHdsSerial: hds,
  present: present,
  state: state,
);

void main() {
  group('planSerialReconcile — liveness gate', () {
    SerialReconcilePlan plan({
      required bool explicit,
      required int tick,
      int everyN = 3,
    }) => planSerialReconcile(
      explicitScan: explicit,
      livenessTick: tick,
      livenessEveryN: everyN,
      tracked: const [],
      hdsPaths: const {},
    );

    test('an explicit scan is always a liveness pass', () {
      expect(plan(explicit: true, tick: 1).livenessPass, isTrue);
      expect(plan(explicit: true, tick: 2).livenessPass, isTrue);
    });

    test('a timer reconcile is a liveness pass every Nth tick', () {
      expect(plan(explicit: false, tick: 1).livenessPass, isFalse);
      expect(plan(explicit: false, tick: 2).livenessPass, isFalse);
      expect(plan(explicit: false, tick: 3).livenessPass, isTrue);
      expect(plan(explicit: false, tick: 6).livenessPass, isTrue);
    });
  });

  group('planSerialReconcile — liveness releases', () {
    test(
      'releases a discovered (not-connected) HDS, keeps a connected one',
      () {
        final p = planSerialReconcile(
          explicitScan: true,
          livenessTick: 1,
          livenessEveryN: 3,
          tracked: [
            _port('/off', hds: true, state: ConnectionState.discovered),
            _port('/live', hds: true, state: ConnectionState.connected),
          ],
          hdsPaths: {'/off', '/live'},
        );
        expect(p.release, {'/off'});
        expect(p.reap, isEmpty, reason: 'a released path is not also reaped');
      },
    );

    test('does NOT release a CONNECTING HDS (would dispose mid-connect)', () {
      final p = planSerialReconcile(
        explicitScan: true,
        livenessTick: 1,
        livenessEveryN: 3,
        tracked: [
          _port('/connecting', hds: true, state: ConnectionState.connecting),
        ],
        hdsPaths: {'/connecting'},
      );
      expect(p.release, isEmpty);
      expect(p.reap, isEmpty);
    });

    test('a non-liveness pass releases nothing', () {
      final p = planSerialReconcile(
        explicitScan: false,
        livenessTick: 1,
        livenessEveryN: 3,
        tracked: [_port('/off', hds: true, state: ConnectionState.discovered)],
        hdsPaths: {'/off'},
      );
      expect(p.livenessPass, isFalse);
      expect(p.release, isEmpty);
    });

    test(
      'does not release a non-HDS device (it is reaped if disconnected)',
      () {
        final p = planSerialReconcile(
          explicitScan: true,
          livenessTick: 1,
          livenessEveryN: 3,
          tracked: [
            _port('/de1', hds: false, state: ConnectionState.disconnected),
          ],
          hdsPaths: const {},
        );
        expect(p.release, isEmpty);
        expect(p.reap, {'/de1'});
      },
    );
  });

  group('planSerialReconcile — reap + suppression', () {
    test('keeps a present, connected device', () {
      final p = planSerialReconcile(
        explicitScan: false,
        livenessTick: 1,
        livenessEveryN: 3,
        tracked: [_port('/de1', state: ConnectionState.connected)],
        hdsPaths: const {},
      );
      expect(p.reap, isEmpty);
      expect(p.suppressAdd, isEmpty);
    });

    test('a present self-disconnect is reaped and suppressed (anti-churn)', () {
      final p = planSerialReconcile(
        explicitScan: false,
        livenessTick: 1,
        livenessEveryN: 3,
        tracked: [
          _port('/s', present: true, state: ConnectionState.disconnected),
        ],
        hdsPaths: const {},
      );
      expect(p.reap, {'/s'});
      expect(p.suppressAdd, {'/s'});
      expect(p.suppressRemove, isEmpty);
      expect(p.hdsForget, isEmpty);
    });

    test('a vanished port is reaped, un-suppressed, and forgotten as HDS', () {
      final p = planSerialReconcile(
        explicitScan: false,
        livenessTick: 1,
        livenessEveryN: 3,
        tracked: [
          _port(
            '/gone',
            hds: true,
            present: false,
            state: ConnectionState.connected,
          ),
        ],
        hdsPaths: {'/gone'},
      );
      expect(p.reap, {'/gone'});
      expect(p.suppressRemove, contains('/gone'));
      expect(p.suppressAdd, isEmpty);
      expect(p.hdsForget, {'/gone'});
    });

    test('a liveness pass lifts HDS suppression, but a same-pass present '
        'self-disconnected HDS nets to suppressed (add wins)', () {
      final p = planSerialReconcile(
        explicitScan: true,
        livenessTick: 1,
        livenessEveryN: 3,
        tracked: [
          _port(
            '/x',
            hds: false,
            present: true,
            state: ConnectionState.disconnected,
          ),
        ],
        hdsPaths: {'/x', '/other'},
      );
      expect(p.suppressRemove, contains('/other'));
      expect(p.suppressAdd, contains('/x'));
      expect(p.suppressRemove, isNot(contains('/x')));
    });
  });

  group('hdsResuppressionPaths', () {
    test('suppresses a present, untracked (silent) HDS port', () {
      expect(
        hdsResuppressionPaths(
          hdsPaths: {'/a', '/b'},
          presentPorts: {'/a', '/b'},
          trackedPaths: {'/a'},
        ),
        {'/b'},
      );
    });

    test('does not suppress an absent HDS port', () {
      expect(
        hdsResuppressionPaths(
          hdsPaths: {'/a'},
          presentPorts: const {},
          trackedPaths: const {},
        ),
        isEmpty,
      );
    });
  });

  group('serialDevicesChanged', () {
    test('false for an identical set', () {
      expect(serialDevicesChanged({'a', 'b'}, {'b', 'a'}), isFalse);
    });
    test('true when a device is added or removed', () {
      expect(serialDevicesChanged({'a', 'b'}, {'a'}), isTrue);
      expect(serialDevicesChanged({'a'}, {'a', 'b'}), isTrue);
    });
  });

  group('serialPortMatchesCandidate', () {
    test('rejects Bluetooth transport', () {
      expect(
        serialPortMatchesCandidate(
          name: 'cu.usbmodem1',
          transport: 'Bluetooth',
        ),
        isFalse,
      );
    });
    test('accepts known productNames', () {
      expect(
        serialPortMatchesCandidate(
          name: 'COM5',
          transport: 'USB',
          productName: 'DE1',
        ),
        isTrue,
      );
      for (final productName in ['Bengle', 'Half Decent Scale']) {
        expect(
          serialPortMatchesCandidate(
            name: 'whatever',
            transport: 'Unknown',
            productName: productName,
          ),
          isTrue,
        );
      }
    });
    test('accepts unix usb-serial port names', () {
      for (final n in [
        'cu.usbmodem1',
        'ttyACM0',
        'ttyUSB0',
        'cu.wchusbserial',
      ]) {
        expect(
          serialPortMatchesCandidate(name: n, transport: 'USB'),
          isTrue,
          reason: n,
        );
      }
    });
    test('accepts a USB COM port, rejects a non-USB COM port', () {
      expect(
        serialPortMatchesCandidate(name: 'COM3', transport: 'USB'),
        isTrue,
      );
      expect(
        serialPortMatchesCandidate(name: 'COM3', transport: 'Native'),
        isFalse,
      );
    });
    test('rejects an unrelated port', () {
      expect(
        serialPortMatchesCandidate(
          name: 'cu.Bluetooth-Incoming',
          transport: 'Native',
        ),
        isFalse,
      );
    });
  });
}
