import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:reaprime/src/services/storage/hive_store_service.dart';

void main() {
  late HiveStoreService store;

  setUp(() async {
    Hive.init('./test_hive_data_export');
    store = HiveStoreService(defaultNamespace: 'testKvStore');
    await store.initialize();
  });

  tearDown(() async {
    await Hive.close();
    await Hive.deleteFromDisk();
  });

  group('namespaces', () {
    test('returns default namespace after initialization', () async {
      final ns = store.namespaces;
      expect(ns, contains('testKvStore'));
    });

    test('includes namespaces created by set()', () async {
      await store.set(namespace: 'pluginData', key: 'k1', value: 'v1');
      final ns = store.namespaces;
      expect(ns, contains('pluginData'));
    });
  });

  test('registers Flutter type adapters for Hive.init-based startup', () {
    ensureFlutterTypeAdaptersRegistered();
    expect(Hive.isAdapterRegistered(200), isTrue);
    expect(Hive.isAdapterRegistered(201), isTrue);
  });

  group('getAll', () {
    test('returns all key-value pairs in a namespace', () async {
      await store.set(key: 'a', value: 'alpha');
      await store.set(key: 'b', value: 'beta');
      final all = await store.getAll();
      expect(all, {'a': 'alpha', 'b': 'beta'});
    });

    test('returns empty map for empty namespace', () async {
      await store.set(namespace: 'empty', key: 'temp', value: '1');
      await store.delete(namespace: 'empty', key: 'temp');
      final all = await store.getAll(namespace: 'empty');
      expect(all, isEmpty);
    });
  });
}
