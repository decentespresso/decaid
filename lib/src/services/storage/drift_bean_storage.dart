import 'package:reaprime/src/models/data/bean.dart' as domain;
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/database/mappers/bean_mapper.dart';
import 'package:reaprime/src/services/storage/bean_storage_service.dart';

class DriftBeanStorageService implements BeanStorageService {
  final AppDatabase _db;

  DriftBeanStorageService(this._db);

  @override
  Future<List<domain.Bean>> getAllBeans({bool includeArchived = false}) async {
    final rows = await _db.beanDao.getAllBeans(
      includeArchived: includeArchived,
    );
    return rows.map(BeanMapper.fromRow).toList();
  }

  @override
  Stream<List<domain.Bean>> watchAllBeans({bool includeArchived = false}) {
    return _db.beanDao
        .watchAllBeans(includeArchived: includeArchived)
        .map((rows) => rows.map(BeanMapper.fromRow).toList());
  }

  @override
  Future<domain.Bean?> getBeanById(String id) async {
    final row = await _db.beanDao.getBeanById(id);
    return row == null ? null : BeanMapper.fromRow(row);
  }

  @override
  Future<void> insertBean(domain.Bean bean) {
    return _db.beanDao.insertBean(BeanMapper.toCompanion(bean));
  }

  @override
  Future<void> updateBean(domain.Bean bean) {
    return _db.beanDao.updateBean(BeanMapper.toCompanion(bean));
  }

  @override
  Future<void> deleteBean(String id) {
    return _db.beanDao.deleteBean(id);
  }

  @override
  Future<List<domain.BeanBatch>> getAllBatches({
    bool includeArchived = false,
  }) async {
    final rows = await _db.beanDao.getAllBatches(
      includeArchived: includeArchived,
    );
    return rows.map(BeanMapper.batchFromRow).toList();
  }

  @override
  Future<List<domain.BeanBatch>> getBatchesForBean(
    String beanId, {
    bool includeArchived = false,
  }) async {
    final rows = await _db.beanDao.getBatchesForBean(
      beanId,
      includeArchived: includeArchived,
    );
    return rows.map(BeanMapper.batchFromRow).toList();
  }

  @override
  Stream<List<domain.BeanBatch>> watchBatchesForBean(
    String beanId, {
    bool includeArchived = false,
  }) {
    return _db.beanDao
        .watchBatchesForBean(beanId, includeArchived: includeArchived)
        .map((rows) => rows.map(BeanMapper.batchFromRow).toList());
  }

  @override
  Future<domain.BeanBatch?> getBatchById(String id) async {
    final row = await _db.beanDao.getBatchById(id);
    return row == null ? null : BeanMapper.batchFromRow(row);
  }

  @override
  Future<void> insertBatch(domain.BeanBatch batch) {
    return _db.beanDao.insertBatch(BeanMapper.batchToCompanion(batch));
  }

  @override
  Future<void> updateBatch(domain.BeanBatch batch) {
    return _db.beanDao.updateBatch(BeanMapper.batchToCompanion(batch));
  }

  @override
  Future<void> deleteBatch(String id) {
    return _db.beanDao.deleteBatch(id);
  }

  @override
  Future<void> decrementBatchWeight(String batchId, double amount) {
    return _db.beanDao.decrementBatchWeight(batchId, amount);
  }
}
