import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/controllers/connection/status_publisher.dart';
import 'package:reaprime/src/controllers/connection_error.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/services/telemetry/anonymization.dart';
import 'package:reaprime/src/services/telemetry/log_buffer.dart';
import 'package:reaprime/src/services/telemetry/telemetry_forwarder_filter.dart';
import 'package:reaprime/src/services/telemetry/telemetry_report_queue.dart';
import 'package:reaprime/src/util/shot_importer.dart';
import 'package:reaprime/src/util/user_facing_exception.dart';

import '../../helpers/shot_event_storage.dart';

void main() {
  late Level previousLevel;
  late StreamSubscription<LogRecord> subscription;
  late LogBuffer logBuffer;
  late List<LogRecord> records;
  late List<Object> sentErrors;
  late List<StackTrace?> sentStacks;

  setUp(() {
    previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    logBuffer = LogBuffer();
    records = [];
    sentErrors = [];
    sentStacks = [];
    final queue = TelemetryReportQueue((
      error,
      stack, {
      bool fatal = false,
    }) async {
      sentErrors.add(error);
      sentStacks.add(stack);
    });
    subscription = Logger.root.onRecord.listen((record) {
      records.add(record);
      if (record.level < Level.WARNING) return;
      final scrubbed = Anonymization.scrubString(
        '${record.level.name}: ${record.loggerName}: ${record.message}',
      );
      logBuffer.append(scrubbed);
      if (shouldForwardToTelemetry(record)) {
        queue.enqueue(record.error ?? scrubbed, record.stackTrace);
      }
    });
  });

  tearDown(() async {
    await subscription.cancel();
    Logger.root.level = previousLevel;
  });

  test(
    'recoverable StatusPublisher events stay buffered, not reported',
    () async {
      final publisher = StatusPublisher();
      addTearDown(publisher.dispose);
      const kinds = [
        ConnectionErrorKind.machineConnectFailed,
        ConnectionErrorKind.machineDisconnected,
        ConnectionErrorKind.scaleConnectFailed,
        ConnectionErrorKind.scaleDisconnected,
        ConnectionErrorKind.sensorConnectFailed,
        ConnectionErrorKind.grinderConnectFailed,
      ];

      for (final kind in kinds) {
        publisher.emitError(
          ConnectionError(
            kind: kind,
            severity: ConnectionErrorSeverity.error,
            timestamp: DateTime.utc(2026),
            message: 'Recoverable connection state',
          ),
        );
      }
      await pumpEventQueue();

      expect(records, hasLength(kinds.length));
      for (var i = 0; i < kinds.length; i++) {
        expect(records[i].loggerName, 'StatusPublisher');
        expect(records[i].level, Level.SEVERE);
        expect(records[i].error, isNull);
        expect(records[i].stackTrace, isNull);
        expect(
          logBuffer.getContents(),
          contains('StatusPublisher: emit error:'),
        );
        expect(logBuffer.getContents(), contains('kind=${kinds[i]}'));
      }
      expect(sentErrors, isEmpty);
    },
  );

  test('handled invalid shot JSON stays buffered, not reported', () async {
    final controller = PersistenceController(
      storageService: ShotEventStorage(),
    );
    addTearDown(controller.dispose);
    final importer = ShotImporter(controller: controller);
    try {
      await importer.importJson('{invalid shot JSON');
      fail('Invalid input must throw');
    } on FormatException catch (error, stack) {
      Logger(
        'DataManagement',
      ).severe('Legacy shot import failed', error, stack);
    }
    await pumpEventQueue();

    expect(records.single.error, isA<UserFacingFormatException>());
    expect(
      logBuffer.getContents(),
      contains('DataManagement: Legacy shot import failed'),
    );
    expect(sentErrors, isEmpty);
  });

  for (final logger in ['DataManagement', 'BLETransport-device']) {
    test(
      'unexpected $logger FormatException retains its origin through queue',
      () async {
        late FormatException originalError;
        late StackTrace originalStack;
        try {
          _unexpectedFormatFailure();
        } on FormatException catch (error, stack) {
          originalError = error;
          originalStack = stack;
          Logger(logger).severe('Unexpected parser failure', error, stack);
        }
        await pumpEventQueue();

        expect(records.single.error, same(originalError));
        expect(records.single.stackTrace, same(originalStack));
        expect(sentErrors, hasLength(1));
        expect(sentErrors.single, same(originalError));
        expect(sentErrors.single, isNot(isA<UserFacingFormatException>()));
        expect(sentStacks.single, same(originalStack));
        expect(
          sentStacks.single.toString(),
          contains('_unexpectedFormatFailure'),
        );
        expect(
          logBuffer.getContents(),
          contains('$logger: Unexpected parser failure'),
        );
      },
    );
  }

  for (final logger in [
    'BLETransport-device',
    'StatusPublisher',
    'DataManagement',
  ]) {
    test(
      'unexpected $logger exception retains its origin through queue',
      () async {
        late Object originalError;
        late StackTrace originalStack;
        try {
          _unexpectedFailure();
        } catch (error, stack) {
          originalError = error;
          originalStack = stack;
          Logger(logger).severe('Unexpected subsystem failure', error, stack);
        }
        await pumpEventQueue();

        expect(sentErrors, hasLength(1));
        expect(sentErrors.single, same(originalError));
        expect(sentStacks.single, same(originalStack));
        expect(sentStacks.single.toString(), contains('_unexpectedFailure'));
        expect(
          logBuffer.getContents(),
          contains('$logger: Unexpected subsystem failure'),
        );
      },
    );
  }
}

Never _unexpectedFailure() => throw StateError('Unexpected subsystem failure');

Never _unexpectedFormatFailure() =>
    throw const FormatException('Unexpected internal data');
