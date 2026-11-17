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

  group('serial identity candidates', () {
    SerialPortMetadata metadata(
      String path, {
      int? vid,
      int? pid,
      String? serial,
      int? interfaceNumber,
    }) => SerialPortMetadata(
      path: path,
      name: path.split('/').last,
      transport: 'USB',
      vid: vid,
      pid: pid,
      serial: serial,
      interfaceNumber: interfaceNumber,
    );

    test('canonicalId uses USB metadata or the path basename', () {
      expect(
        metadata(
          '/dev/cu.X',
          vid: 0x1234,
          pid: 0xabcd,
          serial: 'abc',
        ).canonicalId,
        'usb-1234-abcd-abc',
      );
      expect(metadata('/dev/ttyUSB0').canonicalId, 'serial-ttyUSB0');
    });

    test('interface numbers produce distinct IDs and candidates', () {
      final machine = metadata('/dev/ttyUSB0', vid: 1, pid: 2, serial: 'abc');
      final tap = metadata(
        '/dev/ttyUSB1',
        vid: 1,
        pid: 2,
        serial: 'abc',
        interfaceNumber: 1,
      );

      expect(tap.canonicalId, 'usb-1-2-abc-if01');
      expect(dedupeSerialCandidates([machine, tap]), [machine, tap]);
    });

    test('USB aliases collapse and prefer cu regardless of input order', () {
      final cu = metadata('/dev/cu.X', vid: 1, pid: 2, serial: 'abc');
      final tty = metadata('/dev/tty.X', vid: 1, pid: 2, serial: 'abc');

      for (final result in [
        dedupeSerialCandidates([tty, cu]),
        dedupeSerialCandidates([cu, tty]),
      ]) {
        expect(result, hasLength(1));
        expect(result.single.path, '/dev/cu.X');
        expect(result.single.canonicalId, 'usb-1-2-abc');
      }
    });

    test('same canonical USB ID collapses within one batch', () {
      final first = metadata('/dev/ttyUSB0', vid: 1, pid: 2, serial: 'abc');
      final second = metadata('/dev/ttyUSB1', vid: 1, pid: 2, serial: 'abc');

      expect(dedupeSerialCandidates([first, second]), [first]);
    });

    test('non-alias paths retain the first candidate', () {
      final first = metadata('/dev/COM5', vid: 1, pid: 2, serial: 'abc');
      final second = metadata('/dev/cu.X', vid: 1, pid: 2, serial: 'abc');

      expect(dedupeSerialCandidates([first, second]), [first]);
    });

    test('macOS aliases without USB metadata collapse and prefer cu', () {
      final cu = metadata('/dev/cu.X');
      final tty = metadata('/dev/tty.X');

      final result = dedupeSerialCandidates([tty, cu]);
      expect(result, hasLength(1));
      expect(result.single.path, '/dev/cu.X');
      expect(result.single.canonicalId, 'serial-cu.X');
    });

    test('mixed metadata macOS aliases collapse and keep the USB id', () {
      final cu = metadata('/dev/cu.X', vid: 1, pid: 2, serial: 'abc');
      final bareTty = metadata('/dev/tty.X');

      for (final batch in [
        [cu, bareTty],
        [bareTty, cu],
      ]) {
        final result = dedupeSerialCandidates(batch);
        expect(result, hasLength(1));
        expect(result.single.path, '/dev/cu.X');
        expect(result.single.canonicalId, 'usb-1-2-abc');
      }
    });

    test('trackedSerialIdentities unions tracked ids and alias ids', () {
      expect(
        trackedSerialIdentities(
          trackedIds: {'usb-1-2-abc'},
          trackedPaths: {'/dev/cu.X'},
        ),
        {'usb-1-2-abc', 'serial-cu.X', 'serial-tty.X'},
      );
    });

    test('legacy IDs cover macOS aliases and other port names', () {
      expect(desktopSerialLegacyIds('/dev/cu.wchusbserial535A0000011'), {
        'serial-cu.wchusbserial535A0000011',
        'serial-tty.wchusbserial535A0000011',
      });
      expect(desktopSerialLegacyIds('/dev/ttyUSB0'), {'serial-ttyUSB0'});
    });

    test('acceptedIds includes canonical and legacy IDs', () {
      final candidate = metadata('/dev/cu.X', vid: 1, pid: 2, serial: 'abc');

      expect(candidate.acceptedIds, {
        'usb-1-2-abc',
        'serial-cu.X',
        'serial-tty.X',
      });
    });
  });
}
