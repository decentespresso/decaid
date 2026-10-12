import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/import/de1app_importer.dart';
import 'package:reaprime/src/import/import_result.dart';
import 'package:reaprime/src/import/parsers/shot_v2_json_parser.dart';
import 'package:reaprime/src/models/data/bean.dart';
import 'package:reaprime/src/models/data/grinder.dart';
import 'package:reaprime/src/models/data/profile.dart';
import 'package:reaprime/src/models/data/profile_record.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/models/data/steam_record.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/data/workflow_context.dart';
import 'package:reaprime/src/models/wake_schedule.dart';
import 'package:reaprime/src/services/storage/bean_storage_service.dart';
import 'package:reaprime/src/services/storage/grinder_storage_service.dart';
import 'package:reaprime/src/services/storage/profile_storage_service.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';
import 'package:reaprime/src/settings/charging_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/scale_power_mode.dart';

import '../helpers/mock_settings_service.dart';

class FakeStorageService implements StorageService {
  final shots = <String, ShotRecord>{};
  final failedIds = <String>{};
  final List<String> _existingIds;
  Workflow? _currentWorkflow;

  FakeStorageService({List<String>? existingIds, Workflow? currentWorkflow})
    : _existingIds = existingIds ?? [],
      _currentWorkflow = currentWorkflow;

  @override
  Future<void> storeShot(ShotRecord record) async {
    if (failedIds.contains(record.id)) throw StateError('write failed');
    shots[record.id] = record;
  }

  @override
  Future<List<String>> getShotIds() async => List.unmodifiable(_existingIds);

  @override
  Future<void> updateShot(ShotRecord record) => throw UnimplementedError();
  @override
  Future<void> deleteShot(String id) => throw UnimplementedError();
  @override
  Future<List<ShotRecord>> getAllShots() => throw UnimplementedError();
  @override
  Future<ShotRecord?> getShot(String id) => throw UnimplementedError();
  @override
  Future<void> storeCurrentWorkflow(Workflow workflow) async =>
      _currentWorkflow = workflow;
  @override
  Future<Workflow?> loadCurrentWorkflow() async => _currentWorkflow;
  @override
  Future<List<ShotRecord>> getShotsPaginated({
    int limit = 20,
    int offset = 0,
    String? grinderId,
    String? grinderModel,
    String? beanBatchId,
    List<String>? beanBatchIds,
    String? coffeeName,
    String? coffeeRoaster,
    String? profileTitle,
    String? search,
    bool ascending = false,
  }) => throw UnimplementedError();
  @override
  Future<int> countShots({
    String? grinderId,
    String? grinderModel,
    String? beanBatchId,
    List<String>? beanBatchIds,
    String? coffeeName,
    String? coffeeRoaster,
    String? profileTitle,
    String? search,
    bool ascending = false,
  }) => throw UnimplementedError();
  @override
  Future<ShotRecord?> getLatestShot() => throw UnimplementedError();
  @override
  Future<ShotRecord?> getLatestShotMeta() => throw UnimplementedError();

  @override
  Future<void> storeSteam(SteamRecord record) async {}
  @override
  Future<void> updateSteam(SteamRecord record) async {}
  @override
  Future<void> deleteSteam(String id) async {}
  @override
  Future<List<String>> getSteamIds() async => [];
  @override
  Future<List<SteamRecord>> getAllSteams() async => [];
  @override
  Future<SteamRecord?> getSteam(String id) async => null;
  @override
  Future<SteamRecord?> getLatestSteam() async => null;
  @override
  Future<SteamRecord?> getLatestSteamMeta() async => null;
}

class FakeProfileStorageService implements ProfileStorageService {
  final profiles = <String, ProfileRecord>{};

  @override
  Future<void> store(ProfileRecord record) async =>
      profiles[record.id] = record;

  @override
  Future<ProfileRecord?> get(String id) async => profiles[id];

  @override
  Future<void> initialize() async {}

  @override
  Future<List<ProfileRecord>> getAll({Visibility? visibility}) async =>
      profiles.values.toList();

  @override
  Future<void> update(ProfileRecord record) async =>
      profiles[record.id] = record;

  @override
  Future<void> replace(String oldId, ProfileRecord replacement) async {
    profiles[replacement.id] = replacement;
    profiles.remove(oldId);
  }

  @override
  Future<void> delete(String id) async => profiles.remove(id);

  @override
  Future<bool> exists(String id) async => profiles.containsKey(id);

  @override
  Future<List<String>> getAllIds() async => profiles.keys.toList();

  @override
  Future<List<ProfileRecord>> getByParentId(String parentId) async => [];

  @override
  Future<void> storeAll(List<ProfileRecord> records) async {
    for (final r in records) {
      profiles[r.id] = r;
    }
  }

  @override
  Future<void> clear() async => profiles.clear();

  @override
  Future<int> count({Visibility? visibility}) async => profiles.length;
}

class FakeBeanStorageService implements BeanStorageService {
  final beans = <String, Bean>{};
  final batches = <String, BeanBatch>{};
  final failedBeanNames = <String>{};
  final failedBatchBeanNames = <String>{};

  @override
  Future<void> insertBean(Bean bean) async {
    if (failedBeanNames.contains(bean.name)) {
      throw StateError('bean write failed');
    }
    beans[bean.id] = bean;
  }

