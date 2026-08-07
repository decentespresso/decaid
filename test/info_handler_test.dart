import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/build_info.dart';
import 'package:reaprime/src/services/webserver/info_handler.dart';
import 'package:shelf_plus/shelf_plus.dart';

void main() {
  late InfoHandler infoHandler;
  late Handler handler;

  setUp(() {
    infoHandler = InfoHandler();
    final app = Router().plus;
    infoHandler.addRoutes(app);
    handler = app.call;
  });

  Future<Response> sendGet(String path) async {
    return await handler(Request('GET', Uri.parse('http://localhost$path')));
  }

  group('InfoHandler', () {
    test('GET /api/v1/info returns build info', () async {
      final response = await sendGet('/api/v1/info');
      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('application/json'));

      final body = jsonDecode(await response.readAsString());
      expect(body['commit'], BuildInfo.commit);
      expect(body['commitShort'], BuildInfo.commitShort);
      expect(body['branch'], BuildInfo.branch);
      expect(body['buildTime'], BuildInfo.buildTime);
      expect(body['version'], BuildInfo.version);
      expect(body['buildNumber'], BuildInfo.buildNumber);
      expect(body['appStore'], BuildInfo.appStore);
      expect(body['fullVersion'], BuildInfo.fullVersion);
      expect(body['localIp'], isA<String>());

      final expectedKeys = {
        'commit',
        'commitShort',
        'branch',
        'buildTime',
        'version',
        'buildNumber',
        'appStore',
        'fullVersion',
        'localIp',
      };
      expect((body as Map).keys.toSet(), expectedKeys);
    });
  });
}
