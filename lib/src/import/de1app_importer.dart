import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/models/data/bean.dart';
import 'package:reaprime/src/models/data/grinder.dart';
import 'package:reaprime/src/import/import_result.dart';
import 'package:reaprime/src/import/parsers/grinder_tdb_parser.dart';
import 'package:reaprime/src/import/parsers/profile_v2_parser.dart';
import 'package:reaprime/src/import/parsers/shot_v2_json_parser.dart';
import 'package:reaprime/src/import/parsers/tcl_profile_parser.dart';
import 'package:reaprime/src/import/parsers/tcl_shot_parser.dart';
import 'package:reaprime/src/services/storage/bean_storage_service.dart';
import 'package:reaprime/src/services/storage/grinder_storage_service.dart';
import 'package:reaprime/src/services/storage/profile_storage_service.dart';
import 'package:reaprime/src/models/data/shot_record.dart';
import 'package:reaprime/src/import/parsers/settings_tdb_parser.dart';
import 'package:reaprime/src/models/wake_schedule.dart';
import 'package:reaprime/src/models/data/workflow.dart';
import 'package:reaprime/src/models/data/workflow_context.dart';
import 'package:reaprime/src/controllers/workflow_controller.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/settings/scale_power_mode.dart';
import 'dart:convert';

part 'entity_extractor.dart';

final _log = Logger('De1appImporter');

class De1appImporter {
  final PersistenceController controller;
  final ProfileStorageService profileStorageService;
  final BeanStorageService beanStorageService;
  final GrinderStorageService grinderStorageService;
  final SettingsController? settingsController;
  final WorkflowController? workflowController;
  final ParsedShot Function(Map<String, dynamic>) _parseV2Shot;

  De1appImporter({
    required this.controller,
    required this.profileStorageService,
    required this.beanStorageService,
    required this.grinderStorageService,
    this.settingsController,
    this.workflowController,
    @visibleForTesting
    ParsedShot Function(Map<String, dynamic>) parseV2Shot =
        ShotV2JsonParser.parse,
  }) : _parseV2Shot = parseV2Shot;

  Future<ImportResult> import(
    ScanResult scanResult, {
    void Function(ImportProgress)? onProgress,
  }) async {
    final errors = <ImportError>[];
    var shotsImported = 0;
    var shotsSkipped = 0;
    var profilesImported = 0;
    var profilesSkipped = 0;
    final entities = _ImportedShotEntities(
      beanStorageService,
      grinderStorageService,
    );
    var settingsApplied = false;

    final parsedShots = <ParsedShot>[];
    final shotFiles = (await _mergedFiles(
      preferred: Directory('${scanResult.sourcePath}/history_v2'),
      preferredExtension: '.json',
      fallback: Directory('${scanResult.sourcePath}/history'),
      fallbackExtension: '.shot',
      newerFallbackWins: true,
    )).values.toList();

    for (var i = 0; i < shotFiles.length; i++) {
      final entry = shotFiles[i];
      final filename = entry.file.uri.pathSegments.last;
      try {
        final content = await entry.file.readAsString();
        ParsedShot parsed;
        if (entry.isPreferred) {
          final json = jsonDecode(content) as Map<String, dynamic>;
          parsed = _parseV2Shot(json);
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
        ImportProgress(current: i + 1, total: shotFiles.length, phase: 'shots'),
      );
    }

    var dyeGrinders = <Grinder>[];
    if (scanResult.hasDyeGrinders) {
      final tdbFile = File('${scanResult.sourcePath}/plugins/DYE/grinders.tdb');
      try {
        dyeGrinders = GrinderTdbParser.parse(await tdbFile.readAsString());
      } catch (e, st) {
        _log.warning('Failed to parse DYE grinders.tdb', e, st);
      }
    }
    final linkedShots = await entities.reconcile(
      parsedShots,
      dyeGrinders,
      errors: errors,
      onProgress: onProgress,
    );

    final existingIds = (await controller.storageService.getShotIds()).toSet();

    for (var i = 0; i < parsedShots.length; i++) {
      final shot = linkedShots[i];

      if (existingIds.contains(shot.id)) {
        shotsSkipped++;
        onProgress?.call(
          ImportProgress(
            current: i + 1,
            total: parsedShots.length,
            phase: 'storing shots',
            beansCreated: entities.beansCreated,
            grindersCreated: entities.grindersCreated,
          ),
        );
        continue;
      }

      try {
        await controller.storeShot(shot, notifyApplication: false);
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
          beansCreated: entities.beansCreated,
          grindersCreated: entities.grindersCreated,
        ),
      );
    }

    if (shotsImported > 0) controller.notifyShotsChanged();

    final profileFiles = (await _mergedFiles(
      preferred: Directory('${scanResult.sourcePath}/profiles_v2'),
      preferredExtension: '.json',
      fallback: Directory('${scanResult.sourcePath}/profiles'),
      fallbackExtension: '.tcl',
    )).values.toList();

    for (var i = 0; i < profileFiles.length; i++) {
      final entry = profileFiles[i];
      final filename = entry.file.uri.pathSegments.last;
      try {
        final content = await entry.file.readAsString();
        final record = entry.isPreferred
            ? ProfileV2Parser.parse(jsonDecode(content) as Map<String, dynamic>)
            : TclProfileParser.parse(content);

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
          total: profileFiles.length,
          phase: 'profiles',
        ),
      );
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
              await controller.storageService.loadCurrentWorkflow() ??
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
          await controller.storageService.storeCurrentWorkflow(updatedWorkflow);
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
      beansCreated: entities.beansCreated,
      beansSkipped: entities.beansSkipped,
      grindersCreated: entities.grindersCreated,
      grindersSkipped: entities.grindersSkipped,
      settingsApplied: settingsApplied,
      errors: errors,
    );
  }
}

class _MergedFile {
  final File file;
  final bool isPreferred;
  const _MergedFile(this.file, {required this.isPreferred});
}

Future<Map<String, _MergedFile>> _mergedFiles({
  required Directory preferred,
  required String preferredExtension,
  required Directory fallback,
  required String fallbackExtension,
  bool newerFallbackWins = false,
}) async {
  final result = <String, _MergedFile>{};

  if (await fallback.exists()) {
    await for (final entity in fallback.list()) {
      if (entity is File && entity.path.endsWith(fallbackExtension)) {
        result[_basename(entity, fallbackExtension)] = _MergedFile(
          entity,
          isPreferred: false,
        );
      }
    }
  }

  if (await preferred.exists()) {
    await for (final entity in preferred.list()) {
      if (entity is File && entity.path.endsWith(preferredExtension)) {
        final basename = _basename(entity, preferredExtension);
        final existing = result[basename];
        if (newerFallbackWins && existing != null && !existing.isPreferred) {
          final preferredModified = (await entity.stat()).modified;
          final fallbackModified = (await existing.file.stat()).modified;
          if (preferredModified.isBefore(fallbackModified)) continue;
        }
        result[basename] = _MergedFile(entity, isPreferred: true);
      }
    }
  }

  return result;
}

String _basename(File file, String extension) {
  final name = file.uri.pathSegments.last;
  return name.substring(0, name.length - extension.length);
}
