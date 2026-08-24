import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/de1_interface.dart';
import 'package:reaprime/src/models/device/impl/bengle/mock_bengle.dart';
import 'package:reaprime/src/models/device/impl/mock_de1/mock_de1.dart';
import 'package:reaprime/src/debug_feature/debug_item_details_view.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/test_de1.dart';

class _CalibrationDe1 extends TestDe1 {
  var reads = <(De1CalibrationTarget, De1CalibrationSource)>[];
  var writes = <De1Calibration>[];
  var failReads = false;
  var failWrites = false;

  var current = <De1CalibrationTarget, De1Calibration>{
    De1CalibrationTarget.flow: const De1Calibration(
      target: De1CalibrationTarget.flow,
      de1ReportedValue: 1,
      measuredValue: 1.1,
    ),
    De1CalibrationTarget.pressure: const De1Calibration(
      target: De1CalibrationTarget.pressure,
      de1ReportedValue: 1,
      measuredValue: 0.9,
    ),
    De1CalibrationTarget.temperature: const De1Calibration(
      target: De1CalibrationTarget.temperature,
      de1ReportedValue: 0,
      measuredValue: -0.25,
    ),
  };

  final factory = <De1CalibrationTarget, De1Calibration>{
    for (final target in De1CalibrationTarget.values)
      target: De1Calibration(
        target: target,
        de1ReportedValue: target == De1CalibrationTarget.temperature ? 0 : 1,
        measuredValue: target == De1CalibrationTarget.temperature ? 0 : 1,
      ),
  };

  @override
  Future<De1Calibration> readCalibration(
    De1CalibrationTarget target, {
    De1CalibrationSource source = De1CalibrationSource.current,
  }) async {
    reads = [...reads, (target, source)];
    if (failReads) throw Exception('read failed');
    return source == De1CalibrationSource.current
        ? current[target]!
        : factory[target]!;
  }

  @override
  Future<void> writeCalibration(De1Calibration calibration) async {
    if (failWrites) throw Exception('write failed');
    writes = [...writes, calibration];
    final previous = current[calibration.target]!.measuredValue;
    final measuredValue = calibration.target == De1CalibrationTarget.temperature
        ? previous + (calibration.measuredValue - calibration.de1ReportedValue)
        : previous * calibration.measuredValue / calibration.de1ReportedValue;
    current = {
      ...current,
      calibration.target: De1Calibration(
        target: calibration.target,
        de1ReportedValue: calibration.target == De1CalibrationTarget.temperature
            ? 0
            : 1,
        measuredValue: measuredValue,
      ),
    };
  }
}

class _DelayedCalibrationDe1 extends _CalibrationDe1 {
  final _connection = Completer<void>();
  var _connected = false;

  @override
  Future<void> onConnect() async {
    await _connection.future;
    _connected = true;
  }

  @override
  Future<De1Calibration> readCalibration(
    De1CalibrationTarget target, {
    De1CalibrationSource source = De1CalibrationSource.current,
  }) {
    if (!_connected) throw StateError('read before connection');
    return super.readCalibration(target, source: source);
  }

  void completeConnection() => _connection.complete();
}

