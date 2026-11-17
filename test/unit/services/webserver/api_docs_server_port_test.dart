import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:reaprime/src/services/webserver_service.dart';

class _FakePathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  _FakePathProvider(this.tempDir);

  final Directory tempDir;

  @override
  Future<String?> getTemporaryPath() async => tempDir.path;
}

const _apiDocsPort = 4001;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    final tempDir = Directory.systemTemp.createTempSync('api_docs_port_test');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    PathProviderPlatform.instance = _FakePathProvider(tempDir);
  });

  test('a bound docs port does not fail the boot', () async {
    final holder = await ServerSocket.bind(
      InternetAddress.anyIPv4,
      _apiDocsPort,
    );
    addTearDown(holder.close);

    final server = await startApiDocsServer();

    expect(server, isNull);
    expect(holder.port, _apiDocsPort);
  });

  test('a free docs port still serves the docs', () async {
    final server = await startApiDocsServer();
    addTearDown(() => server?.close(force: true));

    expect(server, isNotNull);
    expect(server!.port, _apiDocsPort);
  });
}
