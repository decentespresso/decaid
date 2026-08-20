import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:reaprime/src/services/storage/app_directories.dart';

class _FakePathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _FakePathProvider(this.docsDir, this.supportDir, this.tempDir);

  final Directory docsDir;
  final Directory supportDir;
  final Directory tempDir;

  @override
  Future<String?> getApplicationDocumentsPath() async => docsDir.path;

  @override
  Future<String?> getApplicationSupportPath() async => supportDir.path;

  @override
  Future<String?> getTemporaryPath() async => tempDir.path;
}

void main() {
  final tempRoot = Directory.systemTemp.createTempSync('app_directories_test');
  final docsDir = Directory('${tempRoot.path}/docs')..createSync();
  final supportDir = Directory('${tempRoot.path}/support')..createSync();
  final tmpDir = Directory('${tempRoot.path}/tmp')..createSync();
  tearDownAll(() => tempRoot.deleteSync(recursive: true));

  setUp(() {
    PathProviderPlatform.instance = _FakePathProvider(
      docsDir,
      supportDir,
      tmpDir,
    );
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('desktop resolves support, logs subdirectory and temp', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    expect(await AppDirectories.support, supportDir.path);
    expect(await AppDirectories.temp, tmpDir.path);
    expect(await AppDirectories.hive, p.join(supportDir.path, 'store'));
    expect(await AppDirectories.logs, p.join(supportDir.path, 'logs'));
    expect(await AppDirectories.plugins, p.join(supportDir.path, 'plugins'));
    expect(await AppDirectories.webUi, p.join(supportDir.path, 'web-ui'));
  });

  test('mobile keeps the documents layout', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    expect(await AppDirectories.support, docsDir.path);
    expect(await AppDirectories.hive, p.join(docsDir.path, 'store'));
    expect(await AppDirectories.logs, docsDir.path);
    expect(await AppDirectories.plugins, p.join(docsDir.path, 'plugins'));
  });
}
