import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:reaprime/src/models/feedback/feedback_request.dart';
import 'package:reaprime/src/services/feedback_service.dart';

class _FakePathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _FakePathProvider(this.docsDir);

  final Directory docsDir;

  @override
  Future<String?> getApplicationDocumentsPath() async => docsDir.path;
}

void main() {
  test('scrubs serials from logs when the serial provider is empty', () async {
    final tempDir = Directory.systemTemp.createTempSync(
      'feedback_service_test',
    );
    addTearDown(() => tempDir.deleteSync(recursive: true));

    PathProviderPlatform.instance = _FakePathProvider(tempDir);

    File('${tempDir.path}/log.txt').writeAsStringSync(
      'device connected {"machineInfo":{"serialNumber":"SN123456"}}\n'
      'another line serialNumber: SN999888\n',
    );

    final service = FeedbackService(
      githubToken: 'token',
      currentSerialNumbers: () => const [],
    );

    final report = await service.generateHtmlReport(
      FeedbackRequest(
        description: 'test',
        type: FeedbackType.bug,
        includeLogs: true,
        includeSystemInfo: false,
      ),
    );

    expect(report, isNot(contains('SN123456')));
    expect(report, isNot(contains('SN999888')));
    expect(report, contains('serial_'));
  });
}
