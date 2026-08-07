import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/storage/kv_store_service.dart';
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
  });
}
