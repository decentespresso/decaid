import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/device/device.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/transport/serial_port.dart';
import 'package:rxdart/rxdart.dart';

/// Regression coverage for comms-harden #1 — `setProfile` equality guard.
///
/// The guard short-circuits when `_currentProfile == profile`. Before the
/// fix, `_currentProfile` was assigned **before** `_sendProfile` was
/// awaited, so a mid-upload throw (e.g. a BLE timeout after the header
/// frame but before the tail) poisoned the cache: a retry with the same
/// profile hit the guard and silently no-op'd, leaving the DE1 running
/// on a half-loaded profile with the caller seeing success.
///
/// After the fix, `_currentProfile` is assigned only after `_sendProfile`
/// completes successfully, so a retry with the same profile after a
/// failed upload proceeds with a fresh upload.
///
/// Option C verification: integration test over a real `UnifiedDe1` with
/// a recording `SerialTransport`. Counts `writeCommand` invocations as a
/// proxy for "upload happened".
///
/// See: doc/plans/comms-harden.md #1, doc/plans/comms-phase-0-1.md PR 2.
class _RecordingSerialTransport extends SerialTransport {
  final _connState = BehaviorSubject<ConnectionState>.seeded(
    ConnectionState.connected,
  );
  final List<String> writes = [];

  /// If set, the call whose zero-based index matches this value throws
  /// once, then clears itself.
  int? failIndexOnce;

  @override
  String get id => 'test-serial-de1';

  @override
  String get name => 'TestSerialDe1';

  @override
  Stream<ConnectionState> get connectionState => _connState.stream;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Stream<String> get readStream => const Stream.empty();

  @override
  Stream<Uint8List> get rawStream => const Stream.empty();

  @override
  Future<void> writeHexCommand(Uint8List command) async {}

  @override
  Future<void> writeCommand(String command) async {
    final index = writes.length;
    writes.add(command);
    if (failIndexOnce != null && failIndexOnce == index) {
      failIndexOnce = null;
      throw Exception('simulated transport failure at index $index');
    }
  }

  @override
  Future<void> dispose() async {
    _connState.close();
  }
}

