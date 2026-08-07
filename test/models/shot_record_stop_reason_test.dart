import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/shot_record.dart';

void main() {
  final workflow = WorkflowController().currentWorkflow;

  ShotRecord makeRecord({String? stopReason}) {
    return ShotRecord(
      id: 'shot-1',
      timestamp: DateTime.utc(2026, 6, 17, 9, 0),
      measurements: const [],
      workflow: workflow,
      stopReason: stopReason,
    );
  }

  group('ShotRecord.stopReason', () {
    test('serializes to JSON and round-trips', () {
      final record = makeRecord(stopReason: 'targetWeight');

      final json = record.toJson();
      expect(json['stopReason'], 'targetWeight');

      final parsed = ShotRecord.fromJson(json);
      expect(parsed.stopReason, 'targetWeight');
    });

    test('is omitted from JSON when null', () {
      final json = makeRecord().toJson();
      expect(json.containsKey('stopReason'), isFalse);
    });

    test('parses to null for legacy shots without the field', () {
      final json = makeRecord().toJson()..remove('stopReason');
      expect(ShotRecord.fromJson(json).stopReason, isNull);
    });

    test('an unknown reason string survives a round-trip untouched', () {
      final record = makeRecord(stopReason: 'someFutureReason');
      final parsed = ShotRecord.fromJson(record.toJson());
      expect(parsed.stopReason, 'someFutureReason');
    });

    test('appears in the measurement-free list serialization too', () {
      final json = makeRecord(
        stopReason: 'machineEnded',
      ).toJsonWithoutMeasurements();
      expect(json['stopReason'], 'machineEnded');
    });

    test('copyWith preserves and overrides stopReason', () {
      final record = makeRecord(stopReason: 'targetWeight');
      expect(record.copyWith().stopReason, 'targetWeight');
      expect(
        record.copyWith(stopReason: 'machineEnded').stopReason,
        'machineEnded',
      );
    });
  });
}