  @override
  Future<void> insertBatch(BeanBatch batch) async {
    final bean = beans[batch.beanId];
    if (failedBatchBeanNames.contains(bean?.name)) {
      throw StateError('batch write failed');
    }
    batches[batch.id] = batch;
  }

  @override
  Future<List<Bean>> getAllBeans({bool includeArchived = false}) async =>
      beans.values.toList();

  @override
  Stream<List<Bean>> watchAllBeans({bool includeArchived = false}) =>
      throw UnimplementedError();

  @override
  Future<Bean?> getBeanById(String id) async => beans[id];

  @override
  Future<void> updateBean(Bean bean) async => beans[bean.id] = bean;

  @override
  Future<void> deleteBean(String id) async => beans.remove(id);

  @override
  Future<List<BeanBatch>> getAllBatches({bool includeArchived = false}) async =>
      includeArchived
      ? batches.values.toList()
      : batches.values.where((batch) => !batch.archived).toList();

  @override
  Future<List<BeanBatch>> getBatchesForBean(
    String beanId, {
    bool includeArchived = false,
  }) async => batches.values.where((b) => b.beanId == beanId).toList();

  @override
  Stream<List<BeanBatch>> watchBatchesForBean(
    String beanId, {
    bool includeArchived = false,
  }) => throw UnimplementedError();

  @override
  Future<BeanBatch?> getBatchById(String id) async => batches[id];

  @override
  Future<void> updateBatch(BeanBatch batch) async => batches[batch.id] = batch;

  @override
  Future<void> deleteBatch(String id) async => batches.remove(id);

  @override
  Future<void> decrementBatchWeight(String batchId, double amount) =>
      throw UnimplementedError();
}

class FakeGrinderStorageService implements GrinderStorageService {
  final grinders = <String, Grinder>{};
  final failedModels = <String>{};

  @override
  Future<void> insertGrinder(Grinder grinder) async {
    if (failedModels.contains(grinder.model)) {
      throw StateError('grinder write failed');
    }
    grinders[grinder.id] = grinder;
  }

  @override
  Future<List<Grinder>> getAllGrinders({bool includeArchived = false}) async =>
      grinders.values.toList();

  @override
  Stream<List<Grinder>> watchAllGrinders({bool includeArchived = false}) =>
      throw UnimplementedError();

  @override
  Future<Grinder?> getGrinderById(String id) async => grinders[id];

  @override
  Future<void> updateGrinder(Grinder grinder) async =>
      grinders[grinder.id] = grinder;

  @override
  Future<void> deleteGrinder(String id) async => grinders.remove(id);
}

De1appImporter makeImporter({
  FakeStorageService? storage,
  PersistenceController? controller,
  FakeProfileStorageService? profileStorage,
  FakeBeanStorageService? beanStorage,
  FakeGrinderStorageService? grinderStorage,
  SettingsController? settingsController,
  ParsedShot Function(Map<String, dynamic>) parseV2Shot =
      ShotV2JsonParser.parse,
}) {
  return De1appImporter(
    controller:
        controller ??
        PersistenceController(storageService: storage ?? FakeStorageService()),
    profileStorageService: profileStorage ?? FakeProfileStorageService(),
    beanStorageService: beanStorage ?? FakeBeanStorageService(),
    grinderStorageService: grinderStorage ?? FakeGrinderStorageService(),
    settingsController: settingsController,
    parseV2Shot: parseV2Shot,
  );
}

const _fixturesPath = 'test/fixtures/de1app';

Future<String?> _importShotSources({
  required bool includeLegacy,
  required bool includeV2,
  DateTime? legacyModified,
  DateTime? v2Modified,
}) async {
  final tempDir = await Directory.systemTemp.createTemp('de1app_merge_');
  try {
    if (includeLegacy) {
      final directory = Directory('${tempDir.path}/history');
      await directory.create();
      final file = await File(
        '$_fixturesPath/history/20231108T091544.shot',
      ).copy('${directory.path}/same-basename.shot');
      if (legacyModified != null) await file.setLastModified(legacyModified);
    }
    if (includeV2) {
      final directory = Directory('${tempDir.path}/history_v2');
      await directory.create();
      final file = await File(
        '$_fixturesPath/history_v2/20240315T143022.json',
      ).copy('${directory.path}/same-basename.json');
      if (v2Modified != null) await file.setLastModified(v2Modified);
    }

    final storage = FakeStorageService();
    await makeImporter(storage: storage).import(
      ScanResult(
        shotCount: 1,
        profileCount: 0,
        hasDyeGrinders: false,
        hasSettings: false,
        sourcePath: tempDir.path,
        shotSource: 'both',
      ),
    );
    return storage.shots.values.single.workflow.context?.grinderModel;
  } finally {
    await tempDir.delete(recursive: true);
  }
}

