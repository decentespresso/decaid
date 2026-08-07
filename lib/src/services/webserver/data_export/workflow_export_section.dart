import 'dart:convert';

import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/services/webserver/data_export/data_export_section.dart';

class WorkflowExportSection implements DataExportSection {
  final WorkflowController _controller;

  WorkflowExportSection({required WorkflowController controller})
    : _controller = controller;

  @override
  String get filename => 'workflow.json';

  @override
  Future<void> exportJson(JsonSink output) async {
    output.writeRaw(jsonEncode(_controller.currentWorkflow.toJson()));
  }

  @override
  Future<SectionImportResult> importJson(
    SectionJsonInput input,
    ConflictStrategy strategy,
  ) async {
    try {
      final data = await input.readWhole();
      final workflow = Workflow.fromJson(data as Map<String, dynamic>);
      _controller.setWorkflow(workflow);
      return const SectionImportResult(imported: 1);
    } catch (e) {
      return SectionImportResult(errors: ['Failed to import workflow: $e']);
    }
  }
}
