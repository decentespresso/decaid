import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/shot_record.dart' as domain;
import 'package:reaprime/src/models/data/workflow.dart' as domain_workflow;
import 'package:reaprime/src/services/database/database.dart';
import 'package:reaprime/src/services/database/mappers/shot_mapper.dart';
import 'package:reaprime/src/services/storage/drift_bean_storage.dart';
import 'package:reaprime/src/services/storage/drift_storage_service.dart';
import 'package:reaprime/src/services/webserver/shots_handler.dart';
import 'package:shelf_plus/shelf_plus.dart';

void main() {
  late AppDatabase db;
  late DriftStorageService storage;
  late PersistenceController persistence;
  late Handler handler;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    storage = DriftStorageService(db);
    persistence = PersistenceController(storageService: storage);
    final app = Router().plus;
    ShotsHandler(
      controller: persistence,
      beanStorage: DriftBeanStorageService(db),
    ).addRoutes(app);
    handler = app.call;
  });

  tearDown(() async {
    persistence.dispose();
    await db.close();
  });

  domain_workflow.Workflow importedWorkflow({
    String title = 'de1app profile',
    List<ProfileStep> steps = const [],
  }) {
    final base = WorkflowController().currentWorkflow;
    return base.copyWith(
      profile: Profile(
        version: '2',
        title: title,
        notes: '',
        author: '',
        beverageType: BeverageType.espresso,
        steps: steps,
        targetVolumeCountStart: 0,
        tankTemperature: 0,
      ),
    );
  }

  Future<void> insertShot(
    String id,
    domain_workflow.Workflow workflow, {
    required DateTime timestamp,
  }) async {
    await db.shotDao.insertShot(
      ShotMapper.toCompanion(
        domain.ShotRecord(
          id: id,
          timestamp: timestamp,
          measurements: const [],
          workflow: workflow,
        ),
      ),
    );
  }

  group('de1app imported shots (gh#784)', () {
    test('a stored profile with no steps reads back', () async {
      await insertShot(
        'de1app-1626149813',
        importedWorkflow(),
        timestamp: DateTime.utc(2021, 7, 13),
      );

      final restored = await storage.getShot('de1app-1626149813');

      expect(restored, isNotNull);
      expect(restored!.workflow.profile.steps, isEmpty);
      expect(restored.workflow.profile.title, 'de1app profile');
    });

    test('a stored profile with no title reads back', () async {
      await insertShot(
        'de1app-1626149814',
        importedWorkflow(title: ''),
        timestamp: DateTime.utc(2021, 7, 13),
      );

      final restored = await storage.getShot('de1app-1626149814');

      expect(restored, isNotNull);
      expect(restored!.workflow.profile.title, isNotEmpty);
    });

    test('one step-less shot does not hide the rest of the history', () async {
      await insertShot(
        'shot-good-1',
        WorkflowController().currentWorkflow,
        timestamp: DateTime.utc(2026, 9, 1),
      );
      await insertShot(
        'de1app-1626149813',
        importedWorkflow(),
        timestamp: DateTime.utc(2021, 7, 13),
      );
      await insertShot(
        'shot-good-2',
        WorkflowController().currentWorkflow,
        timestamp: DateTime.utc(2026, 9, 2),
      );

      final page = await storage.getShotsPaginated(limit: 20);

      expect(page.map((s) => s.id), [
        'shot-good-2',
        'shot-good-1',
        'de1app-1626149813',
      ]);
    });
  });

  group('updating de1app imported shots (gh#784)', () {
    Future<Response> sendPut(String id, Map<String, dynamic> patch) async =>
        handler(
          Request(
            'PUT',
            Uri.parse('http://localhost/api/v1/shots/$id'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode(patch),
          ),
        );

    test('a step-less imported shot accepts an annotation patch', () async {
      await insertShot(
        'de1app-1626149813',
        importedWorkflow(),
        timestamp: DateTime.utc(2021, 7, 13),
      );

      final response = await sendPut('de1app-1626149813', {
        'annotations': {'espressoNotes': 'imported, still editable'},
      });

      expect(response.statusCode, 200);
      final restored = await storage.getShot('de1app-1626149813');
      expect(restored!.annotations?.espressoNotes, 'imported, still editable');
      expect(restored.workflow.profile.steps, isEmpty);
    });

    test('a title-less imported shot accepts an annotation patch', () async {
      await insertShot(
        'de1app-1626149814',
        importedWorkflow(title: ''),
        timestamp: DateTime.utc(2021, 7, 13),
      );

      final response = await sendPut('de1app-1626149814', {
        'annotations': {'espressoNotes': 'no title, still editable'},
      });

      expect(response.statusCode, 200);
      final restored = await storage.getShot('de1app-1626149814');
      expect(restored!.annotations?.espressoNotes, 'no title, still editable');
      expect(restored.workflow.profile.title, Profile.unknownTitle);
    });
  });

  group('unreadable rows', () {
    test('a row that cannot be mapped is skipped, not fatal', () async {
      await insertShot(
        'shot-good-1',
        WorkflowController().currentWorkflow,
        timestamp: DateTime.utc(2026, 9, 1),
      );
      await db
          .into(db.shotRecords)
          .insert(
            ShotRecordsCompanion.insert(
              id: 'shot-corrupt',
              timestamp: DateTime.utc(2026, 9, 2),
              workflowJson: const <String, dynamic>{
                'name': 'no profile at all',
              },
              measurementsJson: jsonEncode(const []),
            ),
          );

      final page = await storage.getShotsPaginated(limit: 20);

      expect(page.map((s) => s.id), ['shot-good-1']);
    });

    test('getShot surfaces the failure for a single unreadable id', () async {
      await db
          .into(db.shotRecords)
          .insert(
            ShotRecordsCompanion.insert(
              id: 'shot-corrupt',
              timestamp: DateTime.utc(2026, 9, 2),
              workflowJson: const <String, dynamic>{
                'name': 'no profile at all',
              },
              measurementsJson: jsonEncode(const []),
            ),
          );

      await expectLater(
        storage.getShot('shot-corrupt'),
        throwsA(isA<Object>()),
      );
    });
  });

  group('the profile library stays strict', () {
    test('Workflow.fromJson still rejects a step-less profile (gh#338)', () {
      final recorded = importedWorkflow().toJson();

      expect(
        () => domain_workflow.Workflow.fromJson(recorded),
        throwsArgumentError,
      );
      expect(
        domain_workflow.Workflow.fromRecordedJson(recorded).profile.steps,
        isEmpty,
      );
    });

    test('Profile.fromJson still rejects an empty steps array', () {
      expect(
        () => Profile.fromJson(const {
          'title': 'no steps',
          'steps': <dynamic>[],
          'tank_temperature': 0,
          'target_volume_count_start': 0,
        }),
        throwsArgumentError,
      );
    });

    test('Profile.fromJson still rejects an empty title', () {
      expect(
        () => Profile.fromJson(const {
          'title': '',
          'steps': [
            {'name': 'preinfusion'},
          ],
          'tank_temperature': 0,
          'target_volume_count_start': 0,
        }),
        throwsArgumentError,
      );
    });
  });
}