Future<ImportResult> importEntityShots({
  required FakeStorageService storage,
  required FakeBeanStorageService beans,
  required FakeGrinderStorageService grinders,
  List<Map<String, dynamic>> identities = const [{}],
  String? dye,
  WorkflowContext? inputContext,
}) async {
  final directory = await Directory.systemTemp.createTemp('de1app_entities_');
  try {
    await Directory('${directory.path}/history_v2').create();
    final fixture =
        jsonDecode(
              await File(
                '$_fixturesPath/history_v2/20240315T143022.json',
              ).readAsString(),
            )
            as Map<String, dynamic>;
    for (var i = 0; i < identities.length; i++) {
      final identity = identities[i];
      final meta = fixture['meta'] as Map<String, dynamic>;
      final shot = {
        ...fixture,
        'clock': 1710510622 + i,
        'app': <String, dynamic>{},
        'meta': {
          ...meta,
          'bean': {...meta['bean'] as Map<String, dynamic>, ...identity},
          'grinder': {
            ...meta['grinder'] as Map<String, dynamic>,
            'model': identity['model'] ?? 'Niche Zero',
          },
        },
      };
      await File(
        '${directory.path}/history_v2/$i.json',
      ).writeAsString(jsonEncode(shot));
    }
    if (dye != null) {
      await Directory('${directory.path}/plugins/DYE').create(recursive: true);
      await File(
        '${directory.path}/plugins/DYE/grinders.tdb',
      ).writeAsString(dye);
    }
    return await makeImporter(
      storage: storage,
      beanStorage: beans,
      grinderStorage: grinders,
      parseV2Shot: (json) {
        final parsed = ShotV2JsonParser.parse(json);
        if (inputContext == null) return parsed;
        return ParsedShot(
          shot: parsed.shot.copyWith(
            workflow: parsed.shot.workflow.copyWith(context: inputContext),
          ),
          beanBrand: parsed.beanBrand,
          beanType: parsed.beanType,
          beanNotes: parsed.beanNotes,
          roastDate: parsed.roastDate,
          roastLevel: parsed.roastLevel,
          grinderModel: parsed.grinderModel,
          grinderSetting: parsed.grinderSetting,
        );
      },
    ).import(
      ScanResult(
        shotCount: identities.length,
        profileCount: 0,
        hasDyeGrinders: dye != null,
        hasSettings: false,
        sourcePath: directory.path,
        shotSource: 'history_v2',
      ),
    );
  } finally {
    await directory.delete(recursive: true);
  }
}

Future<void> expectResolvedReferences(
  FakeStorageService storage,
  FakeBeanStorageService beans,
  FakeGrinderStorageService grinders,
) async {
  expect(storage.shots, isNotEmpty);
  for (final shot in storage.shots.values) {
    final context = shot.workflow.context!;
    if (context.beanBatchId != null) {
      final batch = await beans.getBatchById(context.beanBatchId!);
      expect(batch, isNotNull, reason: 'unresolved batch on ${shot.id}');
      expect(await beans.getBeanById(batch!.beanId), isNotNull);
    }
    if (context.grinderId != null) {
      expect(
        await grinders.getGrinderById(context.grinderId!),
        isNotNull,
        reason: 'unresolved grinder on ${shot.id}',
      );
    }
  }
}

