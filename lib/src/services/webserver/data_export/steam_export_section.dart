import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/models/data/steam_record.dart';
import 'package:reaprime/src/services/webserver/data_export/backup_data_sources.dart';
import 'package:reaprime/src/services/webserver/data_export/data_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/data_transfer_limits.dart';
import 'package:reaprime/src/util/incremental_json_parser.dart';

class SteamExportSection implements DataExportSection {
  final PersistenceController _controller;
  final PageCursor<SteamRecord> _pageSteams;
  final int pageSize;

  SteamExportSection({
    required this._controller,
    required this._pageSteams,
    this.pageSize = DataTransferLimits.defaultExportPageSize,
  });

  @override
  String get filename => 'steams.json';

  @override
  Future<void> exportJson(JsonSink output) async {
    final emitter = JsonArrayEmitter(output);
    DateTime? cursorTimestamp;
    String? cursorId;
    while (true) {
      final page = await _pageSteams(
        pageSize,
        afterTimestamp: cursorTimestamp,
        afterId: cursorId,
      );
      if (page.isEmpty) break;
      for (final record in page) {
        emitter.add(record.toJson());
        cursorTimestamp = record.timestamp;
        cursorId = record.id;
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
        errors: ['Expected JSON array of steam records'],
      );
    }

    int imported = 0;
    int skipped = 0;
    final errors = SectionImportErrors();

    await for (final event in input.valuesAtDepth(1)) {
      try {
        final record = SteamRecord.fromJson(
          event.value as Map<String, dynamic>,
        );
        final existing = await _controller.storageService.getSteam(record.id);

        if (existing != null) {
          if (strategy == ConflictStrategy.overwrite) {
            await _controller.storageService.updateSteam(record);
            imported++;
          } else {
            skipped++;
          }
        } else {
          await _controller.storageService.storeSteam(record);
          imported++;
        }
      } catch (e) {
        errors.add('Failed to import steam record: $e');
      }
    }

    if (imported > 0) {
      _controller.notifySteamsChanged();
    }

    return SectionImportResult(
      imported: imported,
      skipped: skipped,
      errors: errors.toList(),
    );
  }
}
