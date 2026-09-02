import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/services/webserver/data_export/backup_data_sources.dart';
import 'package:reaprime/src/services/webserver/data_export/data_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/data_transfer_limits.dart';
import 'package:reaprime/src/util/incremental_json_parser.dart';

class ShotExportSection implements DataExportSection {
  final PersistenceController _controller;
  final PageCursor<ShotRecord> _pageShots;
  final int pageSize;

  ShotExportSection({
    required PersistenceController controller,
    required PageCursor<ShotRecord> pageShots,
    this.pageSize = DataTransferLimits.defaultExportPageSize,
  }) : _controller = controller,
       _pageShots = pageShots;

  @override
  String get filename => 'shots.json';

  @override
  Future<void> exportJson(JsonSink output) async {
    final emitter = JsonArrayEmitter(output);
    DateTime? cursorTimestamp;
    String? cursorId;
    while (true) {
      final page = await _pageShots(
        pageSize,
        afterTimestamp: cursorTimestamp,
        afterId: cursorId,
      );
      if (page.isEmpty) break;
      for (final shot in page) {
        emitter.add(shot.toJson());
        cursorTimestamp = shot.timestamp;
        cursorId = shot.id;
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
        errors: ['Expected JSON array of shot records'],
      );
    }

    int imported = 0;
    int skipped = 0;
    final errors = SectionImportErrors();

    await for (final event in input.valuesAtDepth(1)) {
      try {
        final record = ShotRecord.fromJson(event.value as Map<String, dynamic>);
        final existing = await _controller.storageService.getShot(record.id);

        if (existing != null) {
          if (strategy == ConflictStrategy.overwrite) {
            final contentChanged = !existing.sameContent(
              record,
              includeMeasurements: true,
            );
            await _controller.storageService.updateShot(
              record.copyWith(
                createdAt:
                    existing.createdAt ??
                    record.createdAt ??
                    existing.timestamp,
                updatedAt: contentChanged
                    ? DateTime.now().toUtc()
                    : existing.updatedAt ??
                          existing.createdAt ??
                          existing.timestamp,
              ),
            );
            imported++;
          } else {
            skipped++;
          }
        } else {
          await _controller.storageService.storeShot(record);
          imported++;
        }
      } catch (e) {
        errors.add('Failed to import shot: $e');
      }
    }

    if (imported > 0) {
      _controller.notifyShotsChanged();
    }

    return SectionImportResult(
      imported: imported,
      skipped: skipped,
      errors: errors.toList(),
    );
  }
}
