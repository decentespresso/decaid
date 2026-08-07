import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/models/data/bean.dart';
import 'package:reaprime/src/services/storage/bean_storage_service.dart';
import 'package:reaprime/src/services/webserver/data_export/bean_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/data_export_section.dart';
import 'package:reaprime/src/util/incremental_json_parser.dart';

import 'streaming_test_helpers.dart';

class MockBeanStorage implements BeanStorageService {
  final List<Bean> beans = [];
  final List<BeanBatch> batches = [];

  @override
  Future<List<Bean>> getAllBeans({bool includeArchived = false}) async {
    throw StateError('getAllBeans must not be called during streaming export');
  }

  @override
  Stream<List<Bean>> watchAllBeans({bool includeArchived = false}) =>
      const Stream.empty();

  @override
  Future<Bean?> getBeanById(String id) async =>
      beans.where((b) => b.id == id).firstOrNull;

  @override
  Future<void> insertBean(Bean bean) async => beans.add(bean);

  @override
  Future<void> updateBean(Bean bean) async {
    beans.removeWhere((b) => b.id == bean.id);
    beans.add(bean);
  }

  @override
  Future<void> deleteBean(String id) async =>
      beans.removeWhere((b) => b.id == id);

  @override
  Future<List<BeanBatch>> getBatchesForBean(
    String beanId, {
    bool includeArchived = false,
  }) async {
    if (!includeArchived) {
      return batches.where((b) => b.beanId == beanId && !b.archived).toList();
    }
    return batches.where((b) => b.beanId == beanId).toList();
  }

  @override
  Stream<List<BeanBatch>> watchBatchesForBean(
    String beanId, {
    bool includeArchived = false,
  }) => const Stream.empty();

  @override
  Future<BeanBatch?> getBatchById(String id) async =>
      batches.where((b) => b.id == id).firstOrNull;

  @override
  Future<void> insertBatch(BeanBatch batch) async => batches.add(batch);

  @override
  Future<void> updateBatch(BeanBatch batch) async {
    batches.removeWhere((b) => b.id == batch.id);
    batches.add(batch);
  }

  @override
  Future<void> deleteBatch(String id) async =>
      batches.removeWhere((b) => b.id == id);

  @override
  Future<void> decrementBatchWeight(String batchId, double amount) async {}
}

Bean makeBean(int i) => Bean(
  id: 'bean-$i',
  roaster: 'Sey',
  name: 'La Esperanza $i',
  createdAt: DateTime(2024, 1, 1).add(Duration(days: i)),
  updatedAt: DateTime(2024, 1, 1).add(Duration(days: i)),
);

BeanBatch makeBatch(String id, String beanId) => BeanBatch(
  id: id,
  beanId: beanId,
  createdAt: DateTime(2024, 2, 1),
  updatedAt: DateTime(2024, 2, 1),
);

void main() {
  group('BeanExportSection', () {
    test('streams beans with embedded batches in bounded pages', () async {
      final storage = MockBeanStorage();
      final pageSizes = <int>[];
      final section = BeanExportSection(
        storage: storage,
        pageBeans: (limit, {afterTimestamp, afterCreatedAt, afterId}) async {
          pageSizes.add(limit);
          final all = List.generate(150, makeBean)
            ..sort((a, b) {
              final c = a.createdAt.compareTo(b.createdAt);
              return c != 0 ? c : a.id.compareTo(b.id);
            });
          final start = all.indexWhere(
            (b) =>
                afterCreatedAt == null ||
                b.createdAt.isAfter(afterCreatedAt) ||
                (b.createdAt == afterCreatedAt && b.id.compareTo(afterId!) > 0),
          );
          final from = start < 0 ? all.length : start;
          return all.skip(from).take(limit).toList();
        },
        pageSize: 100,
      );
      storage.batches
        ..add(makeBatch('b1', 'bean-0'))
        ..add(makeBatch('b2', 'bean-0'));

      final sink = CapturingJsonSink();
      await section.exportJson(sink);

      expect(pageSizes, [100, 100]);
      final decoded = jsonDecode(sink.json) as List;
      expect(decoded, hasLength(150));
      final first = decoded.first as Map<String, dynamic>;
      expect(first['batches'], hasLength(2));
      expect((first['batches'] as List).first['id'], 'b1');
    });

    test('imports beans and batches with skip/overwrite semantics', () async {
      final storage = MockBeanStorage()
        ..beans.add(makeBean(0))
        ..batches.add(makeBatch('b1', 'bean-0'));
      final section = BeanExportSection(
        storage: storage,
        pageBeans: (limit, {afterTimestamp, afterCreatedAt, afterId}) async =>
            [],
      );

      final bean1 = makeBean(1).toJson();
      final batchFor1 = makeBatch('b2', 'bean-1').toJson();
      final json = jsonEncode([
        makeBean(0).toJson(),
        {
          ...bean1,
          'batches': [batchFor1],
        },
      ]);

      final skip = await importSectionJson(
        section,
        json,
        ConflictStrategy.skip,
      );
      expect(skip.imported, 2);
      expect(skip.skipped, 1);
      expect(storage.beans, hasLength(2));
      expect(storage.batches, hasLength(2));

      final overwrite = await importSectionJson(
        section,
        jsonEncode([
          {...makeBean(0).toJson(), 'batches': <Object?>[]},
        ]),
        ConflictStrategy.overwrite,
      );
      expect(overwrite.imported, 1);
    });

    test('rejects malformed and non-array payloads', () async {
      final storage = MockBeanStorage();
      final section = BeanExportSection(
        storage: storage,
        pageBeans: (limit, {afterTimestamp, afterCreatedAt, afterId}) async =>
            [],
      );
      await expectLater(
        importSectionJson(section, '[{"id":', ConflictStrategy.skip),
        throwsA(isA<JsonStreamFormatException>()),
      );
      final nonArray = await importSectionJson(
        section,
        '{"beans": []}',
        ConflictStrategy.skip,
      );
      expect(nonArray.errors, hasLength(1));
      expect(storage.beans, isEmpty);
    });
  });
}
