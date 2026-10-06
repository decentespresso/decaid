import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/export/archive_export.dart';

class _Picker extends FilePickerPlatform {
  _Picker(this.path);
  final String? path;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.fluttercommunity.plus/share');
  const origin = Rect.fromLTWH(30, 40, 160, 48);

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.linux,
    TargetPlatform.windows,
  ]) {
    for (final save in [true, false]) {
      test(
        '$platform desktop save=$save never resolves share origin',
        () async {
          debugDefaultTargetPlatformOverride = platform;
          final temp = await Directory.systemTemp.createTemp('desktop-share-');
          final destination = '${temp.path}/backup.zip';
          final originalPicker = FilePickerPlatform.instance;
          FilePickerPlatform.instance = _Picker(save ? destination : null);
          addTearDown(() async {
            FilePickerPlatform.instance = originalPicker;
            await temp.delete(recursive: true);
          });
          var written = false;
          final result = await deliverArchive(
            fileName: 'backup.zip',
            sharePositionOrigin: () => throw StateError('must not be called'),
            writeArchive: (target) async {
              written = true;
              await File(target.outputPath).writeAsString('archive');
            },
          );
          expect(
            result,
            save ? DeliveryOutcome.saved : DeliveryOutcome.cancelled,
          );
          expect(written, save);
          if (save) expect(File(destination).readAsStringSync(), 'archive');
        },
      );
    }
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    test('$platform resolver failure propagates and removes archive', () async {
      debugDefaultTargetPlatformOverride = platform;
      String? writtenPath;
      var shared = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            shared = true;
            return '';
          });
      final error = StateError('no visible share action');
      await expectLater(
        deliverArchive(
          fileName: 'backup.zip',
          sharePositionOrigin: () {
            expect(File(writtenPath!).readAsStringSync(), 'archive');
            throw error;
          },
          writeArchive: (target) async {
            writtenPath = target.outputPath;
            await File(target.outputPath).writeAsString('archive');
          },
        ),
        throwsA(same(error)),
      );
      expect(shared, isFalse);
      expect(File(writtenPath!).parent.existsSync(), isFalse);
    });
    test('$platform archive share receives supplied non-zero origin', () async {
      debugDefaultTargetPlatformOverride = platform;
      Map<dynamic, dynamic>? shared;
      String? writtenPath;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            expect(call.method, 'share');
            shared = call.arguments as Map;
            expect(
              File(
                (shared!['paths'] as List).single as String,
              ).readAsStringSync(),
              'archive',
            );
            return '';
          });
      final result = await deliverArchive(
        fileName: 'backup.zip',
        sharePositionOrigin: () => origin,
        writeArchive: (target) async {
          writtenPath = target.outputPath;
          await File(target.outputPath).writeAsString('archive');
        },
      );
      expect(result, DeliveryOutcome.cancelled);
      expect(shared, isNotNull);
      expect(shared!['originX'], origin.left);
      expect(shared!['originY'], origin.top);
      expect(shared!['originWidth'], origin.width);
      expect(shared!['originHeight'], origin.height);
      expect(shared!['subject'], 'Decent backup');
      expect(shared!['mimeTypes'], ['application/zip']);
      expect(File(writtenPath!).existsSync(), isFalse);
    });
  }
}
