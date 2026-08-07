import 'package:drift/drift.dart';
import 'package:reaprime/src/models/data/workflow.dart' as domain;
import 'package:reaprime/src/services/database/database.dart' as db;

class WorkflowMapper {
  static domain.Workflow fromRow(db.Workflow row) {
    return domain.Workflow.fromJson(row.workflowJson);
  }

  static db.WorkflowsCompanion toCompanion(
    domain.Workflow workflow, {
    String id = 'current',
  }) {
    return db.WorkflowsCompanion(
      id: Value(id),
      workflowJson: Value(workflow.toJson()),
      updatedAt: Value(DateTime.now()),
    );
  }
}
