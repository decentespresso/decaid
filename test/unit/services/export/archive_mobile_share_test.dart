import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/export/archive_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.fluttercommunity.plus/share');
  const origin = Rect.fromLTWH(30, 40, 160, 48);

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
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
        sharePositionOrigin: origin,
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
