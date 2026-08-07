import 'package:drift/drift.dart';
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/database/tables/workflow_tables.dart';

part 'workflow_dao.g.dart';

@DriftAccessor(tables: [Workflows])
class WorkflowDao extends DatabaseAccessor<AppDatabase>
    with _$WorkflowDaoMixin {
  WorkflowDao(super.db);

  static const _currentWorkflowId = 'current';

  Future<Workflow?> loadCurrentWorkflow() {
    return (select(
      workflows,
    )..where((w) => w.id.equals(_currentWorkflowId))).getSingleOrNull();
  }

  Future<void> saveCurrentWorkflow(WorkflowsCompanion workflow) {
    return into(workflows).insertOnConflictUpdate(
      workflow.copyWith(id: const Value(_currentWorkflowId)),
    );
  }
}
