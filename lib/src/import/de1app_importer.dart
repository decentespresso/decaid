import 'dart:io';

import 'package:collection/collection.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/data/bean.dart';
import 'package:reaprime/src/import/entity_extractor.dart';
import 'package:reaprime/src/import/import_result.dart';
import 'package:reaprime/src/import/parsers/grinder_tdb_parser.dart';
import 'package:reaprime/src/import/parsers/profile_v2_parser.dart';
import 'package:reaprime/src/import/parsers/shot_v2_json_parser.dart';
import 'package:reaprime/src/import/parsers/tcl_shot_parser.dart';
import 'package:reaprime/src/services/storage/bean_storage_service.dart';
import 'package:reaprime/src/services/storage/grinder_storage_service.dart';
import 'package:reaprime/src/services/storage/profile_storage_service.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/import/parsers/settings_tdb_parser.dart';
import 'package:reaprime/src/models/wake_schedule.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/data/workflow_context.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/scale_power_mode.dart';
import 'dart:convert';

final _log = Logger('De1appImporter');

/// Orchestrates the full de1app import pipeline:
/// scan → parse shots → extract entities → store everything.
class De1appImporter {
  final StorageService storageService;
  final ProfileStorageService profileStorageService;
  final BeanStorageService beanStorageService;
  final GrinderStorageService grinderStorageService;
  final SettingsController? settingsController;
  final WorkflowController? workflowController;

  De1appImporter({
    required this.storageService,
    required this.profileStorageService,
    required this.beanStorageService,
    required this.grinderStorageService,
    this.settingsController,
    this.workflowController,
  });

