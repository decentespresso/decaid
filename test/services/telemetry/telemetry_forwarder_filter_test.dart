import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/errors.dart';
import 'package:reaprime/src/services/telemetry/telemetry_forwarder_filter.dart';
import 'package:reaprime/src/util/remote_error.dart';

LogRecord _record(
  Level level,
  String loggerName,
  String message, [
  Object? error,
  StackTrace? stackTrace,
]) {
  return LogRecord(level, message, loggerName, error, stackTrace);
}

void main() {
  test(
    'typed download service failures remain excluded from crash telemetry',
    () {
      for (final logger in ['WebUIStorage', 'AndroidUpdater']) {
        expect(
          shouldForwardToTelemetry(
            _record(
              Level.SEVERE,
              logger,
              'Download failed',
              remoteHttpError(404),
            ),
          ),
          isFalse,
        );
      }
    },
  );
  group('shouldForwardToTelemetry', () {
    group('SEVERE floor', () {
      test('WARNING with no noise pattern is dropped', () {
        final record = _record(
          Level.WARNING,
          'SomeController',
          'something unusual happened',
        );
        expect(shouldForwardToTelemetry(record), isFalse);
      });

      test('WARNING with a real error is dropped', () {
        final record = _record(
          Level.WARNING,
          'SomeController',
          'invariant violated',
          StateError('bad state'),
        );
        expect(shouldForwardToTelemetry(record), isFalse);
      });

      test('INFO is dropped', () {
        final record = _record(Level.INFO, 'SomeController', 'just fyi');
        expect(shouldForwardToTelemetry(record), isFalse);
      });

      test('SEVERE is forwarded', () {
        final record = _record(Level.SEVERE, 'SomeController', 'boom');
        expect(shouldForwardToTelemetry(record), isTrue);
      });

      test('SHOUT is forwarded', () {
        final record = _record(Level.SHOUT, 'SomeController', 'really boom');
        expect(shouldForwardToTelemetry(record), isTrue);
      });
    });

    test('drops SEVERE operationCancelled errors', () {
      final record = _record(
        Level.SEVERE,
        'BLETransport-device',
        'queued write failed',
        _FakeUniversalBleException(
          'Code: UniversalBleErrorCode.operationCancelled',
        ),
      );

      expect(shouldForwardToTelemetry(record), isFalse);
    });

    group('drops noise from WebUIStorage', () {
      test('"Skin already exists: ..." is dropped', () {
        final record = _record(
          Level.SEVERE,
          'WebUIStorage',
          'Skin already exists: streamline_project-main, overwriting…',
        );
        expect(shouldForwardToTelemetry(record), isFalse);
      });

      test('SocketException at SEVERE is dropped', () {
        final record = _record(
          Level.SEVERE,
          'WebUIStorage',
          'Failed to install WebUI from URL: https://example.com/skin.zip',
          const SocketException('Failed host lookup: example.com'),
        );
        expect(shouldForwardToTelemetry(record), isFalse);
      });

      test('TimeoutException at SEVERE is dropped', () {
        final record = _record(
          Level.SEVERE,
          'WebUIStorage',
          'Failed to install WebUI from URL: https://example.com/skin.zip',
          TimeoutException('http get'),
        );
        expect(shouldForwardToTelemetry(record), isFalse);
      });

      test('HttpException at SEVERE is dropped', () {
        final record = _record(
          Level.SEVERE,
          'WebUIStorage',
          'Failed to install WebUI from URL: https://example.com/skin.zip',
          const HttpException('connection closed'),
        );
        expect(shouldForwardToTelemetry(record), isFalse);
      });

      test('Exception("Failed to fetch GitHub release: 403") is dropped', () {
        final record = _record(
          Level.SEVERE,
          'WebUIStorage',
          'GitHub release install failed',
          Exception('Failed to fetch GitHub release: 403'),
        );
        expect(shouldForwardToTelemetry(record), isFalse);
      });

      test('Exception("Failed to download: 404") is dropped', () {
        final record = _record(
          Level.SEVERE,
          'WebUIStorage',
          'Skin install failed',
          Exception('Failed to download: 404'),
        );
        expect(shouldForwardToTelemetry(record), isFalse);
      });
    });

    group('keeps real WebUIStorage problems', () {
      test('StateError at SEVERE is kept (real bug)', () {
        final record = _record(
          Level.SEVERE,
          'WebUIStorage',
          'Skin install failed',
          StateError('zip corrupt'),
        );
        expect(shouldForwardToTelemetry(record), isTrue);
      });

      test('Unrelated SEVERE message is kept', () {
        final record = _record(
          Level.SEVERE,
          'WebUIStorage',
          'Manifest parse failed: missing required field',
        );
        expect(shouldForwardToTelemetry(record), isTrue);
      });
    });

    group('does not affect other loggers', () {
      test('SocketException from BleTransport is kept', () {
        final record = _record(
          Level.SEVERE,
          'BleTransport',
          'connection failed',
          const SocketException('Connection refused'),
        );
        expect(shouldForwardToTelemetry(record), isTrue);
      });

      test('"Skin already exists" emitted by a different logger is kept', () {
        final record = _record(
          Level.SEVERE,
          'SomeOtherLogger',
          'Skin already exists: foo',
        );
        expect(shouldForwardToTelemetry(record), isTrue);
      });
    });

    group('drops typed transient exceptions regardless of logger', () {
      test(
        'DeviceNotConnectedException.machine from any logger is dropped',
        () {
          final record = _record(
            Level.SEVERE,
            'BatteryController',
            'Failed to set USB charger mode',
            const DeviceNotConnectedException.machine(),
          );
          expect(shouldForwardToTelemetry(record), isFalse);
        },
      );

      test('DeviceNotConnectedException.scale from any logger is dropped', () {
        final record = _record(
          Level.SEVERE,
          'PresenceController',
          'Failed to send user present',
          const DeviceNotConnectedException.scale(),
        );
        expect(shouldForwardToTelemetry(record), isFalse);
      });

      test('MmrTimeoutException from any logger is dropped', () {
        final record = _record(
          Level.SEVERE,
          'De1Controller',
          'shotSettings readback failed',
          const MmrTimeoutException('flushFlowRate', Duration(seconds: 2)),
        );
        expect(shouldForwardToTelemetry(record), isFalse);
      });

      test('typed transient exception is dropped at SEVERE too', () {
        final record = _record(
          Level.SEVERE,
          'AnyLogger',
          'machine call failed',
          const DeviceNotConnectedException.machine(),
        );
        expect(shouldForwardToTelemetry(record), isFalse);
      });
    });

    group('extends transient-network-error skip to AndroidUpdater', () {
      test('SocketException from AndroidUpdater is dropped', () {
        final record = _record(
          Level.SEVERE,
          'AndroidUpdater',
          'checkForUpdate failed',
          const SocketException('Failed host lookup: api.github.com'),
        );
        expect(shouldForwardToTelemetry(record), isFalse);
      });

      test('TimeoutException from AndroidUpdater is dropped', () {
        final record = _record(
          Level.SEVERE,
          'AndroidUpdater',
          'checkForUpdate timed out',
          TimeoutException('http get'),
        );
        expect(shouldForwardToTelemetry(record), isFalse);
      });

      test('Real bug from AndroidUpdater is kept', () {
        final record = _record(
          Level.SEVERE,
          'AndroidUpdater',
          'parse failed',
          StateError('release manifest malformed'),
        );
        expect(shouldForwardToTelemetry(record), isTrue);
      });
    });

    group('keeps genuinely-unexpected exceptions', () {
      test('StateError from any logger is kept', () {
        final record = _record(
          Level.SEVERE,
          'SomeController',
          'invariant violated',
          StateError('bad state'),
        );
        expect(shouldForwardToTelemetry(record), isTrue);
      });
    });
  });
}

class _FakeUniversalBleException implements Exception {
  _FakeUniversalBleException(this.message);

  final String message;

  @override
  String toString() => 'UniversalBleException: $message';
}