void main() {
  group('debugViewTitle', () {
    test('returns DE1 label for a non-Bengle De1Interface', () {
      expect(debugViewTitle(MockDe1()), equals('DE1 Details'));
    });

    test('returns Bengle label for a BengleInterface', () {
      expect(debugViewTitle(MockBengle()), equals('Bengle Details'));
    });
  });

  group('DE1 calibration controls', () {
    Future<void> pumpView(
      WidgetTester tester,
      _CalibrationDe1 machine, {
      bool scrollToCalibration = true,
    }) async {
      await tester.pumpWidget(
        ScaffoldMessenger(
          child: ShadApp(
            home: De1DebugView(key: ValueKey(machine), machine: machine),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (scrollToCalibration) {
        await tester.scrollUntilVisible(
          find.text('Calibration'),
          400,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
      }
    }

    testWidgets('reads current and factory values for every target', (
      tester,
    ) async {
      final machine = _CalibrationDe1();

      await pumpView(tester, machine);

      expect(find.text('Calibration'), findsOneWidget);
      expect(find.text('Flow'), findsAtLeastNWidgets(1));
      expect(find.text('Pressure'), findsAtLeastNWidgets(1));
      expect(find.text('Temperature'), findsAtLeastNWidgets(1));
      expect(machine.reads.toSet(), {
        for (final target in De1CalibrationTarget.values)
          (target, De1CalibrationSource.current),
        for (final target in De1CalibrationTarget.values)
          (target, De1CalibrationSource.factory),
      });
      expect(
        find.text('Current: reported 1.0000, measured 1.1000'),
        findsOneWidget,
      );
      expect(
        find.text('Factory: reported 1.0000, measured 1.0000'),
        findsNWidgets(2),
      );
    });

    testWidgets('waits for connection before reading calibration', (
      tester,
    ) async {
      final machine = _DelayedCalibrationDe1();

      await tester.pumpWidget(
        ScaffoldMessenger(
          child: ShadApp(home: De1DebugView(machine: machine)),
        ),
      );
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('Calibration'),
        400,
        scrollable: find.byType(Scrollable).first,
      );

      expect(machine.reads, isEmpty);

      machine.completeConnection();
      await tester.pumpAndSettle();

      expect(machine.reads, hasLength(6));
    });

    testWidgets('writes entered values and refreshes the current value', (
      tester,
    ) async {
      final machine = _CalibrationDe1();
      await pumpView(tester, machine);
      final reported = find.byKey(const Key('calibration-reported-flow'));
      final measured = find.byKey(const Key('calibration-measured-flow'));
      final write = find.byKey(const Key('calibration-write-flow'));
      await tester.ensureVisible(write);
      await tester.pumpAndSettle();

      await tester.enterText(reported, '1.2');
      await tester.enterText(measured, '1.5');
      await tester.tap(write);
      await tester.pumpAndSettle();

      expect(machine.writes, [
        const De1Calibration(
          target: De1CalibrationTarget.flow,
          de1ReportedValue: 1.2,
          measuredValue: 1.5,
        ),
      ]);
      expect(
        machine.reads
            .where(
              (read) =>
                  read.$1 == De1CalibrationTarget.flow &&
                  read.$2 == De1CalibrationSource.current,
            )
            .length,
        2,
      );
      expect(
        find.text('Current: reported 1.0000, measured 1.3750'),
        findsOneWidget,
      );
      expect(find.text('Flow calibration updated'), findsOneWidget);
    });

    testWidgets('writing unchanged controls preserves the calibration', (
      tester,
    ) async {
      final machine = _CalibrationDe1();
      await pumpView(tester, machine);
      final write = find.byKey(const Key('calibration-write-flow'));
      await tester.ensureVisible(write);
      await tester.pumpAndSettle();

      await tester.tap(write);
      await tester.pumpAndSettle();

      expect(
        machine.writes.single,
        const De1Calibration(
          target: De1CalibrationTarget.flow,
          de1ReportedValue: 1.1,
          measuredValue: 1.1,
        ),
      );
      expect(
        find.text('Current: reported 1.0000, measured 1.1000'),
        findsOneWidget,
      );
    });

    testWidgets('rejects invalid values without writing', (tester) async {
      final machine = _CalibrationDe1();
      await pumpView(tester, machine);
      final reported = find.byKey(const Key('calibration-reported-flow'));
      final write = find.byKey(const Key('calibration-write-flow'));
      await tester.ensureVisible(write);
      await tester.pumpAndSettle();

      await tester.enterText(reported, 'not-a-number');
      await tester.tap(write);
      await tester.pumpAndSettle();

      expect(machine.writes, isEmpty);
      expect(
        find.text('Enter valid reported and measured values'),
        findsOneWidget,
      );
    });

    testWidgets('permits a zero reported value for temperature', (
      tester,
    ) async {
      final machine = _CalibrationDe1();
      await pumpView(tester, machine);

      final temperatureReported = find.byKey(
        const Key('calibration-reported-temperature'),
      );
      final temperatureWrite = find.byKey(
        const Key('calibration-write-temperature'),
      );
      await tester.ensureVisible(temperatureWrite);
      await tester.enterText(temperatureReported, '0');
      await tester.tap(temperatureWrite);
      await tester.pumpAndSettle();

      expect(machine.writes.single.target, De1CalibrationTarget.temperature);
      expect(machine.writes.single.de1ReportedValue, 0);
    });

    testWidgets('shows device read and write failures', (tester) async {
      final readFailure = _CalibrationDe1()..failReads = true;
      await pumpView(tester, readFailure, scrollToCalibration: false);
      expect(find.text('Calibration read failed'), findsOneWidget);
      expect(find.text('Exception: read failed'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      final writeFailure = _CalibrationDe1()..failWrites = true;
      await pumpView(tester, writeFailure);
      final write = find.byKey(const Key('calibration-write-flow'));
      await tester.ensureVisible(write);
      await tester.pumpAndSettle();
      await tester.tap(write);
      await tester.pumpAndSettle();

      expect(find.text('Calibration write failed'), findsOneWidget);
      expect(find.text('Exception: write failed'), findsOneWidget);
    });

    testWidgets('invalidates a target when write verification fails', (
      tester,
    ) async {
      final machine = _CalibrationDe1();
      await pumpView(tester, machine);
      final write = find.byKey(const Key('calibration-write-flow'));
      await tester.ensureVisible(write);
      machine.failReads = true;

      await tester.tap(write);
      await tester.pumpAndSettle();

      expect(machine.writes, hasLength(1));
      expect(find.text('Calibration refresh failed'), findsOneWidget);
      expect(find.text('Current: unavailable'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(write, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(machine.writes, hasLength(1));
    });

    testWidgets('failed refresh invalidates values and stops reading', (
      tester,
    ) async {
      final machine = _CalibrationDe1();
      await pumpView(tester, machine);
      machine.failReads = true;

      await tester.tap(find.byIcon(LucideIcons.refreshCw));
      await tester.pumpAndSettle();

      expect(machine.reads, hasLength(7));
      expect(find.text('Current: unavailable'), findsNWidgets(3));
      expect(find.text('Factory: unavailable'), findsNWidgets(3));
      expect(find.text('Calibration read failed'), findsOneWidget);
    });

    testWidgets('fits narrow and wide debug layouts', (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      for (final size in const [Size(360, 800), Size(1200, 800)]) {
        tester.view.physicalSize = size;
        await pumpView(tester, _CalibrationDe1());
        expect(tester.takeException(), isNull);
      }
    });
  });
}
