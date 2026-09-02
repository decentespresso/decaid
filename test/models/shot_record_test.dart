import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/shot_annotations.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/shot_snapshot.dart';
import 'package:reaprime/src/models/device/machine.dart';

void main() {
  test('canonical constructor annotations stay authoritative when null', () {
    final serialized = ShotRecord(
      id: 'shot-1',
      timestamp: DateTime.utc(2026, 7, 23),
      measurements: const [],
      workflow: WorkflowController().currentWorkflow,
      annotations: const ShotAnnotations(),
      shotNotes: 'legacy notes',
      metadata: const {'favorite': true},
    ).toJson();

    expect(serialized['annotations'], isEmpty);
    expect(serialized.containsKey('shotNotes'), isFalse);
    expect(serialized.containsKey('metadata'), isFalse);
  });

  test(
    'legacy aliases synthesize annotations when canonical key is absent',
    () {
      final json = _baseJson()
        ..addAll({
          'shotNotes': 'legacy notes',
          'metadata': {'favorite': true},
        });

      final serialized = ShotRecord.fromJson(json).toJson();

      expect(serialized['annotations'], {
        'espressoNotes': 'legacy notes',
        'extras': {'favorite': true},
      });
      expect(serialized['shotNotes'], 'legacy notes');
      expect(serialized['metadata'], {'favorite': true});
    },
  );

  test('canonical annotation object ignores conflicting legacy aliases', () {
    final json = _baseJson()
      ..addAll({
        'annotations': {
          'espressoNotes': 'canonical notes',
          'extras': {'favorite': true},
        },
        'shotNotes': 'stale notes',
        'metadata': {'favorite': false},
      });

    final serialized = ShotRecord.fromJson(json).toJson();

    expect(serialized['shotNotes'], 'canonical notes');
    expect(serialized['metadata'], {'favorite': true});
  });

  test('explicit canonical null does not reconstruct stale aliases', () {
    final json = _baseJson()
      ..addAll({
        'annotations': null,
        'shotNotes': 'stale notes',
        'metadata': {'favorite': false},
      });

    final serialized = ShotRecord.fromJson(json).toJson();

    expect(serialized.containsKey('annotations'), isFalse);
    expect(serialized.containsKey('shotNotes'), isFalse);
    expect(serialized.containsKey('metadata'), isFalse);
  });

  test('serialization always emits UTC for createdAt and updatedAt', () {
    final record = ShotRecord(
      id: 'shot-1',
      timestamp: DateTime.utc(2026, 7, 23),
      createdAt: DateTime(2026, 7, 23, 10, 30),
      updatedAt: DateTime(2026, 7, 23, 10, 31),
      measurements: const [],
      workflow: WorkflowController().currentWorkflow,
    );

    expect(record.toJson()['createdAt'], endsWith('Z'));
    expect(record.toJson()['updatedAt'], endsWith('Z'));
    expect(record.toJsonWithoutMeasurements()['createdAt'], endsWith('Z'));
    expect(record.toJsonWithoutMeasurements()['updatedAt'], endsWith('Z'));
  });

  test('fromJson normalizes non-UTC and legacy-fallback timestamps to UTC', () {
    final json = _baseJson()
      ..['createdAt'] = '2026-07-23T10:30:00'
      ..['updatedAt'] = '2026-07-23T10:31:00';

    final record = ShotRecord.fromJson(json);
    expect(record.createdAt!.isUtc, isTrue);
    expect(record.updatedAt!.isUtc, isTrue);
    expect(record.toJson()['createdAt'], endsWith('Z'));
    expect(record.toJson()['updatedAt'], endsWith('Z'));

    final legacy = ShotRecord.fromJson(_baseJson());
    expect(legacy.createdAt!.isUtc, isTrue);
    expect(legacy.updatedAt!.isUtc, isTrue);
    expect(legacy.createdAt, legacy.timestamp.toUtc());
    expect(legacy.updatedAt, legacy.timestamp.toUtc());
  });

  group('sameContent', () {
    final workflow = WorkflowController().currentWorkflow;

    ShotRecord record({Map<String, dynamic>? extras, String? notes}) =>
        ShotRecord(
          id: 'shot-1',
          timestamp: DateTime.utc(2026, 7, 23),
          createdAt: DateTime.utc(2026, 7, 23, 9),
          updatedAt: DateTime.utc(2026, 7, 23, 9, 30),
          measurements: const [],
          workflow: workflow,
          annotations: ShotAnnotations(espressoNotes: notes, extras: extras),
        );

    test('bookkeeping-only differences are not content', () {
      final base = record(extras: {'favorite': true});
      final withMarker = record(
        extras: {'favorite': true, 'uploaded_to_decent': 1767230000},
      );
      final changedMarker = record(
        extras: {'favorite': true, 'uploaded_to_decent': 1767230001},
      );
      final visualizerOnly = record(
        extras: {'favorite': true, 'visualizerId': 'viz-1'},
      );
      final rejectedOnly = record(
        extras: {
          'favorite': true,
          'decent_upload_rejected': {'status': 422},
        },
      );

      expect(base.sameContent(withMarker), isTrue);
      expect(base.sameContent(changedMarker), isTrue);
      expect(base.sameContent(visualizerOnly), isTrue);
      expect(base.sameContent(rejectedOnly), isTrue);
    });

    test('empty extras compares equal to absent extras', () {
      final noExtras = record(notes: 'hi');
      final emptyExtras = record(notes: 'hi', extras: {});
      final markerOnly = record(notes: 'hi', extras: {'uploaded_to_decent': 1});

      expect(noExtras.sameContent(emptyExtras), isTrue);
      expect(noExtras.sameContent(markerOnly), isTrue);
    });

    test('empty annotations compares equal to absent annotations', () {
      final bare = ShotRecord(
        id: 'shot-1',
        timestamp: DateTime.utc(2026, 7, 23),
        measurements: const [],
        workflow: workflow,
      );
      final markerOnly = record(extras: {'visualizerId': 'viz-1'});

      expect(bare.sameContent(markerOnly), isTrue);
    });

    test('meaningful extras differences are content', () {
      final base = record(extras: {'favorite': true});
      final changed = record(extras: {'favorite': false});
      final added = record(extras: {'favorite': true, 'origin': 'x'});

      expect(base.sameContent(changed), isFalse);
      expect(base.sameContent(added), isFalse);
    });

    test('notes differences are content', () {
      expect(record(notes: 'a').sameContent(record(notes: 'b')), isFalse);
    });

    test('system-managed timestamps never count as content', () {
      final a = record();
      final b = record();
      final c = ShotRecord(
        id: 'shot-1',
        timestamp: DateTime.utc(2026, 7, 23),
        createdAt: DateTime.utc(2026, 7, 23, 8),
        updatedAt: DateTime.utc(2026, 7, 23, 8, 45),
        measurements: const [],
        workflow: workflow,
        annotations: const ShotAnnotations(),
      );

      expect(a.sameContent(b), isTrue);
      expect(a.sameContent(c), isTrue);
    });

    test('measurements count as content only when requested', () {
      ShotSnapshot snapshot(double volume) => ShotSnapshot(
        machine: MachineSnapshot(
          timestamp: DateTime.utc(2026, 7, 23, 10),
          state: const MachineStateSnapshot(
            state: MachineState.steam,
            substate: MachineSubstate.pouring,
          ),
          flow: 0,
          pressure: 0,
          targetFlow: 0,
          targetPressure: 0,
          mixTemperature: 90,
          groupTemperature: 90,
          targetMixTemperature: 93,
          targetGroupTemperature: 93,
          profileFrame: 0,
          steamTemperature: 140,
        ),
        volume: volume,
      );

      final plain = record();
      final withFlow = ShotRecord(
        id: 'shot-1',
        timestamp: DateTime.utc(2026, 7, 23),
        createdAt: DateTime.utc(2026, 7, 23, 9),
        updatedAt: DateTime.utc(2026, 7, 23, 9, 30),
        measurements: [snapshot(42)],
        workflow: workflow,
      );

      expect(plain.sameContent(withFlow), isTrue);
      expect(plain.sameContent(withFlow, includeMeasurements: true), isFalse);
      expect(withFlow.sameContent(withFlow, includeMeasurements: true), isTrue);
    });
  });
}

Map<String, dynamic> _baseJson() => ShotRecord(
  id: 'shot-1',
  timestamp: DateTime.utc(2026, 7, 23),
  measurements: const [],
  workflow: WorkflowController().currentWorkflow,
).toJson();
