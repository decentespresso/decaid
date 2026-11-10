import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/shot_annotations.dart';
import 'package:reaprime/src/models/data/steam_record.dart';
import 'package:reaprime/src/services/database/database.dart' hide SteamRecord;
import 'package:reaprime/src/services/storage/drift_storage_service.dart';
import 'package:reaprime/src/services/webserver/steams_handler.dart';
import 'package:shelf_plus/shelf_plus.dart';

void main() {
  late AppDatabase db;
  late PersistenceController persistence;
  late Handler handler;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    persistence = PersistenceController(
      storageService: DriftStorageService(db),
    );
    final steamsHandler = SteamsHandler(controller: persistence);
    final app = Router().plus;
    steamsHandler.addRoutes(app);
    handler = app.call;
  });

  tearDown(() async {
    persistence.dispose();
    await db.close();
  });

  Future<Response> sendGet(String path) async =>
      handler(Request('GET', Uri.parse('http://localhost$path')));

  Future<Response> sendPut(String path, Map<String, dynamic> body) async =>
      handler(
        Request(
          'PUT',
          Uri.parse('http://localhost$path'),
          body: jsonEncode(body),
          headers: {'content-type': 'application/json'},
        ),
      );

  Future<Response> sendDelete(String path) async =>
      handler(Request('DELETE', Uri.parse('http://localhost$path')));

  SteamRecord makeRecord(String id) => SteamRecord(
    id: id,
    timestamp: DateTime.utc(2026, 5, 18, 12, 0, 0),
    measurements: const [],
    workflow: WorkflowController().currentWorkflow,
  );

  group('SteamsHandler', () {
    test('GET /api/v1/steams returns empty list', () async {
      final response = await sendGet('/api/v1/steams');
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as List;
      expect(body, isEmpty);
    });

    test(
      'GET /api/v1/steams returns persisted records (no measurements)',
      () async {
        await persistence.persistSteam(makeRecord('s1'));
        await persistence.persistSteam(makeRecord('s2'));

        final response = await sendGet('/api/v1/steams');
        expect(response.statusCode, 200);
        final body = jsonDecode(await response.readAsString()) as List;
        expect(body, hasLength(2));
        for (final entry in body) {
          expect(entry, isA<Map>());
          expect((entry as Map).containsKey('measurements'), isFalse);
        }
      },
    );

    test('GET /api/v1/steams/ids returns ids', () async {
      await persistence.persistSteam(makeRecord('s1'));
      final response = await sendGet('/api/v1/steams/ids');
      final body = jsonDecode(await response.readAsString()) as List;
      expect(body, contains('s1'));
    });

    test('GET /api/v1/steams/latest returns the most recent record', () async {
      await persistence.persistSteam(
        makeRecord('s1')
            .copyWith(timestamp: DateTime.utc(2026, 5, 18, 11, 0, 0)),
      );
      await persistence.persistSteam(
        makeRecord('s2')
            .copyWith(timestamp: DateTime.utc(2026, 5, 18, 13, 0, 0)),
      );

      final response = await sendGet('/api/v1/steams/latest');
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['id'], equals('s2'));
    });

    test('GET /api/v1/steams/<id> returns the record', () async {
      await persistence.persistSteam(makeRecord('s1'));
      final response = await sendGet('/api/v1/steams/s1');
      expect(response.statusCode, 200);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['id'], equals('s1'));
    });

    test('GET /api/v1/steams/<id> returns 404 for unknown id', () async {
      final response = await sendGet('/api/v1/steams/nope');
      expect(response.statusCode, 404);
    });

    test('PUT /api/v1/steams/<id> updates annotations', () async {
      await persistence.persistSteam(makeRecord('s1'));
      final response = await sendPut('/api/v1/steams/s1', {
        'annotations': ShotAnnotations(espressoNotes: 'silky').toJson(),
      });
      expect(response.statusCode, 200);
      final body =
          jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(body['annotations']['espressoNotes'], equals('silky'));
    });

    test('DELETE /api/v1/steams/<id> removes the record', () async {
      await persistence.persistSteam(makeRecord('s1'));
      final response = await sendDelete('/api/v1/steams/s1');
      expect(response.statusCode, 200);
      final after = await sendGet('/api/v1/steams/s1');
      expect(after.statusCode, 404);
    });
  });
}
