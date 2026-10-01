import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/de1_controller.dart';
import 'package:reaprime/src/controllers/device_controller.dart';
import 'package:reaprime/src/controllers/persistence_controller.dart';
import 'package:reaprime/src/import/widgets/import_result_view.dart';
import 'package:reaprime/src/import/widgets/import_source_picker.dart';
import 'package:reaprime/src/onboarding_feature/onboarding_controller.dart';
import 'package:reaprime/src/onboarding_feature/steps/import_step.dart';
import 'package:reaprime/src/services/storage/bean_storage_service.dart';
import 'package:reaprime/src/services/storage/grinder_storage_service.dart';
import 'package:reaprime/src/services/storage/profile_storage_service.dart';
import 'package:reaprime/src/services/storage/storage_service.dart';
import 'package:reaprime/src/settings/backup_import_response.dart';
import 'package:reaprime/src/settings/data_management_page.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shadcn_ui/shadcn_ui.dart';

import '../helpers/mock_settings_service.dart';

class _Storage extends Fake implements StorageService {}

class _Picker extends FilePickerPlatform {
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
    bool cancelUploadOnWindowBlur = true,
  }) async => FilePickerResult([
    PlatformFile(
      name: 'backup.zip',
      size: 3,
      bytes: Uint8List.fromList([0, 1, 2]),
    ),
  ]);
}

class _Profiles extends Fake implements ProfileStorageService {}

class _Beans extends Fake implements BeanStorageService {}

class _Grinders extends Fake implements GrinderStorageService {}

Future<BackupImportResponse> _reject(String reason) async =>
    BackupImportResponse.fromHttp(
      400,
      '{"message":"Invalid backup","reason":"$reason"}',
    );

void main() {
  for (final (reason, expected) in [
    ('too_many_entries', 'If it is De1App data, extract the archive'),
    ('invalid_zip', 'ZIP import failed'),
  ]) {
    testWidgets('onboarding presents $reason backup rejection', (tester) async {
      final storage = _Storage();
      final called = Completer<void>();
      final step = createImportStep(
        storageService: storage,
        profileStorageService: _Profiles(),
        beanStorageService: _Beans(),
        grinderStorageService: _Grinders(),
        settingsController: SettingsController(MockSettingsService()),
        persistenceController: PersistenceController(storageService: storage),
        importBackup: (path) {
          called.complete();
          return _reject(reason);
        },
      );
      final onboarding = OnboardingController(steps: [step]);
      addTearDown(onboarding.dispose);
      await tester.pumpWidget(
        ShadApp(home: ScaffoldMessenger(child: step.builder(onboarding))),
      );

      tester
          .widget<ImportSourcePicker>(find.byType(ImportSourcePicker))
          .onZipFileSelected('backup.zip');
      await called.future.timeout(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      expect(find.byType(ImportResultView), findsOneWidget);
      if (reason == 'too_many_entries') {
        expect(find.textContaining(expected), findsWidgets);
        expect(
          tester.widget<SnackBar>(find.byType(SnackBar)).duration,
          const Duration(seconds: 12),
        );
      } else {
        expect(find.byType(SnackBar), findsNothing);
        await tester.tap(find.text('Show details'));
        await tester.pump();
        expect(find.textContaining(expected), findsOneWidget);
        expect(find.textContaining('de1plus folder'), findsNothing);
      }
    });
  }
  for (final (reason, expected, duration) in [
    (
      'too_many_entries',
      'select the de1plus folder',
      const Duration(seconds: 12),
    ),
    ('invalid_zip', 'Invalid backup', const Duration(seconds: 4)),
  ]) {
    testWidgets('Settings presents $reason backup rejection', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final originalPicker = FilePickerPlatform.instance;
      FilePickerPlatform.instance = _Picker();
      addTearDown(() => FilePickerPlatform.instance = originalPicker);

      final called = Completer<void>();
      final storage = _Storage();
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(0.7)),
          child: ShadApp(
            home: ScaffoldMessenger(
              child: DataManagementPage(
                controller: SettingsController(MockSettingsService()),
                persistenceController: PersistenceController(
                  storageService: storage,
                ),
                de1Controller: De1Controller(
                  controller: DeviceController(const []),
                ),
                decentAccountService: null,
                importBackup: (path, strategy) {
                  called.complete();
                  return _reject(reason);
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Import Full Backup'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Skip existing'));
      await tester.pump();
      await tester.runAsync(
        () => called.future.timeout(const Duration(seconds: 10)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining(expected), findsOneWidget);
      expect(tester.widget<SnackBar>(find.byType(SnackBar)).duration, duration);
    });
  }
}
