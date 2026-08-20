import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:reaprime/src/services/storage/app_directories.dart';

class _FakePathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _FakePathProvider(this.docsPath, this.supportPath, this.tempPath);

  final String docsPath;
  final String supportPath;
  final String tempPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => docsPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;

  @override
  Future<String?> getTemporaryPath() async => tempPath;
}

void main() {
  const docsPath = '/docs';
  const supportPath = '/support';
  const tempPath = '/tmp';

  setUp(() {
    PathProviderPlatform.instance = _FakePathProvider(
      docsPath,
      supportPath,
      tempPath,
    );
  });

  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('desktop resolves support, logs subdirectory and temp', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    expect(await AppDirectories.support, supportPath);
    expect(await AppDirectories.temp, tempPath);
    expect(await AppDirectories.hive, p.join(supportPath, 'store'));
    expect(
      await AppDirectories.driftFile,
      p.join(supportPath, 'streamline_bridge.sqlite'),
    );
    expect(await AppDirectories.logs, p.join(supportPath, 'logs'));
    expect(await AppDirectories.plugins, p.join(supportPath, 'plugins'));
    expect(await AppDirectories.webUi, p.join(supportPath, 'web-ui'));
  });

  test('mobile keeps the documents layout', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    expect(await AppDirectories.support, docsPath);
    expect(await AppDirectories.hive, p.join(docsPath, 'store'));
    expect(
      await AppDirectories.driftFile,
      p.join(docsPath, 'streamline_bridge.sqlite'),
    );
    expect(await AppDirectories.logs, docsPath);
    expect(await AppDirectories.plugins, p.join(docsPath, 'plugins'));
  });
}
