import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/storage/kv_store_service.dart';
import 'package:reaprime/src/services/storage/storage_operation_coordinator.dart';
import 'package:reaprime/src/services/webserver/data_export/data_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export/data_transfer_limits.dart';
import 'package:reaprime/src/services/webserver/data_export/kv_store_export_section.dart';
import 'package:reaprime/src/util/incremental_json_parser.dart';

import 'streaming_test_helpers.dart';

class MockKvStore implements KeyValueStoreService {
  final Map<String, Map<String, Object>> boxes = {};
  final Map<String, int> keyRequests = {};

  @override
  Future<void> initialize() async {}

  @override
  List<String> get namespaces => boxes.keys.toList();

  @override
  Future<Map<String, Object>> getAll({String namespace = "default"}) async =>
      Map.of(boxes[namespace] ?? {});

  @override
  Future<Object?> get({
    String namespace = "default",
    required String key,
  }) async => boxes[namespace]?[key];

  @override
  Future<List<String>> keys({String namespace = "default"}) async {
    keyRequests.update(namespace, (count) => count + 1, ifAbsent: () => 1);
    return (boxes[namespace] ?? {}).keys.toList();
  }

  @override
  Future<void> set({
    String namespace = "default",
    required String key,
    required Object value,
  }) async {
    boxes.putIfAbsent(namespace, () => {})[key] = value;
  }

  @override
  Future<bool> delete({
    String namespace = "default",
    required String key,
  }) async {
    boxes[namespace]?.remove(key);
    return true;
  }
}

