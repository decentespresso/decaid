import 'package:logging/logging.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/steam_record.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';
import 'package:rxdart/rxdart.dart';

class PersistenceController {
  final StorageService storageService;
  final _log = Logger("PersistenceController");

  PersistenceController({required this.storageService});

  void Function(String shotId)? onShotStored;

  final _shotsChangedSubject = PublishSubject<void>();
  Stream<void> get shotsChanged => _shotsChangedSubject.stream;

  final _steamsChangedSubject = PublishSubject<void>();
  Stream<void> get steamsChanged => _steamsChangedSubject.stream;

  void notifyShotsChanged() {
    _shotsChangedSubject.add(null);
  }

  void notifySteamsChanged() {
    _steamsChangedSubject.add(null);
  }

  Future<void> persistShot(ShotRecord record) async {
    _log.info("Storing shot");
    try {
      await storageService.storeShot(record);
      _shotsChangedSubject.add(null);
      onShotStored?.call(record.id);
    } catch (e, st) {
      _log.severe("Error saving shot:", e, st);
    }
  }

  Future<void> updateShot(ShotRecord record) async {
    _log.info("Updating shot: ${record.id}");
    try {
      await storageService.updateShot(record);
      _shotsChangedSubject.add(null);
    } catch (e, st) {
      _log.severe("Error updating shot:", e, st);
      rethrow;
    }
  }

  Future<void> deleteShot(String id) async {
    _log.info("Deleting shot: $id");
    try {
      await storageService.deleteShot(id);
      _shotsChangedSubject.add(null);
    } catch (e, st) {
      _log.severe("Error deleting shot:", e, st);
      rethrow;
    }
  }

  Future<void> persistSteam(SteamRecord record) async {
    _log.info("Storing steam record");
    try {
      await storageService.storeSteam(record);
      _steamsChangedSubject.add(null);
    } catch (e, st) {
      _log.severe("Error saving steam record:", e, st);
    }
  }

  Future<void> updateSteam(SteamRecord record) async {
    _log.info("Updating steam record: ${record.id}");
    try {
      await storageService.updateSteam(record);
      _steamsChangedSubject.add(null);
    } catch (e, st) {
      _log.severe("Error updating steam record:", e, st);
      rethrow;
    }
  }

  Future<void> deleteSteam(String id) async {
    _log.info("Deleting steam record: $id");
    try {
      await storageService.deleteSteam(id);
      _steamsChangedSubject.add(null);
    } catch (e, st) {
      _log.severe("Error deleting steam record:", e, st);
      rethrow;
    }
  }

  Future<void> saveWorkflow(Workflow workflow) async {
    await storageService.storeCurrentWorkflow(workflow);
  }

  Future<Workflow?> loadWorkflow() async {
    return storageService.loadCurrentWorkflow();
  }

  void dispose() {
    _shotsChangedSubject.close();
    _steamsChangedSubject.close();
  }
}
