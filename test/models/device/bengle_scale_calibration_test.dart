import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle.dart';
import 'package:reaprime/src/models/device/impl/bengle/bengle_mmr.dart';
import 'package:reaprime/src/models/device/impl/de1/de1.models.dart';
import 'package:reaprime/src/models/device/scale_calibration.dart';

import '../../helpers/fake_ble_transport.dart';

int _packed({
  required ScaleCalibrationStep step,
  ScaleCalibrationCell cell = ScaleCalibrationCell.none,
  ScaleCalibrationSubState subState = ScaleCalibrationSubState.settling,
  int secondsRemaining = 0,
  ScaleCalibrationStatus status = ScaleCalibrationStatus.none,
}) =>
    (step.wireValue << 24) |
    (cell.wireValue << 20) |
    (subState.wireValue << 16) |
    (secondsRemaining << 8) |
    status.wireValue;

void main() {
  group('Bengle scale calibration', () {
    late FakeBleTransport transport;
    late Bengle bengle;

    setUp(() async {
      transport = FakeBleTransport();
      bengle = Bengle(transport: transport);
      transport.queueOnConnectResponses(v13Model: 128);
      transport.queueMmrResponseRaw(
        BengleMmr.scaleCalWeight,
        [0xD0, 0x07, 0x00, 0x00], // probe
      );
      transport.queuePaletteHydrationResponses();
      await bengle.onConnect();
    });

    tearDown(() {
      transport.dispose();
    });

    group('ScaleCalibrationState.decode', () {
      test('decodes every packed field exactly as the firmware packs it', () {
        final state = ScaleCalibrationState.decode(
          _packed(
            step: ScaleCalibrationStep.calLatch,
            cell: ScaleCalibrationCell.a,
            subState: ScaleCalibrationSubState.averaging,
            secondsRemaining: 7,
            status: ScaleCalibrationStatus.notSettled,
          ),
        );
        expect(state.step, ScaleCalibrationStep.calLatch);
        expect(state.detectedCell, ScaleCalibrationCell.a);
        expect(state.subState, ScaleCalibrationSubState.averaging);
        expect(state.secondsRemaining, 7);
        expect(state.status, ScaleCalibrationStatus.notSettled);
        expect(state.isInProgress, isTrue);
        expect(state.isTerminal, isFalse);
      });

      test('decodes idle/complete/error and cell B', () {
        final idle = ScaleCalibrationState.decode(0);
        expect(idle.step, ScaleCalibrationStep.idle);
        expect(idle.status, ScaleCalibrationStatus.ok);
        expect(idle.isInProgress, isFalse);
        expect(idle.isTerminal, isFalse);

        final complete = ScaleCalibrationState.decode(
          _packed(
            step: ScaleCalibrationStep.complete,
            cell: ScaleCalibrationCell.b,
            subState: ScaleCalibrationSubState.done,
            status: ScaleCalibrationStatus.ok,
          ),
        );
        expect(complete.step, ScaleCalibrationStep.complete);
        expect(complete.detectedCell, ScaleCalibrationCell.b);
        expect(complete.isTerminal, isTrue);

        final error = ScaleCalibrationState.decode(
          _packed(
            step: ScaleCalibrationStep.error,
            subState: ScaleCalibrationSubState.error,
            status: ScaleCalibrationStatus.noZero,
          ),
        );
        expect(error.step, ScaleCalibrationStep.error);
        expect(error.status, ScaleCalibrationStatus.noZero);
        expect(error.isTerminal, isTrue);
      });
    });

    group('startScaleCalibration', () {
      test(
        'latch writes weight x10 then cmd, accepts on step change',
        () async {
          transport.queueMmrResponseIntSequence(BengleMmr.scaleCalState, [
            _packed(
              step: ScaleCalibrationStep.complete,
              subState: ScaleCalibrationSubState.done,
              status: ScaleCalibrationStatus.ok,
            ), // before
            _packed(
              step: ScaleCalibrationStep.calLatch,
              secondsRemaining: 15,
            ), // after
          ]);
          transport.writes.clear();

          final accepted = await bengle.startScaleCalibration(
            ScaleCalibrationCommand.latch,
            weightGrams: 45.5,
          );

          expect(accepted, isTrue);

          final mmrWrites = transport.writes.where(
            (w) => w.characteristicUUID == Endpoint.writeToMMR.uuid,
          );
          expect(mmrWrites.length, 2);

          // Weight first: address 0x00803888, payload 455 (45.5 g x 10) LE.
          final weightAddr = ByteData(4)
            ..setInt32(0, BengleMmr.scaleCalWeight.address, Endian.big);
          final weightFrame = mmrWrites.first;
          expect(weightFrame.data[1], weightAddr.getUint8(1));
          expect(weightFrame.data[2], weightAddr.getUint8(2));
          expect(weightFrame.data[3], weightAddr.getUint8(3));
          final weightPayload = ByteData.sublistView(weightFrame.data, 4, 8);
          expect(weightPayload.getUint32(0, Endian.little), 455);

          // Then the command: address 0x00803880, payload 2 (latch) LE.
          final cmdAddr = ByteData(4)
            ..setInt32(0, BengleMmr.scaleCalCmd.address, Endian.big);
          final cmdFrame = mmrWrites.last;
          expect(cmdFrame.data[1], cmdAddr.getUint8(1));
          expect(cmdFrame.data[2], cmdAddr.getUint8(2));
          expect(cmdFrame.data[3], cmdAddr.getUint8(3));
          final cmdPayload = ByteData.sublistView(cmdFrame.data, 4, 8);
          expect(cmdPayload.getUint32(0, Endian.little), 2);
        },
      );

      test(
        'reports rejected when the step never leaves its terminal value',
        () async {
          final terminal = _packed(
            step: ScaleCalibrationStep.complete,
            subState: ScaleCalibrationSubState.done,
            status: ScaleCalibrationStatus.ok,
          );
          transport.queueMmrResponseIntSequence(
            BengleMmr.scaleCalState,
            [terminal, terminal], // busy: firmware ignores the command
          );

          final accepted = await bengle.startScaleCalibration(
            ScaleCalibrationCommand.zero,
          );
          expect(accepted, isFalse);
        },
      );

      test('abort is accepted even when already idle', () async {
        transport.queueMmrResponseIntSequence(BengleMmr.scaleCalState, [0, 0]);

        final accepted = await bengle.startScaleCalibration(
          ScaleCalibrationCommand.abort,
        );
        expect(accepted, isTrue);
      });

      test('latch clamps the reference weight to 1..10000 g', () async {
        transport.queueMmrResponseIntSequence(BengleMmr.scaleCalState, [0, 0]);
        transport.writes.clear();

        await bengle.startScaleCalibration(
          ScaleCalibrationCommand.latch,
          weightGrams: 0.2,
        );

        final weightFrame = transport.writes.firstWhere(
          (w) => w.characteristicUUID == Endpoint.writeToMMR.uuid,
        );
        final payload = ByteData.sublistView(weightFrame.data, 4, 8);
        expect(payload.getUint32(0, Endian.little), 10); // 1.0 g x 10
      });

      test('serializes concurrent submissions (single flight)', () async {
        transport.queueMmrResponseIntSequence(BengleMmr.scaleCalState, [
          0, // zero before
          1 << 24, // zero after (Zeroing)
          1 << 24, // latch before
          2 << 24, // latch after (CalLatch)
        ]);

        final results = await Future.wait([
          bengle.startScaleCalibration(ScaleCalibrationCommand.zero),
          bengle.startScaleCalibration(
            ScaleCalibrationCommand.latch,
            weightGrams: 100,
          ),
        ]);
        expect(results, [true, true]);
      });
    });

    group('getScaleCalibrationState', () {
      test('reads and decodes the packed register from the wire', () async {
        final packed = _packed(
          step: ScaleCalibrationStep.zeroing,
          secondsRemaining: 12,
        );
        transport.queueMmrResponseInt(BengleMmr.scaleCalState, packed);

        final state = await bengle.getScaleCalibrationState();
        expect(state.step, ScaleCalibrationStep.zeroing);
        expect(state.secondsRemaining, 12);
      });
    });
  });
}