void main() {
  group('setProfile retry semantics (comms-harden #1)', () {
    late _RecordingSerialTransport transport;
    late UnifiedDe1 de1;

    const profile = Profile(
      version: '2',
      title: 'Phase 1 Test Profile',
      notes: '',
      author: 'test',
      beverageType: BeverageType.espresso,
      steps: [],
      targetVolumeCountStart: 0,
      tankTemperature: 0,
    );

    setUp(() {
      transport = _RecordingSerialTransport();
      de1 = UnifiedDe1(transport: transport);
    });

    tearDown(() {
      transport.dispose();
    });

    test(
      'retry with the same profile after a failed upload triggers a fresh send',
      () async {
        transport.failIndexOnce = 0;
        await expectLater(
          () => de1.setProfile(profile),
          throwsA(isA<Exception>()),
        );
        final writesAfterFailure = transport.writes.length;
        expect(
          writesAfterFailure,
          1,
          reason:
              'only the header write reached the transport before the throw',
        );

        await de1.setProfile(profile);

        expect(
          transport.writes.length,
          greaterThan(writesAfterFailure),
          reason: 'retry must re-upload after a prior failed attempt',
        );
      },
    );

    test('repeated call after a successful upload is a no-op', () async {
      await de1.setProfile(profile);
      final writesAfterSuccess = transport.writes.length;
      expect(writesAfterSuccess, greaterThan(0));

      await de1.setProfile(profile);
      expect(
        transport.writes.length,
        writesAfterSuccess,
        reason: 'identical upload on successful cache must short-circuit',
      );
    });

    test('failed upload invalidates the cache — re-pushing the previously '
        'successful profile re-uploads', () async {
      await de1.setProfile(profile);
      final writesAfterSuccess = transport.writes.length;
      expect(writesAfterSuccess, greaterThan(0));

      final other = profile.copyWith(title: 'Other Profile');
      transport.failIndexOnce = writesAfterSuccess;
      await expectLater(() => de1.setProfile(other), throwsA(isA<Exception>()));

      // Reverting to the original profile MUST re-upload it, not
      // short-circuit on the stale success cache.
      await de1.setProfile(profile);
      expect(
        transport.writes.length,
        greaterThan(writesAfterSuccess + 1),
        reason: 'revert after a failed upload must re-drive the full sequence',
      );
    });

    test('different profile always uploads', () async {
      await de1.setProfile(profile);
      final writesAfterFirst = transport.writes.length;

      final other = profile.copyWith(title: 'Different Profile');
      await de1.setProfile(other);

      expect(
        transport.writes.length,
        greaterThan(writesAfterFirst),
        reason: 'different profile must upload even after a prior success',
      );
    });
  });

  group('concurrent setProfile serialization', () {
    // A profile upload is a stateful multi-write sequence (header + frames +
    // tail) the firmware consumes as one conversation. Two uploads whose
    // writes interleave on the transport queue wedge the firmware's
    // profile-receive state machine — so UnifiedDe1 must serialize uploads
    // across ALL callers (workflow sync, REST handler, reconnect defaults).
    // The two profiles differ in step count so their write sequences differ
    // in length and content; expectations compare against each profile's
    // solo-run write sequence, captured once below.

    const profileA = Profile(
      version: '2',
      title: 'Serialization A',
      notes: '',
      author: 'test',
      beverageType: BeverageType.espresso,
      steps: [],
      targetVolumeCountStart: 0,
      tankTemperature: 0,
    );

    const profileB = Profile(
      version: '2',
      title: 'Serialization B',
      notes: '',
      author: 'test',
      beverageType: BeverageType.espresso,
      steps: [
        ProfileStepPressure(
          name: 'pour',
          transition: TransitionType.fast,
          volume: 0,
          seconds: 30,
          temperature: 92,
          sensor: TemperatureSensor.coffee,
          pressure: 9,
        ),
      ],
      targetVolumeCountStart: 0,
      tankTemperature: 0,
    );

    late List<String> soloWritesA;
    late List<String> soloWritesB;

    /// The exact transport writes one upload of [p] produces on its own.
    Future<List<String>> soloWrites(Profile p) async {
      final t = _RecordingSerialTransport();
      final d = UnifiedDe1(transport: t);
      await d.setProfile(p);
      final writes = List<String>.from(t.writes);
      await t.dispose();
      return writes;
    }

    setUpAll(() async {
      soloWritesA = await soloWrites(profileA);
      soloWritesB = await soloWrites(profileB);
    });

    late _RecordingSerialTransport transport;
    late UnifiedDe1 de1;

    setUp(() {
      transport = _RecordingSerialTransport();
      de1 = UnifiedDe1(transport: transport);
    });

    tearDown(() {
      transport.dispose();
    });

    test('sequences differ so interleaving would be observable', () {
      expect(
        soloWritesA.length,
        greaterThanOrEqualTo(2),
        reason: 'an upload must be a multi-write sequence',
      );
      expect(soloWritesB.length, greaterThan(soloWritesA.length));
    });

    test(
      'concurrent uploads of different profiles do not interleave',
      () async {
        final first = de1.setProfile(profileA);
        final second = de1.setProfile(profileB);
        await Future.wait([first, second]);

        expect(
          transport.writes,
          [...soloWritesA, ...soloWritesB],
          reason:
              'the second upload must not start until the first — '
              'including its post-upload firmware flash guard — has finished',
        );
      },
    );

    test('concurrent identical uploads collapse to one — the equality guard '
        'is evaluated when the upload starts, not when it queues', () async {
      final first = de1.setProfile(profileB);
      final second = de1.setProfile(profileB);
      await Future.wait([first, second]);

      expect(
        transport.writes,
        soloWritesB,
        reason:
            'the queued duplicate must see the fresh cache and '
            'short-circuit instead of re-uploading',
      );
    });

    test('a failed upload releases the queue for the next one', () async {
      transport.failIndexOnce = 0;
      final first = de1.setProfile(profileA);
      final second = de1.setProfile(profileB);

      await expectLater(first, throwsA(isA<Exception>()));
      await second;

      expect(
        transport.writes.length,
        1 + soloWritesB.length,
        reason: 'A records only its failed header; B runs in full',
      );
      expect(
        transport.writes.sublist(1),
        soloWritesB,
        reason: 'the queued upload must run untouched by the failure',
      );
    });
  });
}
