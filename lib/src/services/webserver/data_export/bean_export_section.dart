import 'package:reaprime/src/models/data/bean.dart';
import 'package:reaprime/src/services/storage/bean_storage_service.dart';
import 'package:reaprime/src/services/webserver/data_export/backup_data_sources.dart';
import 'package:reaprime/src/services/webserver/data_export/data_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/data_transfer_limits.dart';
import 'package:reaprime/src/util/incremental_json_parser.dart';

class BeanExportSection implements DataExportSection {
  final BeanStorageService _storage;
  final PageCursor<Bean> _pageBeans;
  final int pageSize;

  BeanExportSection({
    required BeanStorageService storage,
    required PageCursor<Bean> pageBeans,
    this.pageSize = DataTransferLimits.defaultExportPageSize,
  }) : _storage = storage,
       _pageBeans = pageBeans;

  @override
  String get filename => 'beans.json';

  @override
  Future<void> exportJson(JsonSink output) async {
    final emitter = JsonArrayEmitter(output);
    DateTime? cursorCreatedAt;
    String? cursorId;
    while (true) {
      final page = await _pageBeans(
        pageSize,
        afterCreatedAt: cursorCreatedAt,
        afterId: cursorId,
      );
      if (page.isEmpty) break;
      for (final bean in page) {
        final batches = await _storage.getBatchesForBean(
          bean.id,
          includeArchived: true,
        );
        final beanJson = bean.toJson();
        beanJson['batches'] = batches.map((b) => b.toJson()).toList();
        emitter.add(beanJson);
        cursorCreatedAt = bean.createdAt;
        cursorId = bean.id;
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
        errors: ['Expected JSON array of bean records'],
      );
    }

    int imported = 0;
    int skipped = 0;
    final errors = SectionImportErrors();

    await for (final event in input.valuesAtDepth(1)) {
      try {
        final json = event.value as Map<String, dynamic>;
        final batches =
            (json['batches'] as List?)
                ?.cast<Map<String, dynamic>>()
                .map((b) => BeanBatch.fromJson(b))
                .toList() ??
            [];

        final beanJson = Map<String, dynamic>.from(json)..remove('batches');
        final bean = Bean.fromJson(beanJson);

        final existing = await _storage.getBeanById(bean.id);
        if (existing != null) {
          if (strategy == ConflictStrategy.overwrite) {
            await _storage.updateBean(bean);
            imported++;
          } else {
            skipped++;
          }
        } else {
          await _storage.insertBean(bean);
          imported++;
        }

        for (final batch in batches) {
          try {
            final existingBatch = await _storage.getBatchById(batch.id);
            if (existingBatch != null) {
              if (strategy == ConflictStrategy.overwrite) {
                await _storage.updateBatch(batch);
                imported++;
              } else {
                skipped++;
              }
            } else {
              await _storage.insertBatch(batch);
              imported++;
            }
          } catch (e) {
            errors.add('Failed to import batch ${batch.id}: $e');
          }
        }
      } catch (e) {
        errors.add('Failed to import bean: $e');
      }
    }

    return SectionImportResult(
      imported: imported,
      skipped: skipped,
      errors: errors.toList(),
    );
  }
}
