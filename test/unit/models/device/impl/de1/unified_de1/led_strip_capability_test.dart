import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/led_strip.dart';

import '../../../../../../helpers/fake_ble_transport.dart';

void main() {
  group('LedStripCapability', () {
    late FakeBleTransport transport;
    late Bengle bengle;
    late List<LogRecord> logRecords;
    late StreamSubscription<LogRecord> logSub;

    setUp(() async {
      logRecords = <LogRecord>[];
      Logger.root.level = Level.ALL;
      logSub = Logger.root.onRecord.listen(logRecords.add);
      transport = FakeBleTransport();
      bengle = Bengle(transport: transport);
      transport.queueOnConnectResponses(v13Model: 128);
      await bengle.onConnect();
    });

    tearDown(() async {
      await logSub.cancel();
      transport.dispose();
    });

    test('ledStripState returns a Stream<LedStripState>', () {
      expect(bengle.ledStripState, isA<Stream<LedStripState>>());
    });

    test('initial state is all-off', () async {
      final state = await bengle.getLedStripState();
      expect(state.frontStrip.sleeping, Color16.off);
      expect(state.frontStrip.awake, Color16.off);
      expect(state.backStrip.sleeping, Color16.off);
      expect(state.backStrip.awake, Color16.off);
      expect(state.frontSwitch.sleeping, Color16.off);
      expect(state.frontSwitch.awake, Color16.off);
    });

    test('initLedStrip logs and no-ops when wires are unwired', () {
      expect(
        logRecords.any(
          (r) =>
              r.message.contains('LedStripCapability') &&
              r.message.contains('unwired'),
        ),
        isTrue,
        reason: 'expected init log entry about unwired endpoints',
      );
    });

    test('setLedStrip updates cache when wires are unwired', () async {
      await bengle.setLedStrip(
        LedStripState(
          frontStrip: ZoneLedState(
            sleeping: const Color16(65535, 32768, 0),
            awake: Color16.off,
          ),
        ),
      );
      final state = await bengle.getLedStripState();
      expect(state.frontStrip.sleeping, const Color16(65535, 32768, 0));
    });

    test('commitLedStrip is safe when wires are unwired', () async {
      await bengle.commitLedStrip();
    });

    test('resetLedStrip is safe when wires are unwired', () async {
      await bengle.resetLedStrip();
    });

    test('disposeLedStrip closes the subject', () async {
      await bengle.onDisconnect();
      await expectLater(
        bengle.ledStripState,
        emitsInOrder([isA<LedStripState>(), emitsDone]),
      );
    });

    test('all BengleLedEndpoint entries have null uuid and representation', () {
      for (final ep in BengleLedEndpoint.values) {
        expect(
          ep.uuid,
          isNull,
          reason: '${ep.name}.uuid should be null (TBD with FW)',
        );
        expect(
          ep.representation,
          isNull,
          reason: '${ep.name}.representation should be null (TBD with FW)',
        );
      }
    });

    test('connect → disconnect → connect lifecycle is leak-free', () async {
      await bengle.disconnect();
      await expectLater(
        bengle.ledStripState,
        emitsInOrder([isA<LedStripState>(), emitsDone]),
      );

      transport.queueOnConnectResponses(v13Model: 128);
      await bengle.onConnect();

      var streamCompletedWithoutValue = false;
      try {
        await bengle.ledStripState.first.timeout(
          const Duration(milliseconds: 50),
        );
      } on TimeoutException {
        // Expected: stream is open but quiet — capability is alive.
      } on StateError {
        streamCompletedWithoutValue = true;
      }
      expect(
        streamCompletedWithoutValue,
        isFalse,
        reason:
            'ledStripState was closed after reconnect — mixin '
            'failed to re-init its BehaviorSubject',
      );
    });
  });
}
