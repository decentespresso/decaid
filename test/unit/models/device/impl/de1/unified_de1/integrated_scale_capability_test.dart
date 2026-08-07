import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/de1/unified_de1/unified_de1.dart';
import 'package:reaprime/src/models/device/scale.dart';

import '../../../../../../helpers/fake_ble_transport.dart';

void main() {
  group('IntegratedScaleCapability', () {
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

    test('weightSnapshot returns a Stream<ScaleSnapshot>', () {
      expect(bengle.weightSnapshot, isA<Stream<ScaleSnapshot>>());
    });

    test('initIntegratedScale logs and no-ops when wires are unwired', () {
      expect(
        logRecords.any(
          (r) =>
              r.message.contains('IntegratedScaleCapability') &&
              r.message.contains('unwired'),
        ),
        isTrue,
        reason: 'expected init log entry about unwired endpoint',
      );
    });

    test('disposeIntegratedScale closes the subject', () async {
      await bengle.onDisconnect();
      await expectLater(bengle.weightSnapshot, emitsDone);
    });

    test(
      'tareIntegratedScale logs and no-ops when wires are unwired',
      () async {
        logRecords.clear();
        await bengle.tareIntegratedScale();
        expect(
          logRecords.any(
            (r) =>
                r.message.contains('IntegratedScaleCapability') &&
                r.message.contains('tare'),
          ),
          isTrue,
          reason: 'expected tare log entry about unwired control endpoint',
        );
      },
    );

    test('BengleScaleEndpoint.weight.uuid and representation are null', () {
      expect(BengleScaleEndpoint.weight.uuid, isNull);
      expect(BengleScaleEndpoint.weight.representation, isNull);
    });

    test('BengleScaleEndpoint.control.uuid and representation are null', () {
      expect(BengleScaleEndpoint.control.uuid, isNull);
      expect(BengleScaleEndpoint.control.representation, isNull);
    });

    test('connect → disconnect → connect lifecycle is leak-free', () async {
      await bengle.disconnect();
      await expectLater(bengle.weightSnapshot, emitsDone);

      transport.queueOnConnectResponses(v13Model: 128);
      await bengle.onConnect();

      var streamCompletedWithoutValue = false;
      try {
        await bengle.weightSnapshot.first.timeout(
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
            'weightSnapshot was closed after reconnect — mixin '
            'failed to re-init its BehaviorSubject',
      );
    });
  });
}
