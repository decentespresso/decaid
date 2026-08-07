import 'package:reaprime/src/controllers/profile_controller.dart';
import 'package:reaprime/src/models/data/profile_record.dart';
import 'package:reaprime/src/services/webserver/data_export/data_export_section.dart';
import 'package:reaprime/src/util/incremental_json_parser.dart';

class ProfileExportSection implements DataExportSection {
  final ProfileController _controller;

  ProfileExportSection({required ProfileController controller})
    : _controller = controller;

  @override
  String get filename => 'profiles.json';

  @override
  Future<void> exportJson(JsonSink output) async {
    final emitter = JsonArrayEmitter(output);
    final ids = await _controller.getAllIds();
    for (final id in ids) {
      final record = await _controller.get(id);
      if (record != null) emitter.add(record.toJson());
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
        errors: ['Expected JSON array of profile records'],
      );
    }

    int imported = 0;
    int skipped = 0;
    final errors = SectionImportErrors();

    await for (final event in input.valuesAtDepth(1)) {
      try {
        final json = event.value as Map<String, dynamic>;
        final record = ProfileRecord.fromJson(json);
        final existing = await _controller.get(record.id);
        if (existing != null) {
          if (strategy == ConflictStrategy.overwrite) {
            await _controller.update(
              record.id,
              profile: record.profile,
              metadata: record.metadata,
            );
            imported++;
          } else {
            skipped++;
          }
        } else {
          final result = await _controller.importProfiles([json]);
          imported += result['imported'] as int;
          skipped += result['skipped'] as int;
          errors.addAll((result['errors'] as List?)?.cast<String>() ?? []);
        }
      } catch (e) {
        errors.add('Failed to import profile: $e');
      }
    }

    return SectionImportResult(
      imported: imported,
      skipped: skipped,
      errors: errors.toList(),
    );
  }
}
