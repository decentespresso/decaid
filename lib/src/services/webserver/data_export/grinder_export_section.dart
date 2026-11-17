import 'package:reaprime/src/models/data/grinder.dart';
import 'package:reaprime/src/services/storage/grinder_storage_service.dart';
import 'package:reaprime/src/services/webserver/data_export/backup_data_sources.dart';
import 'package:reaprime/src/services/webserver/data_export/data_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/data_transfer_limits.dart';
import 'package:reaprime/src/util/incremental_json_parser.dart';

class GrinderExportSection implements DataExportSection {
  final GrinderStorageService _storage;
  final PageCursor<Grinder> _pageGrinders;
  final int pageSize;

  GrinderExportSection({
    required this._storage,
    required this._pageGrinders,
    this.pageSize = DataTransferLimits.defaultExportPageSize,
  });

  @override
  String get filename => 'grinders.json';

  @override
  Future<void> exportJson(JsonSink output) async {
    final emitter = JsonArrayEmitter(output);
    DateTime? cursorCreatedAt;
    String? cursorId;
    while (true) {
      final page = await _pageGrinders(
        pageSize,
        afterCreatedAt: cursorCreatedAt,
        afterId: cursorId,
      );
      if (page.isEmpty) break;
      for (final grinder in page) {
        emitter.add(grinder.toJson());
        cursorCreatedAt = grinder.createdAt;
        cursorId = grinder.id;
      }
      if (page.length < pageSize) break;
    }
    emitter.end();
  }

  @override
  Future<SectionImportResult> importJson(
    SectionJsonInput input,
    ConflictStrategy strategy,
  ) async {
    if (await input.open() != JsonContainerKind.array) {
      return const SectionImportResult(
        errors: ['Expected JSON array of grinder records'],
      );
    }

    int imported = 0;
    int skipped = 0;
    final errors = SectionImportErrors();

    await for (final event in input.valuesAtDepth(1)) {
      try {
        final grinder = Grinder.fromJson(event.value as Map<String, dynamic>);
        final existing = await _storage.getGrinderById(grinder.id);

        if (existing != null) {
          if (strategy == ConflictStrategy.overwrite) {
            await _storage.updateGrinder(grinder);
            imported++;
          } else {
            skipped++;
          }
        } else {
          await _storage.insertGrinder(grinder);
          imported++;
        }
      } catch (e) {
        errors.add('Failed to import grinder: $e');
      }
    }

    return SectionImportResult(
      imported: imported,
      skipped: skipped,
      errors: errors.toList(),
    );
  }
}