void main() {
  group('KvStoreExportSection', () {
    test('exports namespaces and key/value pairs incrementally', () async {
      final store = MockKvStore();
      await store.set(namespace: 'default', key: 'a', value: 1);
      await store.set(namespace: 'default', key: 'b', value: {'nested': true});
      await store.set(namespace: 'plugins', key: 'p', value: 'x');
      await store.set(namespace: 'empty', key: 'k', value: 'v');
      await store.delete(namespace: 'empty', key: 'k');

      final section = KvStoreExportSection(store: store);

      final sink = CapturingJsonSink();
      await section.exportJson(sink);

      final decoded = jsonDecode(sink.json) as Map<String, dynamic>;
      final namespaces = decoded['namespaces'] as Map<String, dynamic>;
      expect(namespaces.keys.toSet(), {'default', 'plugins', 'empty'});
      expect(namespaces['default'], {
        'a': 1,
        'b': {'nested': true},
      });
      expect(namespaces['plugins'], {'p': 'x'});
      expect(store.keyRequests, {'default': 1, 'plugins': 1, 'empty': 1});
    });

    test('round trips a key at the encoded byte limit', () async {
      const limits = DataTransferLimits(maxKeyBytes: 14);
      final source = MockKvStore();
      await source.set(key: '123456789012', value: 'ok');
      final section = KvStoreExportSection(store: source, limits: limits);
      final sink = CapturingJsonSink();

      await section.exportJson(sink);

      final destination = MockKvStore();
      final result = await importSectionJson(
        KvStoreExportSection(store: destination, limits: limits),
        sink.json,
        ConflictStrategy.skip,
        limits: limits,
      );
      expect(result.imported, 1);
      expect(destination.boxes['default']?['123456789012'], 'ok');
    });

    test('rejects a key beyond the encoded byte limit during export', () async {
      const limits = DataTransferLimits(maxKeyBytes: 14);
      final store = MockKvStore();
      await store.set(key: '1234567890123', value: 'too long');
      final section = KvStoreExportSection(store: store, limits: limits);

      await expectLater(
        section.exportJson(CapturingJsonSink()),
        throwsA(isA<StateError>()),
      );
    });

    test('rejects an oversized nested map key during export', () async {
      const limits = DataTransferLimits(maxKeyBytes: 14);
      final store = MockKvStore();
      await store.set(key: 'ok', value: {'1234567890123': 1});
      final section = KvStoreExportSection(store: store, limits: limits);

      await expectLater(
        section.exportJson(CapturingJsonSink()),
        throwsA(isA<JsonStreamFormatException>()),
      );
    });

    test(
      'counts non-BMP key bytes consistently across export and import',
      () async {
        const limits = DataTransferLimits(maxKeyBytes: 14);
        final source = MockKvStore();
        await source.set(key: '😀😀😀', value: 'ok');
        final section = KvStoreExportSection(store: source, limits: limits);
        final sink = CapturingJsonSink();

        await section.exportJson(sink);

        final destination = MockKvStore();
        final result = await importSectionJson(
          KvStoreExportSection(store: destination, limits: limits),
          sink.json,
          ConflictStrategy.skip,
          limits: limits,
        );
        expect(result.imported, 1);
        expect(destination.boxes['default']?['😀😀😀'], 'ok');
      },
    );

    test('imports key/value pairs at depth 3 with skip semantics', () async {
      final store = MockKvStore();
      await store.set(namespace: 'default', key: 'existing', value: 1);
      final section = KvStoreExportSection(store: store);
      final result = await importSectionJson(
        section,
        jsonEncode({
          'namespaces': {
            'default': {'existing': 1, 'new': 2},
            'plugins': {'setting': 'on'},
          },
        }),
        ConflictStrategy.skip,
      );
      expect(result.imported, 2);
      expect(result.skipped, 1);
      expect(store.boxes['default']!['new'], 2);
      expect(store.boxes['plugins']!['setting'], 'on');
    });

    test('rejects malformed payloads without importing', () async {
      final store = MockKvStore();
      final section = KvStoreExportSection(store: store);
      await expectLater(
        importSectionJson(
          section,
          '{"namespaces": {"a": {"k":',
          ConflictStrategy.skip,
        ),
        throwsA(isA<JsonStreamFormatException>()),
      );
      expect(store.boxes, isEmpty);
    });

    for (final invalidJson in [
      '{}',
      '{"namespaces": false}',
      '{"namespaces": tru}',
    ]) {
      test('rejects $invalidJson without importing', () async {
        final store = MockKvStore();
        final section = KvStoreExportSection(store: store);

        await expectLater(
          importSectionJson(section, invalidJson, ConflictStrategy.skip),
          throwsA(isA<JsonStreamFormatException>()),
        );
        expect(store.boxes, isEmpty);
      });
    }

    test('accepts empty namespace objects', () async {
      final store = MockKvStore();
      final section = KvStoreExportSection(store: store);

      final result = await importSectionJson(
        section,
        '{"namespaces":{"empty":{}}}',
        ConflictStrategy.skip,
      );

      expect(result.errors, isEmpty);
      expect(store.boxes, isEmpty);
    });

    group('maintenance boundary', () {
      const limits = StorageOperationLimits(
        operationTimeout: Duration(milliseconds: 50),
        drainTimeout: Duration(milliseconds: 50),
      );
      final backup = jsonEncode({
        'namespaces': {
          'plugin.a': {'k': 'restored'},
        },
      });

      test('restore waits for an outstanding plugin write', () async {
        final store = MockKvStore();
        final coordinator = StorageOperationCoordinator(limits: limits);
        final gate = Completer<void>();
        final write = coordinator.write('plugin.a', 'k', () async {
          await gate.future;
          await store.set(namespace: 'plugin.a', key: 'k', value: 'plugin');
        });
        final section = KvStoreExportSection(
          store: store,
          coordinator: coordinator,
        );

        final restore = importSectionJson(
          section,
          backup,
          ConflictStrategy.overwrite,
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
        gate.complete();
        await write;
        final result = await restore;

        expect(result.imported, 1);
        expect(result.errors, isEmpty);
        expect(store.boxes['plugin.a']!['k'], 'restored');
      });

      test('restore refuses an unresolved quarantined write', () async {
        final store = MockKvStore();
        final coordinator = StorageOperationCoordinator(limits: limits);
        final gate = Completer<void>();
        await expectLater(
          coordinator.write('plugin.a', 'k', () async {
            await gate.future;
            await store.set(namespace: 'plugin.a', key: 'k', value: 'late');
          }),
          throwsA(isA<StorageOperationException>()),
        );
        expect(coordinator.isQuarantined('plugin.a', 'k'), isTrue);
        final section = KvStoreExportSection(
          store: store,
          coordinator: coordinator,
        );

        final result = await importSectionJson(
          section,
          backup,
          ConflictStrategy.overwrite,
        );

        expect(result.imported, 0);
        expect(result.errors, hasLength(1));
        expect(store.boxes['plugin.a'], isNull);
        expect(coordinator.isQuarantined('plugin.a', 'k'), isTrue);

        gate.complete();
        while (coordinator.isQuarantined('plugin.a', 'k')) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        final retry = await importSectionJson(
          section,
          backup,
          ConflictStrategy.overwrite,
        );
        expect(retry.imported, 1);
        expect(store.boxes['plugin.a']!['k'], 'restored');
      });

      test('plugin access is refused while restore runs', () async {
        final store = _BlockingKvStore();
        final coordinator = StorageOperationCoordinator(limits: limits);
        final section = KvStoreExportSection(
          store: store,
          coordinator: coordinator,
        );

        final restore = importSectionJson(
          section,
          backup,
          ConflictStrategy.overwrite,
        );
        await store.setStarted.future;
        await expectLater(
          coordinator.write('plugin.a', 'k', () async {}),
          throwsA(
            isA<StorageOperationException>().having(
              (e) => e.code,
              'code',
              StorageErrorCode.maintenance,
            ),
          ),
        );
        expect(
          await coordinator.read('other', 'k', () async => 'free'),
          'free',
        );
        store.release.complete();
        expect((await restore).imported, 1);
        await coordinator.write('plugin.a', 'k', () async {});
      });
    });
  });
}

class _BlockingKvStore extends MockKvStore {
  final setStarted = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> set({
    String namespace = "default",
    required String key,
    required Object value,
  }) async {
    if (!setStarted.isCompleted) setStarted.complete();
    await release.future;
    await super.set(namespace: namespace, key: key, value: value);
  }
}
