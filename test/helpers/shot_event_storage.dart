import 'dart:async';

import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/shot_annotations.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';

ShotRecord eventShot({String id = 'shot-1', String notes = 'old'}) =>
    ShotRecord(
      id: id,
      timestamp: DateTime.utc(2024),
      measurements: const [],
      workflow: WorkflowController().currentWorkflow,
      annotations: ShotAnnotations(espressoNotes: notes, enjoyment: 7),
    );

class ShotEventStorage implements StorageService {
  final shots = <String, ShotRecord>{};
  final failedIds = <String>{};
  Completer<void>? writeGate;

  Future<void> _write(ShotRecord record) async {
    if (writeGate != null) await writeGate!.future;
    if (failedIds.contains(record.id)) throw StateError('write failed');
    shots[record.id] = record;
  }

  @override
  Future<void> storeShot(ShotRecord record) => _write(record);

  @override
  Future<void> updateShot(ShotRecord record) => _write(record);

  @override
  Future<ShotRecord?> getShot(String id) async => shots[id];

  @override
  Future<List<ShotRecord>> getShotsPaginated({
    int limit = 20,
    int offset = 0,
    String? grinderId,
    String? grinderModel,
    String? beanBatchId,
    List<String>? beanBatchIds,
    String? coffeeName,
    String? coffeeRoaster,
    String? profileTitle,
    String? search,
    bool ascending = false,
  }) async => shots.values.skip(offset).take(limit).toList();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
