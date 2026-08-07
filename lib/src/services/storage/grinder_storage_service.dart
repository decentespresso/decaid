import 'package:reaprime/src/models/data/grinder.dart';

abstract class GrinderStorageService {
  Future<List<Grinder>> getAllGrinders({bool includeArchived = false});
  Stream<List<Grinder>> watchAllGrinders({bool includeArchived = false});
  Future<Grinder?> getGrinderById(String id);
  Future<void> insertGrinder(Grinder grinder);
  Future<void> updateGrinder(Grinder grinder);
  Future<void> deleteGrinder(String id);
}