  Future<ImportResult> import(
    ScanResult scanResult, {
    void Function(ImportProgress)? onProgress,
  }) async {
    final errors = <ImportError>[];
    var shotsImported = 0;
    var shotsSkipped = 0;
    var profilesImported = 0;
    var profilesSkipped = 0;
    var beansCreated = 0;
    var beansSkipped = 0;
    var grindersCreated = 0;
    var grindersSkipped = 0;
    var settingsApplied = false;

    final parsedShots = <ParsedShot>[];
    if (scanResult.shotSource != null) {
      final shotDir = Directory(
        '${scanResult.sourcePath}/${scanResult.shotSource}',
      );

      final isV2 = scanResult.shotSource == 'history_v2';
      final extension = isV2 ? '.json' : '.shot';
      final files = <File>[];

      await for (final entity in shotDir.list()) {
        if (entity is File && entity.path.endsWith(extension)) {
          files.add(entity);
        }
      }

      for (var i = 0; i < files.length; i++) {
        final file = files[i];
        final filename = file.uri.pathSegments.last;
        try {
          final content = await file.readAsString();
          ParsedShot parsed;
          if (isV2) {
            final json = jsonDecode(content) as Map<String, dynamic>;
            parsed = ShotV2JsonParser.parse(json);
          } else {
            parsed = TclShotParser.parse(content);
          }
          parsedShots.add(parsed);
        } catch (e, st) {
          _log.warning('Failed to parse shot file $filename', e, st);
          errors.add(
            ImportError(
              filename: filename,
              reason: 'Parse error',
              details: e.toString(),
            ),
          );
        }

        onProgress?.call(
          ImportProgress(
            current: i + 1,
            total: scanResult.shotCount,
            phase: 'shots',
          ),
        );
      }
    }

    final extractor = EntityExtractor();
    final extraction = extractor.extract(parsedShots);

    final entityTotal = extraction.beans.length + extraction.grinders.length;
    var entityIndex = 0;

    final existingBeans = await beanStorageService.getAllBeans();
    final existingBeanMap = <String, String>{};
    for (final bean in existingBeans) {
      final key = '${bean.roaster.toLowerCase()}\x00${bean.name.toLowerCase()}';
      existingBeanMap[key] = bean.id;
    }

    final existingBatches = <String, List<BeanBatch>>{};
    for (final bean in existingBeans) {
      final batches = await beanStorageService.getBatchesForBean(bean.id);
      existingBatches[bean.id] = batches;
    }

    final existingGrinders = await grinderStorageService.getAllGrinders();
    final existingGrinderMap = <String, String>{};
    for (final grinder in existingGrinders) {
      existingGrinderMap[grinder.model.toLowerCase()] = grinder.id;
    }

    final beanIdRemap = <String, String>{};
    final batchIdRemap = <String, String>{};
    final grinderIdRemap = <String, String>{};

    for (final bean in extraction.beans) {
      final key = '${bean.roaster.toLowerCase()}\x00${bean.name.toLowerCase()}';
      final existingId = existingBeanMap[key];
      if (existingId != null) {
        beanIdRemap[bean.id] = existingId;
        beansSkipped++;
      } else {
        try {
          await beanStorageService.insertBean(bean);
          beansCreated++;
        } catch (e, st) {
          _log.warning('Failed to store bean ${bean.name}', e, st);
        }
      }
      entityIndex++;
      onProgress?.call(
        ImportProgress(
          current: entityIndex,
          total: entityTotal,
          phase: 'entities',
          beansCreated: beansCreated,
          grindersCreated: grindersCreated,
        ),
      );
    }

    for (final batch in extraction.batches) {
      final actualBeanId = beanIdRemap[batch.beanId] ?? batch.beanId;
      final existingBeanBatches = existingBatches[actualBeanId] ?? [];

      final existingBatch = existingBeanBatches.firstWhereOrNull(
        (b) =>
            b.roastDate == batch.roastDate ||
            (b.roastDate != null &&
                batch.roastDate != null &&
                b.roastDate!.isAtSameMomentAs(batch.roastDate!)),
      );

      if (existingBatch != null) {
        batchIdRemap[batch.id] = existingBatch.id;
      } else {
        final actualBatch = actualBeanId != batch.beanId
            ? BeanBatch(
                id: batch.id,
                beanId: actualBeanId,
                roastDate: batch.roastDate,
                roastLevel: batch.roastLevel,
                createdAt: batch.createdAt,
                updatedAt: batch.updatedAt,
              )
            : batch;
        try {
          await beanStorageService.insertBatch(actualBatch);
        } catch (e, st) {
          _log.warning('Failed to store bean batch ${batch.id}', e, st);
        }
      }
    }

    var grinders = extraction.grinders;
    if (scanResult.hasDyeGrinders) {
      final tdbFile = File('${scanResult.sourcePath}/plugins/DYE/grinders.tdb');
      try {
        final content = await tdbFile.readAsString();
        final dyeGrinders = GrinderTdbParser.parse(content);
        grinders = extractor.mergeGrinderSpecs(grinders, dyeGrinders);
      } catch (e, st) {
        _log.warning('Failed to parse DYE grinders.tdb', e, st);
      }
    }

    for (final grinder in grinders) {
      final existingId = existingGrinderMap[grinder.model.toLowerCase()];
      if (existingId != null) {
        grinderIdRemap[grinder.id] = existingId;
        grindersSkipped++;
      } else {
        try {
          await grinderStorageService.insertGrinder(grinder);
          grindersCreated++;
        } catch (e, st) {
          _log.warning('Failed to store grinder ${grinder.model}', e, st);
        }
      }
      entityIndex++;
      onProgress?.call(
        ImportProgress(
          current: entityIndex,
          total: entityTotal,
          phase: 'entities',
          beansCreated: beansCreated,
          grindersCreated: grindersCreated,
        ),
      );
    }

    final existingIds = (await storageService.getShotIds()).toSet();

    for (var i = 0; i < parsedShots.length; i++) {
      final parsed = parsedShots[i];
      final shot = parsed.shot;

      if (existingIds.contains(shot.id)) {
        shotsSkipped++;
        onProgress?.call(
          ImportProgress(
            current: i + 1,
            total: parsedShots.length,
            phase: 'storing shots',
            beansCreated: beansCreated,
            grindersCreated: grindersCreated,
          ),
        );
        continue;
      }

      final rawBatchId = extraction.shotBeanBatchIds[i];
      final rawGrinderId = extraction.shotGrinderIds[i];
      final batchId = rawBatchId != null
          ? (batchIdRemap[rawBatchId] ?? rawBatchId)
          : null;
      final grinderId = rawGrinderId != null
          ? (grinderIdRemap[rawGrinderId] ?? rawGrinderId)
          : null;

      final updatedShot = (batchId != null || grinderId != null)
          ? _linkShotToEntities(shot, batchId: batchId, grinderId: grinderId)
          : shot;

      try {
        await storageService.storeShot(updatedShot);
        shotsImported++;
      } catch (e, st) {
        _log.warning('Failed to store shot ${shot.id}', e, st);
        errors.add(
          ImportError(
            filename: shot.id,
            reason: 'Storage error',
            details: e.toString(),
          ),
        );
      }

      onProgress?.call(
        ImportProgress(
          current: i + 1,
          total: parsedShots.length,
          phase: 'storing shots',
          beansCreated: beansCreated,
          grindersCreated: grindersCreated,
        ),
      );
    }

    final profilesDir = Directory('${scanResult.sourcePath}/profiles_v2');
    if (await profilesDir.exists()) {
      final profileFiles = <File>[];
      await for (final entity in profilesDir.list()) {
        if (entity is File && entity.path.endsWith('.json')) {
          profileFiles.add(entity);
        }
      }

      for (var i = 0; i < profileFiles.length; i++) {
        final file = profileFiles[i];
        final filename = file.uri.pathSegments.last;
        try {
          final content = await file.readAsString();
          final json = jsonDecode(content) as Map<String, dynamic>;
          final record = ProfileV2Parser.parse(json);

          final existing = await profileStorageService.get(record.id);
          if (existing != null) {
            profilesSkipped++;
          } else {
            await profileStorageService.store(record);
            profilesImported++;
          }
        } catch (e, st) {
          _log.warning('Failed to import profile $filename', e, st);
          errors.add(
            ImportError(
              filename: filename,
              reason: 'Profile import error',
              details: e.toString(),
            ),
          );
        }

        onProgress?.call(
          ImportProgress(
            current: i + 1,
            total: scanResult.profileCount,
            phase: 'profiles',
          ),
        );
      }
    }

    if (scanResult.hasSettings && settingsController != null) {
      try {
        final settingsFile = File('${scanResult.sourcePath}/settings.tdb');
        final content = await settingsFile.readAsString();
        final settings = SettingsTdbParser.parse(content);

        if (!settings.isEmpty) {
          if (settings.wakeHour != null && settings.wakeMinute != null) {
            final schedule = WakeSchedule.create(
              hour: settings.wakeHour!,
              minute: settings.wakeMinute!,
              enabled: settings.wakeScheduleEnabled ?? false,
              keepAwakeFor: settings.keepAwakeForMinutes,
            );
            await settingsController!.setWakeSchedules(
              WakeSchedule.serializeList([schedule]),
            );
          }

          if (settings.keepScaleOn != null) {
            await settingsController!.setScalePowerMode(
              settings.keepScaleOn!
                  ? ScalePowerMode.disabled
                  : ScalePowerMode.disconnect,
            );
          }

          if (settings.sleepTimeoutMinutes != null) {
            await settingsController!.setSleepTimeoutMinutes(
              settings.sleepTimeoutMinutes!,
            );
          }

          if (settings.chargingMode != null) {
            await settingsController!.setChargingMode(settings.chargingMode!);
          }

          if (Platform.isAndroid) {
            if (settings.machineBluetoothAddress != null) {
              await settingsController!.setPreferredMachineId(
                settings.machineBluetoothAddress,
              );
            }
            if (settings.scaleBluetoothAddress != null) {
              await settingsController!.setPreferredScaleId(
                settings.scaleBluetoothAddress,
              );
            }
          }

          final baseWorkflow =
              await storageService.loadCurrentWorkflow() ??
              WorkflowController().newWorkflow();
          final updatedContext =
              (baseWorkflow.context ?? const WorkflowContext()).copyWith(
                targetDoseWeight: settings.doseWeight,
                targetYield: settings.targetYield,
                grinderModel: settings.grinderModel,
                grinderSetting: settings.grinderSetting,
              );
          final updatedSteam = baseWorkflow.steamSettings.copyWith(
            targetTemperature: settings.steamTemperature,
            duration: settings.steamDuration,
          );
          final updatedWater = baseWorkflow.hotWaterData.copyWith(
            targetTemperature: settings.hotWaterTemperature,
            volume: settings.hotWaterVolume,
          );
          final updatedRinse = RinseData(
            targetTemperature: baseWorkflow.rinseData.targetTemperature,
            duration: settings.rinseDuration ?? baseWorkflow.rinseData.duration,
            flow: settings.rinseFlow ?? baseWorkflow.rinseData.flow,
          );
          final updatedWorkflow = baseWorkflow.copyWith(
            context: updatedContext,
            steamSettings: updatedSteam,
            hotWaterData: updatedWater,
            rinseData: updatedRinse,
          );
          await storageService.storeCurrentWorkflow(updatedWorkflow);
          workflowController?.setWorkflow(updatedWorkflow);

          settingsApplied = true;
        }
      } catch (e, st) {
        _log.warning('Failed to import settings.tdb', e, st);
        errors.add(
          ImportError(
            filename: 'settings.tdb',
            reason: 'Settings import error',
            details: e.toString(),
          ),
        );
      }
    }

    return ImportResult(
      shotsImported: shotsImported,
      shotsSkipped: shotsSkipped,
      profilesImported: profilesImported,
      profilesSkipped: profilesSkipped,
      beansCreated: beansCreated,
      beansSkipped: beansSkipped,
      grindersCreated: grindersCreated,
      grindersSkipped: grindersSkipped,
      settingsApplied: settingsApplied,
      errors: errors,
    );
  }

  /// Returns a copy of [shot] with [batchId] and/or [grinderId] set in the
  /// workflow's context.
  static ShotRecord _linkShotToEntities(
    ShotRecord shot, {
    String? batchId,
    String? grinderId,
  }) {
    final existingContext = shot.workflow.context;
    final updatedContext = existingContext?.copyWith(
      beanBatchId: batchId,
      grinderId: grinderId,
    );

    if (updatedContext == null) return shot;

    final updatedWorkflow = shot.workflow.copyWith(context: updatedContext);
    return shot.copyWith(workflow: updatedWorkflow);
  }
}
