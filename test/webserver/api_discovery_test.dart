import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:reaprime/src/services/webserver/info_handler.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_plus/shelf_plus.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart' as sws;
import 'package:web_socket_channel/web_socket_channel.dart';

Future<List<int>> readResponseBytes(Response response) =>
    response.read().fold<List<int>>([], (bytes, chunk) => bytes..addAll(chunk));

class _TestPathProvider extends PathProviderPlatform {
  _TestPathProvider(this.path);

  final String path;

  @override
  Future<String?> getTemporaryPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDirectory;
  late PathProviderPlatform originalPathProvider;

  setUp(() async {
    originalPathProvider = PathProviderPlatform.instance;
    tempDirectory = await Directory.systemTemp.createTemp('api-discovery-test');
    PathProviderPlatform.instance = _TestPathProvider(tempDirectory.path);
  });

  tearDown(() async {
    PathProviderPlatform.instance = originalPathProvider;
    await tempDirectory.delete(recursive: true);
  });

  Handler createHandler({bool withWebSocket = false}) {
    final app = createApiRouter();
    InfoHandler().addRoutes(app);
    LogsHandler(logFilePath: '${tempDirectory.path}/decaid.log').addRoutes(app);
    if (withWebSocket) {
      app.get(
        '/ws/v1/test',
        sws.webSocketHandler((socket, protocol) {
          socket.sink.add('connected');
        }),
      );
    }
    return buildWebServerHandler(app.call);
  }

  test('manifest is exact, small, and uses the docs port', () async {
    final response = await createHandler()(
      Request('GET', Uri.parse('http://localhost/api/v1/manifest')),
    );

    expect(response.statusCode, 200);
    expect(response.headers['content-type'], contains('application/json'));
    final body = await response.readAsString();
    expect(utf8.encode(body).length, lessThan(1024));
    expect(
      body,
      '{"api":"v1","docs":{"port":4001,"viewer":"/","openapi":"/rest_v1.yml","asyncapi":"/websocket_v1.yml"}}',
    );
    expect(jsonDecode(body), {
      'api': 'v1',
      'docs': {
        'port': 4001,
        'viewer': '/',
        'openapi': '/rest_v1.yml',
        'asyncapi': '/websocket_v1.yml',
      },
    });
  });

  test(
    'manifest GET supports HEAD without a body and preserves method status',
    () async {
      final handler = createHandler();
      final manifestUri = Uri.parse('http://localhost/api/v1/manifest');
      final getResponse = await handler(Request('GET', manifestUri));
      final headResponse = await handler(Request('HEAD', manifestUri));

      expect(headResponse.statusCode, getResponse.statusCode);
      expect(await readResponseBytes(headResponse), isEmpty);

      final unconfiguredRouter = Router().plus;
      for (final path in [apiDocsConfiguration.manifestPath, '/api/v1/info']) {
        final configured = await handler(
          Request('POST', Uri.parse('http://localhost$path')),
        );
        final unconfigured = await unconfiguredRouter.call(
          Request('POST', Uri.parse('http://localhost$path')),
        );
        expect(configured.statusCode, unconfigured.statusCode);
      }
    },
  );

  test('unmatched routes use the documentation hint', () async {
    final handler = createHandler();

    for (final path in ['/', '/api/v1/unknown-route']) {
      final response = await handler(
        Request('GET', Uri.parse('http://localhost$path')),
      );

      expect(response.statusCode, 404);
      expect(response.headers['content-type'], contains('application/json'));
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['error'], 'Route not found');
      expect(body['hint'], contains('port 4001'));
      expect(body['hint'], contains('/rest_v1.yml'));
      expect(body['hint'], isNot(contains('/docs')));
    }
  });

  test('handler-generated 404 responses are unchanged', () async {
    final response = await createHandler()(
      Request('GET', Uri.parse('http://localhost/api/v1/logs')),
    );

    expect(response.statusCode, 404);
    expect(response.headers['content-type'], isNull);
    expect(await response.readAsString(), 'Log file not found');
  });

  test('manifest spec URLs use its host and serve exact YAML bytes', () async {
    final apiDirectory = Directory('${tempDirectory.path}/api')
      ..createSync(recursive: true);
    for (final assetPath in apiDocsConfiguration.assetPaths) {
      final filename = assetPath.split('/').last;
      await File(assetPath).copy('${apiDirectory.path}/$filename');
    }

    final manifestUri = Uri.parse('http://docs.example.test/api/v1/manifest');
    final manifestResponse = await createHandler()(Request('GET', manifestUri));
    final manifest = jsonDecode(await manifestResponse.readAsString()) as Map;
    final docs = manifest['docs'] as Map;
    final docsOrigin = Uri(
      scheme: manifestUri.scheme,
      host: manifestUri.host,
      port: docs['port'] as int,
    );
    expect(docsOrigin.host, manifestUri.host);
    expect(docsOrigin.port, apiDocsConfiguration.port);
    final handler = createApiDocsHandler(apiDirectory.path);

    for (final name in ['openapi', 'asyncapi']) {
      final path = docs[name] as String;
      final response = await handler(
        Request('GET', docsOrigin.replace(path: path)),
      );
      final assetPath = apiDocsConfiguration.assetPaths.singleWhere(
        (assetPath) => assetPath.endsWith(path),
      );
      expect(response.statusCode, 200);
      expect(
        await readResponseBytes(response),
        await File(assetPath).readAsBytes(),
      );
    }
  });

  test('existing successful routes and CORS remain available', () async {
    final success = await createHandler()(
      Request('GET', Uri.parse('http://localhost/api/v1/info')),
    );
    expect(success.statusCode, 200);
    expect(success.headers['content-type'], contains('application/json'));

    final preflight = await createHandler()(
      Request(
        'OPTIONS',
        Uri.parse('http://localhost/api/v1/manifest'),
        headers: {
          'origin': 'http://example.test',
          'access-control-request-method': 'GET',
        },
      ),
    );
    expect(preflight.statusCode, 200);
    expect(preflight.headers['access-control-allow-methods'], contains('GET'));
  });

  test('existing WebSocket routes still upgrade', () async {
    final server = await shelf_io.serve(
      createHandler(withWebSocket: true),
      '127.0.0.1',
      0,
    );
    addTearDown(server.close);

    final channel = WebSocketChannel.connect(
      Uri.parse('ws://127.0.0.1:${server.port}/ws/v1/test'),
    );
    addTearDown(channel.sink.close);

    await channel.ready;
    expect(await channel.stream.first, 'connected');
  });
}
