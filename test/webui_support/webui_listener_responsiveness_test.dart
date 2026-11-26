import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';

void main() {
  late Directory skin;
  late WebUIService service;

  setUp(() async {
    WebUIService.resolveWifiIP = () async => 'localhost';
    skin = await Directory.systemTemp.createTemp('webui_listener_health');
    await File('${skin.path}/index.html').writeAsString('skin');
    service = WebUIService(listLocalAddresses: () async => const []);
    await service.serveFolderAtPath(skin.path, port: 0);
  });

  tearDown(() async {
    await service.stopServing();
    if (skin.existsSync()) await skin.delete(recursive: true);
  });

  test(
    'listener responsiveness is verified with a real HTTP request',
    () async {
      final client = HttpClient()
        ..connectionTimeout = const Duration(seconds: 1);
      addTearDown(() => client.close(force: true));

      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${service.port}/'),
      );
      final response = await request.close();
      await response.drain<void>();

      expect(response.statusCode, HttpStatus.ok);
    },
  );
}
