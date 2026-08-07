import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/connection/status_publisher.dart';
import 'package:reaprime/src/controllers/connection_error.dart';
import 'package:reaprime/src/controllers/connection_manager.dart';

ConnectionError _err(String kind) => ConnectionError(
  kind: kind,
  severity: ConnectionErrorSeverity.error,
  timestamp: DateTime(2026, 4, 21, 12, 0),
  message: 'test',
);

void main() {
  group('StatusPublisher', () {
    late StatusPublisher pub;

    setUp(() {
      pub = StatusPublisher();
    });

    tearDown(() {
      pub.dispose();
    });

    test('seeds with an idle ConnectionStatus + no error', () {
      expect(pub.current.phase, ConnectionPhase.idle);
      expect(pub.current.error, isNull);
    });

    test('publish advances phase and emits on stream', () async {
      final phases = <ConnectionPhase>[];
      final sub = pub.stream.listen((s) => phases.add(s.phase));
      pub.publish(pub.current.copyWith(phase: ConnectionPhase.scanning));
      await Future<void>.delayed(Duration.zero);
      expect(phases, contains(ConnectionPhase.scanning));
      sub.cancel();
    });

    test('emitError records an error without changing phase', () {
      pub.publish(pub.current.copyWith(phase: ConnectionPhase.ready));
      pub.emitError(_err(ConnectionErrorKind.scaleConnectFailed));
      expect(pub.current.phase, ConnectionPhase.ready);
      expect(pub.current.error?.kind, ConnectionErrorKind.scaleConnectFailed);
    });

    test('sticky errors survive a publish that leaves error null', () {
      pub.emitError(_err(ConnectionErrorKind.bluetoothPermissionDenied));
      pub.publish(pub.current.copyWith(phase: ConnectionPhase.idle));
      expect(
        pub.current.error?.kind,
        ConnectionErrorKind.bluetoothPermissionDenied,
        reason: 'sticky error must be preserved across phase transitions',
      );
    });

    test('transient errors get stripped when moving into a clearing phase', () {
      pub.emitError(_err(ConnectionErrorKind.scaleConnectFailed));
      pub.publish(pub.current.copyWith(phase: ConnectionPhase.scanning));
      expect(
        pub.current.error,
        isNull,
        reason:
            're-published transient error should be stripped on clearing-phase transition',
      );
    });

    test(
      'a NEW transient error is not stripped on clearing-phase transition',
      () {
        pub.publish(pub.current.copyWith(phase: ConnectionPhase.idle));
        pub.publish(
          pub.current.copyWith(
            phase: ConnectionPhase.ready,
            error: () => _err(ConnectionErrorKind.scaleConnectFailed),
          ),
        );
        expect(pub.current.error, isNull);
      },
    );

    test('clearError drops sticky errors explicitly', () {
      pub.emitError(_err(ConnectionErrorKind.adapterOff));
      expect(pub.current.error, isNotNull);
      pub.clearError();
      expect(pub.current.error, isNull);
    });

    group('phasePersistent errors', () {
      test('profileUploadFailed survives clearing phases', () {
        pub.emitError(_err(ConnectionErrorKind.profileUploadFailed));
        pub.publish(pub.current.copyWith(phase: ConnectionPhase.scanning));
        expect(
          pub.current.error?.kind,
          ConnectionErrorKind.profileUploadFailed,
          reason: 'phase-persistent error must survive scanning',
        );

        pub.publish(pub.current.copyWith(phase: ConnectionPhase.ready));
        expect(
          pub.current.error?.kind,
          ConnectionErrorKind.profileUploadFailed,
          reason: 'phase-persistent error must survive ready',
        );
      });

      test('profileUploadFailed clears through explicit clearError', () {
        pub.emitError(_err(ConnectionErrorKind.profileUploadFailed));
        expect(pub.current.error, isNotNull);
        pub.clearError();
        expect(pub.current.error, isNull);
      });

      test('new error replaces profileUploadFailed', () {
        pub.emitError(_err(ConnectionErrorKind.profileUploadFailed));
        pub.emitError(_err(ConnectionErrorKind.machineConnectFailed));
        expect(
          pub.current.error?.kind,
          ConnectionErrorKind.machineConnectFailed,
          reason: 'new error must replace the previous one',
        );
      });

      test('clearError clears the current error regardless of kind', () {
        pub.emitError(_err(ConnectionErrorKind.profileUploadFailed));
        pub.emitError(_err(ConnectionErrorKind.machineConnectFailed));
        pub.clearError();
        expect(
          pub.current.error,
          isNull,
          reason:
              'unconditional clearError must clear the active error '
              'even when it was not the original one',
        );
      });
    });
  });
}
