import 'package:drift/drift.dart';
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/database/tables/bean_tables.dart';

part 'bean_dao.g.dart';

@DriftAccessor(tables: [Beans, BeanBatches])
class BeanDao extends DatabaseAccessor<AppDatabase> with _$BeanDaoMixin {
  BeanDao(super.db);

  Future<List<Bean>> getAllBeans({bool includeArchived = false}) {
    final query = select(beans);
    if (!includeArchived) {
      query.where((b) => b.archived.equals(false));
    }
    query.orderBy([(b) => OrderingTerm.desc(b.updatedAt)]);
    return query.get();
  }

  Future<List<Bean>> getBeansForExport({
    int limit = 200,
    DateTime? cursorCreatedAt,
    String? cursorId,
  }) {
    final query = select(beans)
      ..orderBy([
        (b) => OrderingTerm.asc(b.createdAt),
        (b) => OrderingTerm.asc(b.id),
      ])
      ..limit(limit);
    if (cursorCreatedAt != null) {
      query.where(
        (b) =>
            b.createdAt.isBiggerThanValue(cursorCreatedAt) |
            (b.createdAt.equals(cursorCreatedAt) &
                b.id.isBiggerThanValue(cursorId!)),
      );
    }
    return query.get();
  }

  Stream<List<Bean>> watchAllBeans({bool includeArchived = false}) {
    final query = select(beans);
    if (!includeArchived) {
      query.where((b) => b.archived.equals(false));
    }
    query.orderBy([(b) => OrderingTerm.desc(b.updatedAt)]);
    return query.watch();
  }

  Future<Bean?> getBeanById(String id) {
    return (select(beans)..where((b) => b.id.equals(id))).getSingleOrNull();
  }

  Future<void> insertBean(BeansCompanion bean) {
    return into(beans).insert(bean);
  }

  Future<void> updateBean(BeansCompanion bean) {
    return (update(
      beans,
    )..where((b) => b.id.equals(bean.id.value))).write(bean);
  }

  Future<void> deleteBean(String id) {
    return (delete(beans)..where((b) => b.id.equals(id))).go();
  }

  Future<List<BeanBatche>> getAllBatches({bool includeArchived = false}) {
    final query = select(beanBatches);
    if (!includeArchived) {
      query.where((b) => b.archived.equals(false));
    }
    query.orderBy([(b) => OrderingTerm.desc(b.updatedAt)]);
    return query.get();
  }

  Future<List<BeanBatche>> getBatchesForBean(
    String beanId, {
    bool includeArchived = false,
  }) {
    final query = select(beanBatches)..where((b) => b.beanId.equals(beanId));
    if (!includeArchived) {
      query.where((b) => b.archived.equals(false));
    }
    query.orderBy([(b) => OrderingTerm.desc(b.updatedAt)]);
    return query.get();
  }

  Stream<List<BeanBatche>> watchBatchesForBean(
    String beanId, {
    bool includeArchived = false,
  }) {
    final query = select(beanBatches)..where((b) => b.beanId.equals(beanId));
    if (!includeArchived) {
      query.where((b) => b.archived.equals(false));
    }
    query.orderBy([(b) => OrderingTerm.desc(b.updatedAt)]);
    return query.watch();
  }

  Future<BeanBatche?> getBatchById(String id) {
    return (select(
      beanBatches,
    )..where((b) => b.id.equals(id))).getSingleOrNull();
  }

  Future<void> insertBatch(BeanBatchesCompanion batch) {
    return into(beanBatches).insert(batch);
  }

  Future<void> updateBatch(BeanBatchesCompanion batch) {
    return (update(
      beanBatches,
    )..where((b) => b.id.equals(batch.id.value))).write(batch);
  }

  Future<void> deleteBatch(String id) {
    return (delete(beanBatches)..where((b) => b.id.equals(id))).go();
  }

  Future<void> decrementBatchWeight(String batchId, double amount) async {
    final batch = await getBatchById(batchId);
    if (batch == null) return;
    final current = batch.weightRemaining ?? batch.weight ?? 0;
    final newWeight = (current - amount).clamp(0.0, double.infinity).toDouble();
    await (update(beanBatches)..where((b) => b.id.equals(batchId))).write(
      BeanBatchesCompanion(
        weightRemaining: Value(newWeight),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }
}
