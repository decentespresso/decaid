import 'package:reaprime/src/models/data/bean.dart';

abstract class BeanStorageService {
  Future<List<Bean>> getAllBeans({bool includeArchived = false});
  Stream<List<Bean>> watchAllBeans({bool includeArchived = false});
  Future<Bean?> getBeanById(String id);
  Future<void> insertBean(Bean bean);
  Future<void> updateBean(Bean bean);
  Future<void> deleteBean(String id);

  Future<List<BeanBatch>> getBatchesForBean(
    String beanId, {
    bool includeArchived = false,
  });
  Stream<List<BeanBatch>> watchBatchesForBean(
    String beanId, {
    bool includeArchived = false,
  });
  Future<BeanBatch?> getBatchById(String id);
  Future<void> insertBatch(BeanBatch batch);
  Future<void> updateBatch(BeanBatch batch);
  Future<void> deleteBatch(String id);
  Future<void> decrementBatchWeight(String batchId, double amount);
}