void main() {
  group('De1appImporter', () {
    group('reconciles stored entity references', () {
      for (final resolved in ['neither', 'batch', 'grinder']) {
        test('replaces stale IDs when $resolved resolves', () async {
          final storage = FakeStorageService();
          final beans = FakeBeanStorageService();
          final grinders = FakeGrinderStorageService();
          const inputContext = WorkflowContext(
            beanBatchId: 'stale-batch',
            grinderId: 'stale-grinder',
            targetDoseWeight: 18,
            targetYield: 36,
            targetWaterVolume: 55,
            grinderModel: 'Original grinder',
            grinderBurrs: 'Original burrs',
            grinderSetting: '12',
            coffeeName: 'Original coffee',
            coffeeRoaster: 'Original roaster',
            finalBeverageType: 'espresso',
            baristaName: 'Barista',
            drinkerName: 'Drinker',
            extras: {'source': 'original'},
          );
          final bean = Bean.create(
            roaster: 'Banibeans',
            name: 'Ethiopia Yirgacheffe',
          );
          final batch = BeanBatch.create(
            beanId: bean.id,
            roastDate: DateTime(2024, 3, 1),
          );
          final grinder = Grinder.create(model: 'Niche Zero');
          if (resolved == 'batch') {
            await beans.insertBean(bean);
            await beans.insertBatch(batch);
          } else {
            beans.failedBatchBeanNames.add(bean.name);
          }
          if (resolved == 'grinder') {
            await grinders.insertGrinder(grinder);
          } else {
            grinders.failedModels.add(grinder.model);
          }
          final result = await importEntityShots(
            storage: storage,
            beans: beans,
            grinders: grinders,
            inputContext: inputContext,
          );
          expect(result.shotsImported, 1);
          expect(result.errors, hasLength(resolved == 'neither' ? 2 : 1));
          final context = storage.shots.values.single.workflow.context!;
          expect(context.beanBatchId, resolved == 'batch' ? batch.id : isNull);
          expect(
            context.grinderId,
            resolved == 'grinder' ? grinder.id : isNull,
          );
          final expected = inputContext.toJson()
            ..remove('beanBatchId')
            ..remove('grinderId');
          if (resolved == 'batch') expected['beanBatchId'] = batch.id;
          if (resolved == 'grinder') expected['grinderId'] = grinder.id;
          expect(context.toJson(), expected);
          await expectResolvedReferences(storage, beans, grinders);
        });
      }

      for (final variant in [
        'exact',
        'incoming whitespace',
        'stored whitespace',
        'case',
      ]) {
        test('reuses persisted IDs for $variant identities', () async {
          final storage = FakeStorageService();
          final beans = FakeBeanStorageService();
          final grinders = FakeGrinderStorageService();
          String value(String text, bool incoming) {
            if (variant == 'case' && incoming) return text.toUpperCase();
            if (variant ==
                (incoming ? 'incoming whitespace' : 'stored whitespace')) {
              return '  $text  ';
            }
            return text;
          }

          final bean = Bean.create(
            roaster: value('Banibeans', false),
            name: value('Ethiopia Yirgacheffe', false),
          );
          final batch = BeanBatch.create(
            beanId: bean.id,
            roastDate: DateTime(2024, 3, 1),
          );
          final grinder = Grinder.create(model: value('Niche Zero', false));
          await beans.insertBean(bean);
          await beans.insertBatch(batch);
          await grinders.insertGrinder(grinder);
          final result = await importEntityShots(
            storage: storage,
            beans: beans,
            grinders: grinders,
            identities: [
              {
                'brand': value('Banibeans', true),
                'type': value('Ethiopia Yirgacheffe', true),
                'model': value('Niche Zero', true),
              },
            ],
          );
          expect(result.errors, isEmpty);
          expect(result.beansCreated, 0);
          expect(result.beansSkipped, 1);
          expect(result.grindersCreated, 0);
          expect(result.grindersSkipped, 1);
          expect(beans.beans, hasLength(1));
          expect(beans.batches, hasLength(1));
          expect(grinders.grinders, hasLength(1));
          final context = storage.shots.values.single.workflow.context!;
          expect(context.beanBatchId, batch.id);
          expect(context.grinderId, grinder.id);
          await expectResolvedReferences(storage, beans, grinders);
        });
      }

      for (final entity in ['Bean', 'BeanBatch', 'Grinder']) {
        test(
          '$entity insert failure is reported without dangling references',
          () async {
            final storage = FakeStorageService();
            final beans = FakeBeanStorageService();
            final grinders = FakeGrinderStorageService();
            if (entity == 'Bean') {
              beans.failedBeanNames.add('Ethiopia Yirgacheffe');
            }
            if (entity == 'BeanBatch') {
              beans.failedBatchBeanNames.add('Ethiopia Yirgacheffe');
            }
            if (entity == 'Grinder') grinders.failedModels.add('Niche Zero');
            final result = await importEntityShots(
              storage: storage,
              beans: beans,
              grinders: grinders,
              identities: [
                {},
                {
                  'brand': 'Other Roaster',
                  'type': 'Other Bean',
                  'model': 'Other Grinder',
                },
              ],
            );
            expect(result.shotsImported, 2);
            final failedContext =
                storage.shots['de1app-1710510622']!.workflow.context!;
            if (entity == 'Grinder') {
              expect(failedContext.grinderId, isNull);
              expect(failedContext.beanBatchId, isNotNull);
            } else {
              expect(failedContext.beanBatchId, isNull);
              expect(failedContext.grinderId, isNotNull);
            }
            final otherContext =
                storage.shots['de1app-1710510623']!.workflow.context!;
            expect(otherContext.beanBatchId, isNotNull);
            expect(otherContext.grinderId, isNotNull);
            await expectResolvedReferences(storage, beans, grinders);
            expect(result.hasErrors, isTrue);
            expect(result.errors, hasLength(1));
            expect(result.errors.single.reason, contains(entity));
            expect(
              result.errors.single.filename,
              contains(
                entity == 'Grinder' ? 'Niche Zero' : 'Ethiopia Yirgacheffe',
              ),
            );
            expect(result.errors.single.details, contains('write failed'));
            if (entity == 'Bean') expect(beans.batches, hasLength(1));
          },
        );
      }

      test(
        'DYE enriches linked grinders and imports DYE-only presets',
        () async {
          final storage = FakeStorageService();
          final beans = FakeBeanStorageService();
          final grinders = FakeGrinderStorageService();
          final result = await importEntityShots(
            storage: storage,
            beans: beans,
            grinders: grinders,
            dye: await File(
              '$_fixturesPath/plugins/DYE/grinders.tdb',
            ).readAsString(),
          );
          expect(result.errors, isEmpty);
          final linked = await grinders.getGrinderById(
            storage.shots.values.single.workflow.context!.grinderId!,
          );
          expect(linked!.model, 'Niche Zero');
          expect(linked.settingType, GrinderSettingType.numeric);
          expect(linked.settingSmallStep, 1);
          expect(linked.settingBigStep, 10);
          final preset = grinders.grinders.values.singleWhere(
            (g) => g.model == 'Baratza Encore',
          );
          expect(preset.settingType, GrinderSettingType.preset);
          expect(preset.settingValues, ['Coarse', 'Fine', 'Medium']);
          expect(preset.settingBigStep, 5);
          expect(
            grinders.grinders.values.any((g) => g.model == 'EK43'),
            isTrue,
          );
          await expectResolvedReferences(storage, beans, grinders);
        },
      );
    });

    test(
      'DYE preset merge matches case variants and keeps unmatched shot grinders',
      () async {
        final storage = FakeStorageService();
        final beans = FakeBeanStorageService();
        final grinders = FakeGrinderStorageService();
        final result = await importEntityShots(
          storage: storage,
          beans: beans,
          grinders: grinders,
          identities: [
            {'model': 'baratza encore'},
            {'model': 'Unknown Grinder'},
          ],
          dye:
              'Baratza\\ Encore {is_numeric 0 default Medium big_step 5 values {Coarse Fine Medium}}',
        );
        expect(result.errors, isEmpty);
        expect(grinders.grinders, hasLength(2));
        final context = storage.shots['de1app-1710510622']!.workflow.context!;
        final preset = await grinders.getGrinderById(context.grinderId!);
        expect(preset!.model, 'baratza encore');
        expect(preset.settingType, GrinderSettingType.preset);
        expect(preset.settingValues, ['Coarse', 'Fine', 'Medium']);
        expect(preset.settingBigStep, 5);
        expect(
          grinders.grinders.values.any((g) => g.model == 'Unknown Grinder'),
          isTrue,
        );
        await expectResolvedReferences(storage, beans, grinders);
      },
    );

    group('selects shots sharing a basename by modification time', () {
      final older = DateTime.utc(2024, 1, 1);
      final newer = DateTime.utc(2024, 2, 1);

      test('a newer legacy shot wins', () async {
        expect(
          await _importShotSources(
            includeLegacy: true,
            includeV2: true,
            legacyModified: newer,
            v2Modified: older,
          ),
          equals('Eureka Mignon'),
        );
      });

      test('a newer v2 shot wins', () async {
        expect(
          await _importShotSources(
            includeLegacy: true,
            includeV2: true,
            legacyModified: older,
            v2Modified: newer,
          ),
          equals('Niche Zero'),
        );
      });

      test('v2 wins when shot modification times are equal', () async {
        expect(
          await _importShotSources(
            includeLegacy: true,
            includeV2: true,
            legacyModified: older,
            v2Modified: older,
          ),
          equals('Niche Zero'),
        );
      });

      test('legacy-only and v2-only shots still import', () async {
        expect(
          await _importShotSources(includeLegacy: true, includeV2: false),
          equals('Eureka Mignon'),
        );
        expect(
          await _importShotSources(includeLegacy: false, includeV2: true),
          equals('Niche Zero'),
        );
      });
    });

    test('profiles keep preferring v2 when legacy profile is newer', () async {
      final tempDir = await Directory.systemTemp.createTemp(
        'de1app_profile_merge_',
      );
      try {
        final legacyDirectory = Directory('${tempDir.path}/profiles');
        final v2Directory = Directory('${tempDir.path}/profiles_v2');
        await legacyDirectory.create();
        await v2Directory.create();
        final legacy = await File(
          '$_fixturesPath/profiles/legacy_lever.tcl',
        ).copy('${legacyDirectory.path}/same-basename.tcl');
        final v2 = await File(
          '$_fixturesPath/profiles_v2/best_practice.json',
        ).copy('${v2Directory.path}/same-basename.json');
        await legacy.setLastModified(DateTime.utc(2024, 2, 1));
        await v2.setLastModified(DateTime.utc(2024, 1, 1));

        final profileStorage = FakeProfileStorageService();
        await makeImporter(profileStorage: profileStorage).import(
          ScanResult(
            shotCount: 0,
            profileCount: 1,
            hasDyeGrinders: false,
            hasSettings: false,
            sourcePath: tempDir.path,
            shotSource: null,
          ),
        );

        expect(
          profileStorage.profiles.values.single.profile.title,
          'Londinium',
        );
      } finally {
        await tempDir.delete(recursive: true);
      }
    });

    group('imports shots merged from history and history_v2', () {
      late FakeStorageService storage;
      late ImportResult result;

      setUpAll(() async {
        storage = FakeStorageService();
        final scanResult = ScanResult(
          shotCount: 2,
          profileCount: 2,
          hasDyeGrinders: true,
          hasSettings: false,
          sourcePath: _fixturesPath,
          shotSource: 'both',
        );
        result = await makeImporter(storage: storage).import(scanResult);
      });

      test('imports both the legacy and v2 shot', () {
        expect(result.shotsImported, equals(2));
      });

      test('both shots are stored in storage service', () {
        expect(storage.shots, hasLength(2));
      });

      test('no shots skipped', () {
        expect(result.shotsSkipped, equals(0));
      });
    });

    group('imports profiles merged from profiles and profiles_v2', () {
      late FakeProfileStorageService profileStorage;
      late ImportResult result;

      setUpAll(() async {
        profileStorage = FakeProfileStorageService();
        final scanResult = ScanResult(
          shotCount: 0,
          profileCount: 2,
          hasDyeGrinders: false,
          hasSettings: false,
          sourcePath: _fixturesPath,
          shotSource: null,
        );
        result = await makeImporter(
          profileStorage: profileStorage,
        ).import(scanResult);
      });

      test('imports both the legacy and v2 profile', () {
        expect(result.profilesImported, equals(2));
      });

      test('both profiles are stored in profile storage service', () {
        expect(profileStorage.profiles, hasLength(2));
      });

      test('the legacy .tcl-only profile was parsed and stored', () {
        expect(
          profileStorage.profiles.values.any(
            (record) => record.profile.title == 'Legacy Lever',
          ),
          isTrue,
        );
      });

      test('no profiles skipped', () {
        expect(result.profilesSkipped, equals(0));
      });
    });

    group('creates bean and grinder entities', () {
      late FakeBeanStorageService beanStorage;
      late FakeGrinderStorageService grinderStorage;
      late ImportResult result;

      setUpAll(() async {
        beanStorage = FakeBeanStorageService();
        grinderStorage = FakeGrinderStorageService();
        final scanResult = ScanResult(
          shotCount: 1,
          profileCount: 0,
          hasDyeGrinders: false,
          hasSettings: false,
          sourcePath: _fixturesPath,
          shotSource: 'history_v2',
        );
        result = await makeImporter(
          beanStorage: beanStorage,
          grinderStorage: grinderStorage,
        ).import(scanResult);
      });

      test('creates at least one bean', () {
        expect(result.beansCreated, greaterThan(0));
        expect(beanStorage.beans, isNotEmpty);
      });

      test('creates at least one bean batch', () {
        expect(beanStorage.batches, isNotEmpty);
      });

      test('creates at least one grinder', () {
        expect(result.grindersCreated, greaterThan(0));
        expect(grinderStorage.grinders, isNotEmpty);
      });
    });

    group('skips duplicate shots', () {
      late FakeStorageService storage;
      late ImportResult result;

      setUpAll(() async {
        storage = FakeStorageService(existingIds: ['de1app-1710510622']);
        final scanResult = ScanResult(
          shotCount: 2,
          profileCount: 0,
          hasDyeGrinders: false,
          hasSettings: false,
          sourcePath: _fixturesPath,
          shotSource: 'both',
        );
        result = await makeImporter(storage: storage).import(scanResult);
      });

      test('skips the duplicate shot', () {
        expect(result.shotsSkipped, equals(1));
      });

      test('imports the shot that was not already present', () {
        expect(result.shotsImported, equals(1));
      });

      test('only the new shot is written to storage', () {
        expect(storage.shots, hasLength(1));
        expect(storage.shots.containsKey('de1app-1699432544'), isTrue);
      });
    });

    group('continues on parse errors', () {
      late Directory tempDir;
      late ImportResult result;

      setUpAll(() async {
        tempDir = await Directory.systemTemp.createTemp('de1app_importer_err_');

        final validFile = File(
          '$_fixturesPath/history_v2/20240315T143022.json',
        );
        final historyV2 = Directory('${tempDir.path}/history_v2');
        await historyV2.create();
        await validFile.copy('${tempDir.path}/history_v2/valid.json');

        await File(
          '${tempDir.path}/history_v2/bad.json',
        ).writeAsString('THIS IS NOT JSON {{{');

        final scanResult = ScanResult(
          shotCount: 2,
          profileCount: 0,
          hasDyeGrinders: false,
          hasSettings: false,
          sourcePath: tempDir.path,
          shotSource: 'history_v2',
        );

        result = await makeImporter().import(scanResult);
      });

      tearDownAll(() async {
        await tempDir.delete(recursive: true);
      });

      test('records an error for the bad file', () {
        expect(result.errors, hasLength(1));
        expect(result.errors.first.filename, equals('bad.json'));
      });

      test('still imports the valid shot', () {
        expect(result.shotsImported, equals(1));
      });
    });

    group('fires progress callbacks', () {
      test('fires shot progress callbacks', () async {
        final progressEvents = <ImportProgress>[];
        final scanResult = ScanResult(
          shotCount: 2,
          profileCount: 0,
          hasDyeGrinders: false,
          hasSettings: false,
          sourcePath: _fixturesPath,
          shotSource: 'both',
        );

        await makeImporter().import(scanResult, onProgress: progressEvents.add);

        final shotEvents = progressEvents.where((e) => e.phase == 'shots');
        expect(shotEvents, isNotEmpty);
        expect(shotEvents.last.current, equals(2));
        expect(shotEvents.last.total, equals(2));
      });

      test('fires profile progress callbacks', () async {
        final progressEvents = <ImportProgress>[];
        final scanResult = ScanResult(
          shotCount: 0,
          profileCount: 2,
          hasDyeGrinders: false,
          hasSettings: false,
          sourcePath: _fixturesPath,
          shotSource: null,
        );

        await makeImporter().import(scanResult, onProgress: progressEvents.add);

        final profileEvents = progressEvents.where(
          (e) => e.phase == 'profiles',
        );
        expect(profileEvents, isNotEmpty);
        expect(profileEvents.last.current, equals(2));
        expect(profileEvents.last.total, equals(2));
      });
    });

    group('merges DYE grinder specs when available', () {
      late FakeGrinderStorageService grinderStorage;
      late ImportResult result;

      setUpAll(() async {
        grinderStorage = FakeGrinderStorageService();
        final scanResult = ScanResult(
          shotCount: 1,
          profileCount: 0,
          hasDyeGrinders: true,
          hasSettings: false,
          sourcePath: _fixturesPath,
          shotSource: 'history_v2',
        );
        result = await makeImporter(
          grinderStorage: grinderStorage,
        ).import(scanResult);
      });

      test('stores grinders after DYE merge', () {
        expect(grinderStorage.grinders, isNotEmpty);
        expect(result.grindersCreated, greaterThan(0));
      });
    });

    group('imports settings from settings.tdb', () {
      late Directory tempDir;
      late FakeStorageService storage;
      late MockSettingsService mockSettingsService;
      late SettingsController settingsController;
      late ImportResult result;

      setUpAll(() async {
        tempDir = await Directory.systemTemp.createTemp(
          'de1app_importer_settings_',
        );

        await File('${tempDir.path}/settings.tdb').writeAsString(
          'scheduler_enable 1\n'
          'scheduler_wake 25200\n'
          'scheduler_sleep 28800\n'
          'keep_scale_on 1\n'
          'screen_saver_delay 30\n'
          'grinder_dose_weight 18.5\n'
          'final_desired_shot_weight_advanced 36.0\n'
          'grinder_model {Niche Zero}\n'
          'grinder_setting 22\n'
          'steam_temperature 155\n'
          'steam_max_time 60\n'
          'water_temperature 80\n'
          'water_volume 200\n'
          'flush_flow 4.5\n'
          'flush_seconds 8\n'
          'smart_battery_charging 2\n',
        );

        final initialWorkflow = Workflow(
          id: 'test-workflow',
          name: 'Default',
          profile: const Profile(
            version: '2',
            title: 'Test Profile',
            notes: '',
            author: 'test',
            beverageType: BeverageType.espresso,
            steps: [],
            targetVolumeCountStart: 0,
            tankTemperature: 0,
          ),
          steamSettings: SteamSettings.defaults(),
          hotWaterData: HotWaterData.defaults(),
          rinseData: RinseData.defaults(),
        );

        storage = FakeStorageService(currentWorkflow: initialWorkflow);
        mockSettingsService = MockSettingsService();
        settingsController = SettingsController(mockSettingsService);
        await settingsController.loadSettings();

        final scanResult = ScanResult(
          shotCount: 0,
          profileCount: 0,
          hasDyeGrinders: false,
          hasSettings: true,
          sourcePath: tempDir.path,
          shotSource: null,
        );

        result = await makeImporter(
          storage: storage,
          settingsController: settingsController,
        ).import(scanResult);
      });

      tearDownAll(() async {
        await tempDir.delete(recursive: true);
      });

      test('returns settingsApplied = true', () {
        expect(result.settingsApplied, isTrue);
      });

      test('sets wake schedule', () {
        final schedules = WakeSchedule.deserializeList(
          settingsController.wakeSchedules,
        );
        expect(schedules, hasLength(1));
        expect(schedules.first.hour, equals(7));
        expect(schedules.first.minute, equals(0));
        expect(schedules.first.enabled, isTrue);
        expect(schedules.first.keepAwakeFor, equals(60));
      });

      test('sets scale power mode to disabled (keep on)', () {
        expect(
          settingsController.scalePowerMode,
          equals(ScalePowerMode.disabled),
        );
      });

      test('sets sleep timeout minutes', () {
        expect(settingsController.sleepTimeoutMinutes, equals(30));
      });

      test('updates workflow context with dose and grinder', () {
        final workflow = storage._currentWorkflow!;
        final ctx = workflow.context!;
        expect(ctx.targetDoseWeight, equals(18.5));
        expect(ctx.targetYield, equals(36.0));
        expect(ctx.grinderModel, equals('Niche Zero'));
        expect(ctx.grinderSetting, equals('22'));
      });

      test('updates workflow steam settings', () {
        final steam = storage._currentWorkflow!.steamSettings;
        expect(steam.targetTemperature, equals(155));
        expect(steam.duration, equals(60));
      });

      test('updates workflow hot water settings', () {
        final water = storage._currentWorkflow!.hotWaterData;
        expect(water.targetTemperature, equals(80));
        expect(water.volume, equals(200));
      });

      test('updates workflow rinse settings', () {
        final rinse = storage._currentWorkflow!.rinseData;
        expect(rinse.flow, equals(4.5));
        expect(rinse.duration, equals(8));
      });

      test('maps smart_battery_charging 2 → highAvailability', () {
        expect(
          settingsController.chargingMode,
          equals(ChargingMode.highAvailability),
        );
      });

      test('has no errors', () {
        expect(result.hasErrors, isFalse);
      });
    });

    group('skips settings when settingsController is null', () {
      late Directory tempDir;
      late ImportResult result;

      setUpAll(() async {
        tempDir = await Directory.systemTemp.createTemp(
          'de1app_importer_nosettings_',
        );
        await File(
          '${tempDir.path}/settings.tdb',
        ).writeAsString('keep_scale_on 1\n');

        final scanResult = ScanResult(
          shotCount: 0,
          profileCount: 0,
          hasDyeGrinders: false,
          hasSettings: true,
          sourcePath: tempDir.path,
          shotSource: null,
        );

        result = await makeImporter().import(scanResult);
      });

      tearDownAll(() async {
        await tempDir.delete(recursive: true);
      });

      test('settingsApplied is false', () {
        expect(result.settingsApplied, isFalse);
      });
    });

    group('links shots to bean batch and grinder IDs', () {
      late FakeStorageService storage;
      late FakeBeanStorageService beans;
      late FakeGrinderStorageService grinders;

      setUpAll(() async {
        storage = FakeStorageService();
        beans = FakeBeanStorageService();
        grinders = FakeGrinderStorageService();
        final scanResult = ScanResult(
          shotCount: 2,
          profileCount: 0,
          hasDyeGrinders: false,
          hasSettings: false,
          sourcePath: _fixturesPath,
          shotSource: 'both',
        );
        await makeImporter(
          storage: storage,
          beanStorage: beans,
          grinderStorage: grinders,
        ).import(scanResult);
      });

      test(
        'every stored shot has a persisted beanBatchId in workflow context',
        () async {
          expect(storage.shots, hasLength(2));
          for (final shot in storage.shots.values) {
            final context = shot.workflow.context;
            expect(context, isNotNull);
            expect(context!.beanBatchId, isNotNull);
            expect(await beans.getBatchById(context.beanBatchId!), isNotNull);
          }
        },
      );

      test(
        'every stored shot has a persisted grinderId in workflow context',
        () async {
          for (final shot in storage.shots.values) {
            final context = shot.workflow.context;
            expect(context, isNotNull);
            expect(context!.grinderId, isNotNull);
            expect(
              await grinders.getGrinderById(context.grinderId!),
              isNotNull,
            );
          }
        },
      );
    });

    group('notifies plugin shot events', () {
      late Directory tempDir;
      late ScanResult scanResult;

      setUpAll(() async {
        tempDir = await Directory.systemTemp.createTemp(
          'de1app_importer_events_',
        );
        await Directory('${tempDir.path}/history_v2').create();
        await File(
          '$_fixturesPath/history_v2/20240315T143022.json',
        ).copy('${tempDir.path}/history_v2/20240315T143022.json');
        scanResult = ScanResult(
          shotCount: 1,
          profileCount: 0,
          hasDyeGrinders: false,
          hasSettings: false,
          sourcePath: tempDir.path,
          shotSource: 'history_v2',
        );
      });

      tearDownAll(() async {
        await tempDir.delete(recursive: true);
      });

      test(
        'bulk import keeps per-shot plugin events and one refresh',
        () async {
          final bulkDir = await Directory.systemTemp.createTemp('de1app_bulk_');
          addTearDown(() => bulkDir.delete(recursive: true));
          await Directory('${bulkDir.path}/history_v2').create();
          final fixture =
              jsonDecode(
                    await File(
                      '$_fixturesPath/history_v2/20240315T143022.json',
                    ).readAsString(),
                  )
                  as Map<String, dynamic>;
          for (var i = 0; i < 3; i++) {
            await File(
              '${bulkDir.path}/history_v2/shot-$i.json',
            ).writeAsString(jsonEncode({...fixture, 'clock': 1710510622 + i}));
          }
          final received = <String>[];
          final controller = PersistenceController(
            storageService: FakeStorageService(),
          )..onShotStored = received.add;
          addTearDown(controller.dispose);
          var changes = 0;
          final subscription = controller.shotsChanged.listen((_) => changes++);
          addTearDown(subscription.cancel);
          final result = await makeImporter(controller: controller).import(
            ScanResult(
              shotCount: 3,
              profileCount: 0,
              hasDyeGrinders: false,
              hasSettings: false,
              sourcePath: bulkDir.path,
              shotSource: 'history_v2',
            ),
          );
          await Future<void>.delayed(Duration.zero);
          expect(result.shotsImported, 3);
          expect(received.toSet(), {
            'de1app-1710510622',
            'de1app-1710510623',
            'de1app-1710510624',
          });
          expect(received, hasLength(3));
          expect(changes, 1);
        },
      );

      test('emits exactly one shotStored per stored shot', () async {
        final received = <String>[];
        final controller = PersistenceController(
          storageService: FakeStorageService(),
        )..onShotStored = received.add;

        addTearDown(controller.dispose);
        var changes = 0;
        final subscription = controller.shotsChanged.listen((_) => changes++);
        addTearDown(subscription.cancel);

        final result = await makeImporter(
          controller: controller,
        ).import(scanResult);

        expect(result.shotsImported, equals(1));
        expect(received, equals(['de1app-1710510622']));
        await Future<void>.delayed(Duration.zero);
        expect(changes, 1);
      });

      test('emits nothing for a shot skipped as already present', () async {
        final received = <String>[];
        final controller = PersistenceController(
          storageService: FakeStorageService(
            existingIds: ['de1app-1710510622'],
          ),
        )..onShotStored = received.add;

        addTearDown(controller.dispose);
        var changes = 0;
        final subscription = controller.shotsChanged.listen((_) => changes++);
        addTearDown(subscription.cancel);

        final result = await makeImporter(
          controller: controller,
        ).import(scanResult);

        expect(result.shotsSkipped, equals(1));
        expect(received, isEmpty);
        await Future<void>.delayed(Duration.zero);
        expect(changes, 0);
      });

      test('emits nothing for a shot whose store fails', () async {
        final received = <String>[];
        final controller = PersistenceController(
          storageService: FakeStorageService()
            ..failedIds.add('de1app-1710510622'),
        )..onShotStored = received.add;

        addTearDown(controller.dispose);
        var changes = 0;
        final subscription = controller.shotsChanged.listen((_) => changes++);
        addTearDown(subscription.cancel);

        final result = await makeImporter(
          controller: controller,
        ).import(scanResult);

        expect(result.shotsImported, equals(0));
        expect(result.errors, hasLength(1));
        expect(received, isEmpty);
        await Future<void>.delayed(Duration.zero);
        expect(changes, 0);
      });
    });
  });
}
