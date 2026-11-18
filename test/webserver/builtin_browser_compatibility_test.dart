import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_source_service.dart';
import 'package:reaprime/src/services/account/proxy_token_service.dart';
import 'package:reaprime/src/services/webserver/extension_management_auth.dart';
import 'package:reaprime/src/services/webserver/port_binding.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_plus/shelf_plus.dart';

import '../helpers/mock_settings_service.dart';
import '../plugins/extension_management_harness.dart'
    show RecordingWebUIStorage, RecordingWebUIService, managerToken;
import '../plugins/plugin_test_helpers.dart';

const _settingsPluginId = 'settings.reaplugin';
const _settingsPagePath = '/api/v1/plugins/$_settingsPluginId/ui';
const _thirdPartyPagePath = '/api/v1/plugins/dye2.reaplugin/ui';
const _skinUpdatePath = '/api/v1/webui/skins/update';
const _settingsPath = '/api/v1/settings';
const _aliasHost = 'de1tablet.home';
const _hostileOrigin = 'https://evil.example';
const _foreignNumericHost = '10.9.9.9';
const _managedInterfaceAddress = '192.168.12.64';
const _nodeHarness = 'test/plugins/builtin_browser_requests.cjs';
const _nodeTimeout = Duration(seconds: 60);

class _ScopedPeerAddress extends Fake implements InternetAddress {
  @override
  String get address => 'fe80::1%test-interface';

  @override
  Uint8List get rawAddress => InternetAddress('fe80::1').rawAddress;
}

class _Reply {
  _Reply(this.status, this.body, this.headers);

  final int status;
  final String body;
  final Map<String, String> headers;

  String? header(String name) => headers[name.toLowerCase()];

  String get corsAllowOrigin => header('access-control-allow-origin') ?? '';

  Map<String, dynamic> get json => body.isEmpty
      ? <String, dynamic>{}
      : jsonDecode(body) as Map<String, dynamic>;

  List<dynamic> get jsonList => jsonDecode(body) as List<dynamic>;

  String get error => (json['error'] ?? json['message'] ?? '').toString();

  @override
  String toString() => 'status=$status cors="$corsAllowOrigin" body=$body';
}

class _PageRequest {
  _PageRequest(this.action, this.method, this.url, this.headers, this.body);

  final String action;
  final String method;
  final String url;
  final Map<String, String> headers;
  final String? body;

  Uri get uri => Uri.parse(url);
}

class _Surface {
  _Surface._({
    required this.tempDir,
    required this.loader,
    required this.tokens,
    required this.skins,
    required this.skinServer,
    required this.settings,
    required this.settingsService,
    required this.handler,
    required this.docsHandler,
    required this.apiServer,
    required this.docsServer,
  });

  final Directory tempDir;
  final PluginLoaderService loader;
  final ProxyTokenService tokens;
  final RecordingWebUIStorage skins;
  final RecordingWebUIService skinServer;
  final SettingsController settings;
  final MockSettingsService settingsService;
  final Handler handler;
  final Handler docsHandler;
  final HttpServer apiServer;
  final HttpServer? docsServer;

  int get apiPort => apiServer.port;

  int? get docsListenerPort => docsServer?.port;

  int get docsPort => docsServer!.port;

  String get numericPageOrigin => 'http://127.0.0.1:$apiPort';

  String get aliasPageOrigin => 'http://$_aliasHost:$apiPort';

  String get numericDocsOrigin => 'http://127.0.0.1:$docsPort';

  String get aliasDocsOrigin => 'http://$_aliasHost:$docsPort';

  static Future<_Surface> start({
    bool requireManagementAuthorization = false,
    int? docsBindPort,
    bool requireDocsBind = false,
  }) async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    final tempDir = Directory.systemTemp.createTempSync('builtin_browser');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => tempDir.path,
        );

    final loader = PluginLoaderService(kvStore: FakeKeyValueStoreService());
    await loader.initialize();
    if (!loader.isPluginLoaded(_settingsPluginId)) {
      await loader.enablePlugin(_settingsPluginId);
    }
    final sourceService = PluginSourceService(loader);
    final tokens = ProxyTokenService(skinToken: 'skin-token-0123456789abcdef')
      ..registerToken(
        managerToken,
        const ProxyCaller(
          id: 'api:manager',
          scopes: {ProxyTokenService.scopeExtensionsManage},
          label: 'Fleet',
        ),
      );
    final skins = RecordingWebUIStorage();
    final skinServer = RecordingWebUIService()
      ..browserOriginAddresses = {'127.0.0.1'};
    final settingsService = MockSettingsService();
    final settings = SettingsController(settingsService);
    await settings.loadSettings();

    final app = Router().plus;
    SettingsHandler(
      controller: settings,
      service: skinServer,
      webUIStorage: skins,
    ).addRoutes(app);
    WebUIHandler(storage: skins, service: skinServer).addRoutes(app);
    PluginsHandler(
      pluginManager: loader.pluginManager,
      pluginService: loader,
      pluginSourceService: sourceService,
    ).addRoutes(app);

    int? apiListenerPort;
    int? apiDocsListenerPort;
    Future<Set<String>> deviceAddresses() =>
        skinServer.currentBrowserOriginAddresses();
    final handler = buildWebServerHandler(
      app.call,
      proxyTokenService: tokens,
      requireExtensionManagementAuthorization: () async =>
          requireManagementAuthorization,
      browserOrigins: extensionManagementBrowserOrigins(
        skinServer,
        apiListenerPort: () => apiListenerPort,
        docsListenerPort: () => apiDocsListenerPort,
      ),
      pageListener: BuiltinPageListener(
        listenerPort: () => apiListenerPort,
        deviceAddresses: deviceAddresses,
      ),
    );
    loader.pluginManager.attachLocalApi(handler);
    final apiServer = await shelf_io.serve(handler, InternetAddress.anyIPv4, 0);
    apiListenerPort = apiServer.port;

    final docsHandler = createApiDocsHandler(
      'assets/api',
      pageListener: BuiltinPageListener(
        listenerPort: () => apiDocsListenerPort,
        deviceAddresses: deviceAddresses,
      ),
    );
    HttpServer? docsServer;
    if (docsBindPort != null) {
      try {
        docsServer = await serveOrReportPortInUse(
          docsHandler,
          InternetAddress.loopbackIPv4,
          docsBindPort,
        );
      } on WebServerPortInUse catch (error) {
        if (requireDocsBind) {
          apiServer.close(force: true);
          await loader.dispose();
          tempDir.deleteSync(recursive: true);
          throw StateError(
            'The API docs viewer port ${error.port} is unavailable; this '
            'regression test needs the built-in docs port so the reproduced '
            'origin matches the reported one',
          );
        }
      }
      apiDocsListenerPort = docsServer?.port;
    }

    return _Surface._(
      tempDir: tempDir,
      loader: loader,
      tokens: tokens,
      skins: skins,
      skinServer: skinServer,
      settings: settings,
      settingsService: settingsService,
      handler: handler,
      docsHandler: docsHandler,
      apiServer: apiServer,
      docsServer: docsServer,
    );
  }

  Future<void> dispose() async {
    await apiServer.close(force: true);
    await docsServer?.close(force: true);
    await loader.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  }

  Future<_Reply> get(String origin, String path) async {
    final target = Uri.parse(origin);
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        'GET',
        Uri.parse('http://127.0.0.1:${target.port}$path'),
      );
      request.followRedirects = false;
      request.headers.host = target.host;
      final response = await request.close();
      return await _reply(response);
    } finally {
      client.close(force: true);
    }
  }

  Future<_Reply> follow(String location) {
    final target = Uri.parse(location);
    final origin = target.hasPort
        ? 'http://${target.host}:${target.port}'
        : 'http://${target.host}';
    return get(origin, target.path.isEmpty ? '/' : target.path);
  }

  Future<_Reply> dispatch(Request request) async =>
      _replyOf(await handler(request));

  Future<_Reply> dispatchDocs(Request request) async =>
      _replyOf(await docsHandler(request));

  Future<_Reply> send(
    String method,
    String path, {
    String? origin,
    String? hostHeader,
    Map<String, String> headers = const {},
    Object? body,
    String? contentType,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:$apiPort$path'),
      );
      request.followRedirects = false;
      if (hostHeader != null) request.headers.host = hostHeader;
      if (origin != null) request.headers.set('origin', origin);
      headers.forEach(request.headers.set);
      if (body != null) {
        if (contentType != null) {
          request.headers.set('content-type', contentType);
        } else {
          request.headers.contentType = ContentType.json;
        }
        request.write(body is String ? body : jsonEncode(body));
      }
      final response = await request.close();
      return await _reply(response);
    } finally {
      client.close(force: true);
    }
  }

  Future<_Reply> preflight(
    String path, {
    required String origin,
    String requestedMethod = 'POST',
    String requestedHeaders = 'content-type',
  }) => send(
    'OPTIONS',
    path,
    origin: origin,
    headers: {
      'access-control-request-method': requestedMethod,
      'access-control-request-headers': requestedHeaders,
    },
  );

  static Future<_Reply> _reply(HttpClientResponse response) async {
    final headers = <String, String>{};
    response.headers.forEach(
      (name, values) => headers[name.toLowerCase()] = values.join(', '),
    );
    return _Reply(
      response.statusCode,
      await response.transform(utf8.decoder).join(),
      headers,
    );
  }

  static Future<_Reply> _replyOf(Response response) async {
    final headers = <String, String>{};
    response.headers.forEach((name, value) {
      headers[name.toLowerCase()] = value.toString();
    });
    return _Reply(response.statusCode, await response.readAsString(), headers);
  }

  Future<List<_PageRequest>> pageRequests({
    required String pageHtml,
    required String pageOrigin,
  }) async {
    final pageFile = File(
      '${tempDir.path}/settings-page-${Uri.parse(pageOrigin).port}.html',
    );
    await pageFile.writeAsString(pageHtml);
    final result = await Process.run('node', [
      _nodeHarness,
      '--html',
      pageFile.path,
      '--origin',
      pageOrigin,
    ]).timeout(_nodeTimeout);
    if (result.exitCode != 0) {
      throw StateError(
        'node harness failed (${result.exitCode}): ${result.stderr}',
      );
    }
    final recorded =
        jsonDecode(result.stdout as String) as Map<String, dynamic>;
    final requests = <_PageRequest>[];
    for (final action in recorded['actions'] as List<dynamic>) {
      final entry = action as Map<String, dynamic>;
      for (final request in entry['requests'] as List<dynamic>) {
        final item = request as Map<String, dynamic>;
        requests.add(
          _PageRequest(
            entry['action'] as String,
            item['method'] as String,
            item['absoluteUrl'] as String,
            {
              for (final header
                  in (item['headers'] as Map<String, dynamic>).entries)
                header.key: header.value.toString(),
            },
            item['body'] as String?,
          ),
        );
      }
    }
    return requests;
  }

  Future<Map<String, dynamic>> viewerConfiguration({
    required String pageHtml,
    required String docsOrigin,
  }) async {
    final rest = await get(docsOrigin, '/rest_v1.yml');
    final async = await get(docsOrigin, '/websocket_v1.yml');
    expect(rest.status, 200, reason: _evidence('GET /rest_v1.yml', rest));
    expect(
      async.status,
      200,
      reason: _evidence('GET /websocket_v1.yml', async),
    );
    final port = Uri.parse(docsOrigin).port;
    final pageFile = File('${tempDir.path}/docs-viewer-$port.html');
    final restFile = File('${tempDir.path}/docs-rest-$port.yml');
    final asyncFile = File('${tempDir.path}/docs-async-$port.yml');
    await pageFile.writeAsString(pageHtml);
    await restFile.writeAsString(rest.body);
    await asyncFile.writeAsString(async.body);
    final result = await Process.run('node', [
      _nodeHarness,
      '--docs',
      '--html',
      pageFile.path,
      '--origin',
      docsOrigin,
      '--rest',
      restFile.path,
      '--ws',
      asyncFile.path,
    ]).timeout(_nodeTimeout);
    if (result.exitCode != 0) {
      throw StateError(
        'node harness failed (${result.exitCode}): ${result.stderr}',
      );
    }
    return jsonDecode(result.stdout as String) as Map<String, dynamic>;
  }
}

Future<_Reply> _replay(
  _Surface surface,
  _PageRequest request, {
  required String pageOrigin,
}) {
  final origin = Uri.parse(pageOrigin);
  String? contentType;
  for (final header in request.headers.entries) {
    if (header.key.toLowerCase() == 'content-type') contentType = header.value;
  }
  return surface.send(
    request.method,
    request.uri.path,
    origin: pageOrigin,
    hostHeader: origin.host == '127.0.0.1' ? null : origin.host,
    headers: {'content-type': ?contentType},
    body: request.body,
  );
}

String _wanted(String expectation) => 'WANTED BEHAVIOUR: $expectation';

int _skinUpdateCount(Iterable<String> mutations) =>
    mutations.where((mutation) => mutation == 'checkForSkinUpdates').length;

int _skinUpdateIncrements(Iterable<String> mutations, List<String> before) =>
    _skinUpdateCount(mutations) - _skinUpdateCount(before);

class _SocketPeer implements HttpConnectionInfo {
  _SocketPeer(this.remoteAddress);

  @override
  final InternetAddress remoteAddress;

  @override
  int get remotePort => 51000;

  @override
  int get localPort => 4001;
}

Handler _pageEntryHandler({
  required Future<Set<String>> Function() deviceAddresses,
  int? Function()? port,
  String? Function()? listenerAddress,
}) => const Pipeline()
    .addMiddleware(
      builtinBrowserCanonicalRedirect(
        pagePaths: builtinApiDocsViewerPaths,
        listener: BuiltinPageListener(
          listenerPort: port ?? () => 4001,
          deviceAddresses: deviceAddresses,
          listenerAddress: listenerAddress,
        ),
      ),
    )
    .addHandler((request) => Response.ok('page'));

Future<Response> _pageEntry(
  Handler handler, {
  String? host = _aliasHost,
  InternetAddress? peer,
  String path = '/',
}) async {
  final connectionInfo = peer == null ? null : _SocketPeer(peer);
  return await handler(
    Request(
      'GET',
      Uri.parse('http://127.0.0.1:4001$path'),
      headers: {'host': ?host},
      context: {'shelf.io.connection_info': ?connectionInfo},
    ),
  );
}

String _evidence(String label, _Reply reply) =>
    '$label -> status=${reply.status} '
    'corsAllowOrigin="${reply.corsAllowOrigin}" body=${reply.body}';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Surface surface;

  setUpAll(() async {
    surface = await _Surface.start(
      docsBindPort: apiDocsConfiguration.port,
      requireDocsBind: true,
    );
  });

  tearDownAll(() async {
    await surface.dispose();
  });

  group('API docs viewer on the built-in docs port', () {
    test(
      'serves its viewer and declares the API listener as its target',
      () async {
        final viewer = await surface.get(surface.numericDocsOrigin, '/');
        expect(viewer.status, 200, reason: _evidence('docs viewer', viewer));
        expect(viewer.body, contains('SwaggerUIBundle'));
        expect(viewer.body, contains('rest_v1.yml'));

        final spec = await surface.get(
          surface.numericDocsOrigin,
          '/rest_v1.yml',
        );
        expect(spec.status, 200);
        expect(spec.body, contains('http://{tablet-ip}:8080'));
        expect(
          surface.docsPort,
          apiDocsConfiguration.port,
          reason: 'the docs page origin reported by the user is port 4001',
        );
      },
    );

    test('numeric-IP docs origin must pass the management preflight', () async {
      final reply = await surface.preflight(
        _skinUpdatePath,
        origin: surface.numericDocsOrigin,
      );
      expect(
        reply.status,
        200,
        reason: _wanted(
          'a browser on the docs page (${surface.numericDocsOrigin}) must get a '
          'successful preflight, not a refusal.\n'
          '${_evidence('OPTIONS $_skinUpdatePath', reply)}',
        ),
      );
      final allowedMethods =
          (reply.header('access-control-allow-methods') ?? '')
              .toLowerCase()
              .split(',')
              .map((method) => method.trim())
              .toSet();
      final allowedHeaders =
          (reply.header('access-control-allow-headers') ?? '').toLowerCase();
      expect(
        allowedMethods,
        contains('post'),
        reason: _wanted(
          'the preflight must allow the requested method POST, not merely answer '
          'a status.\n${_evidence('OPTIONS $_skinUpdatePath', reply)}',
        ),
      );
      expect(
        allowedHeaders,
        contains('content-type'),
        reason: _wanted(
          'the preflight must allow the requested content-type header.\n'
          '${_evidence('OPTIONS $_skinUpdatePath', reply)}',
        ),
      );
      expect(
        reply.corsAllowOrigin,
        surface.numericDocsOrigin,
        reason: _wanted(
          'the preflight must affirmatively allow the docs origin.\n'
          '${_evidence('OPTIONS $_skinUpdatePath', reply)}',
        ),
      );
      expect(reply.header('access-control-max-age'), isNotNull);
    });

    test('numeric-IP docs origin must be able to request a skin update', () async {
      final before = List.of(surface.skins.mutations);
      final reply = await surface.send(
        'POST',
        _skinUpdatePath,
        origin: surface.numericDocsOrigin,
      );
      expect(
        reply.status,
        200,
        reason: _wanted(
          'POST $_skinUpdatePath from the docs page origin '
          '${surface.numericDocsOrigin} (API listener ${surface.apiPort}, the '
          'device equivalent is 8080) must succeed.\n'
          '${_evidence('POST $_skinUpdatePath', reply)}',
        ),
      );
      expect(
        _skinUpdateIncrements(surface.skins.mutations, before),
        1,
        reason: 'exactly one new skin update check must be recorded',
      );
    });

    test(
      'the docs host is trusted once the origin carries the API port',
      () async {
        final reply = await surface.send(
          'POST',
          _skinUpdatePath,
          origin: surface.numericPageOrigin,
        );
        expect(
          reply.status,
          200,
          reason:
              'the docs host is not the problem on its own: the same numeric host '
              'with the API listener port is accepted, so the numeric-IP docs '
              'failure was the docs port missing from the trusted ports.\n'
              '${_evidence('POST $_skinUpdatePath', reply)}',
        );
      },
    );

    test(
      'forged Host and forwarding headers do not change the docs verdict',
      () async {
        final plain = await surface.send(
          'POST',
          _skinUpdatePath,
          origin: surface.numericDocsOrigin,
        );
        final forged = await surface.send(
          'POST',
          _skinUpdatePath,
          origin: surface.numericDocsOrigin,
          hostHeader: _aliasHost,
          headers: {
            'x-forwarded-host': _aliasHost,
            'x-forwarded-for': '127.0.0.1',
            'x-real-ip': '127.0.0.1',
            'forwarded': 'host=$_aliasHost:${surface.docsPort}',
          },
        );
        expect(plain.status, 200, reason: _evidence('POST docs origin', plain));
        expect(
          forged.status,
          plain.status,
          reason:
              'the docs-origin verdict must not depend on client supplied Host or '
              'forwarding headers, and a trusted docs origin must stay trusted '
              'when they are forged.\n${_evidence('plain', plain)}\n'
              '${_evidence('forged', forged)}',
        );
        expect(plain.corsAllowOrigin, surface.numericDocsOrigin);
      },
    );

    test('the literal null origin is refused with the docs port', () async {
      final before = List.of(surface.skins.mutations);
      final reply = await surface.send('POST', _skinUpdatePath, origin: 'null');
      expect(reply.status, 403, reason: _evidence('POST null origin', reply));
      expect(reply.error, untrustedBrowserOriginError);
      expect(reply.corsAllowOrigin, isEmpty);
      expect(surface.skins.mutations, before);
    });

    test('numeric hosts that are not current interfaces are refused on the docs port', () async {
      final before = List.of(surface.skins.mutations);
      final reply = await surface.send(
        'POST',
        _skinUpdatePath,
        origin: 'http://$_foreignNumericHost:${surface.docsPort}',
      );
      expect(
        reply.status,
        403,
        reason: _evidence('POST foreign numeric docs', reply),
      );
      expect(reply.error, untrustedBrowserOriginError);
      expect(surface.skins.mutations, before);
    });

    test('the numeric docs entry point is not redirected', () async {
      final root = await surface.get(surface.numericDocsOrigin, '/');
      expect(root.status, 200, reason: _evidence('GET / numeric', root));
      final localhost = await surface.get(
        'http://localhost:${surface.docsPort}',
        '/index.html',
      );
      expect(
        localhost.status,
        200,
        reason:
            'a working numeric or localhost entry must stay a working entry, '
            'not a redirect.\n${_evidence('GET /index.html localhost', localhost)}',
      );
    });

    test('the alias docs viewer redirects to the numeric docs origin', () async {
      final entry = await surface.get(surface.aliasDocsOrigin, '/');
      expect(
        entry.status,
        302,
        reason: _wanted(
          'the alias docs entry ${surface.aliasDocsOrigin} must send the browser '
          'to the numeric local endpoint it actually reached.\n'
          '${_evidence('GET / via alias', entry)}',
        ),
      );
      expect(
        entry.header('location'),
        'http://127.0.0.1:${surface.docsPort}/#',
        reason:
            'the destination is built from the bound listener port and the local '
            'address, never from the request authority, and it names an empty '
            'fragment so the browser does not inherit one',
      );
      expect(entry.header('cache-control'), 'no-store');
      expect(entry.header('referrer-policy'), 'no-referrer');

      final page = await surface.follow(entry.header('location')!);
      expect(page.status, 200, reason: _evidence('GET canonical docs', page));
      expect(page.body, contains('SwaggerUIBundle'));

      final indexPath = await surface.get(
        surface.aliasDocsOrigin,
        '/index.html',
      );
      expect(
        indexPath.header('location'),
        'http://127.0.0.1:${surface.docsPort}/index.html#',
      );
    });

    test('the redirect carries no query or credentials', () async {
      final entry = await surface.get(
        surface.aliasDocsOrigin,
        '/index.html?token=secret&next=https://evil.example',
      );
      expect(
        entry.status,
        302,
        reason: _evidence('GET /index.html?token', entry),
      );
      expect(
        entry.header('location'),
        'http://127.0.0.1:${surface.docsPort}/index.html#',
        reason:
            'nothing from the incoming request is carried into the redirect '
            'target: no query string, no credentials',
      );
      expect(entry.header('location'), isNot(contains('secret')));
    });

    test('a browser fragment on the docs entry is discarded', () async {
      const browserFragment = 'token=secret';
      final browserUrl = Uri.parse(
        '${surface.aliasDocsOrigin}/index.html#$browserFragment',
      );
      final entry = await surface.get(surface.aliasDocsOrigin, browserUrl.path);
      expect(
        entry.status,
        302,
        reason: _evidence('GET alias docs with fragment', entry),
      );
      final location = entry.header('location')!;
      final destination = Uri.parse(location);
      expect(
        destination.hasFragment,
        isTrue,
        reason: _wanted(
          'an HTTP request never carries the browser fragment, so a redirect '
          'answer that omits the fragment component makes the browser reattach '
          '#$browserFragment to the canonical page. The redirect has to name an '
          'empty fragment instead.\nlocation=$location',
        ),
      );
      expect(destination.fragment, isEmpty);
      expect(location, 'http://127.0.0.1:${surface.docsPort}/index.html#');
      expect(location, isNot(contains(browserFragment)));
      final browserLands = destination.hasFragment
          ? destination
          : destination.replace(fragment: browserUrl.fragment);
      expect(
        browserLands.fragment,
        isEmpty,
        reason:
            'the browser must land on the canonical page without the secret',
      );
    });

    test('the alias Host does not redirect the docs spec files', () async {
      final spec = await surface.get(surface.aliasDocsOrigin, '/rest_v1.yml');
      expect(
        spec.status,
        200,
        reason:
            'only the viewer page is canonicalised; the spec files keep their '
            'existing relative behaviour.\n${_evidence('GET rest_v1.yml', spec)}',
      );
      final async = await surface.get(
        surface.aliasDocsOrigin,
        '/websocket_v1.yml',
      );
      expect(async.status, 200);
    });

    test('the canonical docs viewer targets the numeric API host', () async {
      final page = await surface.get(surface.numericDocsOrigin, '/');
      expect(page.status, 200, reason: _evidence('canonical docs', page));
      final viewer = await surface.viewerConfiguration(
        pageHtml: page.body,
        docsOrigin: surface.numericDocsOrigin,
      );
      final rest = viewer['rest'] as Map<String, dynamic>;
      final shippedServers = rest['shippedServers'] as List<dynamic>;
      final servers = rest['servers'] as List<dynamic>;
      expect(
        rest['specProvided'],
        isTrue,
        reason: _wanted(
          'the delivered viewer must hand its own spec to Swagger UI so the API '
          'target can be canonicalised.\nviewer=$viewer',
        ),
      );
      expect(shippedServers, isNotEmpty);
      expect(
        servers,
        isNotEmpty,
        reason: _wanted(
          'the delivered viewer must configure an API target.\nviewer=$viewer',
        ),
      );
      final shipped = shippedServers.first as Map<String, dynamic>;
      final target = servers.first as Map<String, dynamic>;
      expect(
        shipped['resolved'],
        'http://localhost:8080',
        reason:
            'the shipped spec still defaults the tablet-ip variable to '
            'localhost, so the numeric target has to come from the viewer',
      );
      expect(
        target['resolved'],
        'http://127.0.0.1:8080',
        reason: _wanted(
          'the docs viewer must target the canonical numeric host it was '
          'served from instead of the localhost default, so a browser on '
          'another machine sends its API requests to the device.\n'
          'viewer=$viewer',
        ),
      );
      final asyncApi = viewer['asyncApi'] as Map<String, dynamic>;
      final asyncServers = asyncApi['servers'] as List<dynamic>;
      expect(asyncServers, isNotEmpty);
      expect(
        (asyncServers.first as Map<String, dynamic>)['resolved'],
        '127.0.0.1:8080',
      );
    });

    test('the alias docs entry ends in a working skin update from the numeric host', () async {
      final entry = await surface.get(surface.aliasDocsOrigin, '/');
      expect(entry.status, 302, reason: _evidence('alias docs entry', entry));
      final canonicalOrigin = Uri.parse(entry.header('location')!);
      final pageOrigin =
          'http://${canonicalOrigin.host}:${canonicalOrigin.port}';
      final page = await surface.follow(entry.header('location')!);
      expect(page.status, 200, reason: _evidence('canonical docs', page));

      final viewer = await surface.viewerConfiguration(
        pageHtml: page.body,
        docsOrigin: pageOrigin,
      );
      final rest = viewer['rest'] as Map<String, dynamic>;
      final servers = rest['servers'] as List<dynamic>;
      expect(servers, isNotEmpty, reason: _wanted('viewer=$viewer'));
      final apiTarget = Uri.parse(
        (servers.first as Map<String, dynamic>)['resolved'] as String,
      );
      expect(
        apiTarget.host,
        canonicalOrigin.host,
        reason: _wanted(
          'the canonical docs page must address the numeric host it was '
          'served from.\nviewer=$viewer',
        ),
      );
      expect(
        apiTarget.port,
        8080,
        reason:
            'the docs port stays 4001 and the API port stays the documented '
            '8080; only the host is canonicalised',
      );

      final before = List.of(surface.skins.mutations);
      final reply = await surface.send(
        'POST',
        _skinUpdatePath,
        origin: pageOrigin,
      );
      expect(
        reply.status,
        200,
        reason:
            'the request the canonical docs page actually makes must be '
            'admitted.\n${_evidence('POST $_skinUpdatePath', reply)}',
      );
      expect(
        _skinUpdateIncrements(surface.skins.mutations, before),
        1,
        reason:
            'the request the canonical docs page actually makes must be the one '
            'new skin update check',
      );
    });
  });

  group('the docs port is trusted only while its listener is bound', () {
    test(
      'the helper keeps the docs port untrusted without a bound listener',
      () async {
        final pageService = RecordingWebUIService()
          ..browserOriginAddresses = {_managedInterfaceAddress};
        final docsOrigin =
            'http://$_managedInterfaceAddress:${apiDocsConfiguration.port}';
        final listenerOrigin =
            'http://$_managedInterfaceAddress:${surface.apiPort}';

        final withoutListener = extensionManagementBrowserOrigins(
          pageService,
          apiListenerPort: () => surface.apiPort,
        );
        expect(
          await withoutListener.classify(docsOrigin),
          BrowserOriginVerdict.untrusted,
          reason:
              'callers that pass no docs listener (the WebUI tests) must keep the '
              'previous policy: the built-in docs port is never trusted by default',
        );
        expect(
          await withoutListener.classify(listenerOrigin),
          BrowserOriginVerdict.trusted,
        );

        int? boundDocsPort;
        final withListener = extensionManagementBrowserOrigins(
          pageService,
          apiListenerPort: () => surface.apiPort,
          docsListenerPort: () => boundDocsPort,
        );
        expect(
          await withListener.classify(docsOrigin),
          BrowserOriginVerdict.untrusted,
          reason:
              'a docs listener that is not bound must not contribute a port',
        );
        boundDocsPort = apiDocsConfiguration.port;
        expect(
          await withListener.classify(docsOrigin),
          BrowserOriginVerdict.trusted,
        );
        boundDocsPort = null;
        expect(
          await withListener.classify(docsOrigin),
          BrowserOriginVerdict.untrusted,
          reason:
              'a docs listener that stops, or that failed to start, must drop the '
              'trusted origin again',
        );
      },
    );

    test(
      'a docs listener that failed to start leaves its port untrusted',
      () async {
        final occupied = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        addTearDown(() => occupied.close());
        final blockedPort = occupied.port;

        final failedStart = await _Surface.start(docsBindPort: blockedPort);
        addTearDown(failedStart.dispose);

        expect(
          failedStart.docsListenerPort,
          isNull,
          reason:
              'startApiDocsServer() returns null after WebServerPortInUse, and only '
              'a bound listener may contribute a trusted port',
        );
        final before = List.of(failedStart.skins.mutations);
        final reply = await failedStart.send(
          'POST',
          _skinUpdatePath,
          origin: 'http://127.0.0.1:$blockedPort',
        );
        expect(
          reply.status,
          403,
          reason: _evidence('POST failed docs port', reply),
        );
        expect(reply.error, untrustedBrowserOriginError);
        expect(reply.corsAllowOrigin, isEmpty);
        expect(failedStart.skins.mutations, before);
      },
    );
  });

  group('the alias entry is canonicalised before any browser request', () {
    test('the alias settings page redirects to the numeric page origin', () async {
      final entry = await surface.get(
        surface.aliasPageOrigin,
        _settingsPagePath,
      );
      expect(
        entry.status,
        302,
        reason: _wanted(
          'the bundled settings page reached through $_aliasHost must send the '
          'browser to the numeric local endpoint.\n'
          '${_evidence('GET $_settingsPagePath via alias', entry)}',
        ),
      );
      expect(
        entry.header('location'),
        'http://127.0.0.1:${surface.apiPort}$_settingsPagePath#',
      );
      expect(entry.header('cache-control'), 'no-store');
      expect(entry.header('referrer-policy'), 'no-referrer');
      expect(entry.body, isEmpty, reason: 'a redirect must not run the plugin');
    });

    test('a browser fragment on the page entry is discarded', () async {
      const browserFragment = 'token=secret';
      final browserUrl = Uri.parse(
        '${surface.aliasPageOrigin}$_settingsPagePath#$browserFragment',
      );
      final entry = await surface.get(surface.aliasPageOrigin, browserUrl.path);
      expect(
        entry.status,
        302,
        reason: _evidence('GET alias page with fragment', entry),
      );
      final location = entry.header('location')!;
      final destination = Uri.parse(location);
      expect(
        destination.hasFragment,
        isTrue,
        reason: _wanted(
          'the browser keeps #$browserFragment on the canonical page when the '
          'redirect answer omits the fragment component, because an HTTP request '
          'never carries it. The redirect has to name an empty '
          'fragment.\nlocation=$location',
        ),
      );
      expect(destination.fragment, isEmpty);
      expect(
        location,
        'http://127.0.0.1:${surface.apiPort}$_settingsPagePath#',
      );
      expect(location, isNot(contains(browserFragment)));
      final browserLands = destination.hasFragment
          ? destination
          : destination.replace(fragment: browserUrl.fragment);
      expect(
        browserLands.fragment,
        isEmpty,
        reason:
            'the browser must land on the canonical page without the secret',
      );
    });

    test('the numeric settings entry point is not redirected', () async {
      final page = await surface.get(
        surface.numericPageOrigin,
        _settingsPagePath,
      );
      expect(
        page.status,
        200,
        reason:
            'a working numeric entry must stay a working entry.\n'
            '${_evidence('GET numeric page', page)}',
      );
      expect(page.body, contains('checkSkinUpdates'));
    });

    test('the alias entry ends in a working page mutation', () async {
      final entry = await surface.get(
        surface.aliasPageOrigin,
        _settingsPagePath,
      );
      expect(entry.status, 302, reason: _evidence('alias page entry', entry));
      final location = Uri.parse(entry.header('location')!);
      final pageOrigin = 'http://${location.host}:${location.port}';

      final page = await surface.follow(entry.header('location')!);
      expect(page.status, 200, reason: _evidence('canonical page', page));
      expect(page.body, contains('checkSkinUpdates'));

      final requests = await surface.pageRequests(
        pageHtml: page.body,
        pageOrigin: pageOrigin,
      );
      expect(requests, isNotEmpty);
      for (final request in requests) {
        expect(
          request.uri.host,
          location.host,
          reason:
              'the page the redirect delivered must address its own canonical '
              'origin, not the alias it entered through',
        );
      }

      final before = List.of(surface.skins.mutations);
      final reply = await _replay(
        surface,
        requests.first,
        pageOrigin: pageOrigin,
      );
      expect(
        reply.status,
        200,
        reason: _wanted(
          'the page mutation the canonical page actually makes must succeed.\n'
          '${_evidence('POST $_skinUpdatePath', reply)}',
        ),
      );
      expect(
        _skinUpdateIncrements(surface.skins.mutations, before),
        1,
        reason:
            'the page mutation the canonical page actually makes must be the one '
            'new skin update check',
      );
    });

    test('the alias Host does not redirect other plugin pages', () async {
      final reply = await surface.get(
        surface.aliasPageOrigin,
        _thirdPartyPagePath,
      );
      expect(
        reply.status,
        isNot(302),
        reason:
            'only the bundled settings page is canonicalised; a third-party '
            'plugin page keeps its own behaviour.\n'
            '${_evidence('GET $_thirdPartyPagePath', reply)}',
      );
    });

    test('the alias Host does not redirect API routes or mutations', () async {
      final plugins = await surface.get(
        surface.aliasPageOrigin,
        '/api/v1/plugins',
      );
      expect(
        plugins.status,
        200,
        reason:
            'the API answers the alias Host exactly as before; only the bundled '
            'page is canonicalised.\n${_evidence('GET plugins', plugins)}',
      );
      expect(plugins.jsonList, isA<List<dynamic>>());

      final post = await surface.send(
        'POST',
        _settingsPagePath,
        hostHeader: '$_aliasHost:${surface.apiPort}',
      );
      expect(
        post.status,
        isNot(302),
        reason:
            'a mutation is never answered with a page redirect; the origin and '
            'credential rules own that decision.\n'
            '${_evidence('POST $_settingsPagePath', post)}',
      );
    });

    test('an alias page request without socket provenance is refused', () async {
      final aliasRequest = Request(
        'GET',
        Uri.parse('http://$_aliasHost:${surface.apiPort}$_settingsPagePath'),
        headers: {'host': '$_aliasHost:${surface.apiPort}'},
      );
      final reply = await surface.dispatch(aliasRequest);
      expect(
        reply.status,
        403,
        reason: _wanted(
          'without a socket that can name the local endpoint the alias entry '
          'fails closed instead of guessing a destination.\n'
          '${_evidence('GET alias without provenance', reply)}',
        ),
      );
      expect(reply.error, builtinPageAddressUnavailableError);
      expect(reply.header('cache-control'), 'no-store');

      final docsReply = await surface.dispatchDocs(
        Request(
          'GET',
          Uri.parse('http://$_aliasHost:${surface.docsPort}/'),
          headers: {'host': '$_aliasHost:${surface.docsPort}'},
        ),
      );
      expect(
        docsReply.status,
        403,
        reason: _evidence('GET alias docs without provenance', docsReply),
      );
      expect(docsReply.error, builtinPageAddressUnavailableError);

      final numeric = await surface.dispatch(
        Request(
          'GET',
          Uri.parse('http://127.0.0.1:${surface.apiPort}$_settingsPagePath'),
          headers: {'host': '127.0.0.1:${surface.apiPort}'},
        ),
      );
      expect(
        numeric.status,
        200,
        reason:
            'a numeric entry needs no redirect, so it is not affected by a '
            'missing socket.\n${_evidence('GET numeric without provenance', numeric)}',
      );
    });
  });

  group('canonical page addresses', () {
    test('a loopback peer keeps the loopback destination', () {
      expect(
        canonicalPageHost(
          peer: InternetAddress('127.0.0.1'),
          addresses: const {},
        ),
        '127.0.0.1',
      );
      expect(
        canonicalPageHost(peer: InternetAddress('::1'), addresses: const {}),
        '::1',
      );
    });

    test('IPv6 destinations are bracketed in the redirect location', () {
      expect(
        builtinPageLocation(host: '::1', port: 4001, path: '/').toString(),
        'http://[::1]:4001/#',
      );
      expect(
        builtinPageLocation(
          host: '2001:db8::5',
          port: 8080,
          path: _settingsPagePath,
        ).toString(),
        'http://[2001:db8::5]:8080$_settingsPagePath#',
      );
      expect(
        builtinPageLocation(
          host: '192.168.12.64',
          port: 8080,
          path: '/',
        ).toString(),
        'http://192.168.12.64:8080/#',
      );
    });

    test('a page location names an explicitly empty fragment', () {
      final location = builtinPageLocation(
        host: '127.0.0.1',
        port: 4001,
        path: '/',
      );
      expect(
        location.hasFragment,
        isTrue,
        reason: _wanted(
          'a Location that omits the fragment component makes the browser keep '
          'the fragment of the page it entered through, and the HTTP request '
          'never shows that fragment, so the redirect has to name an empty one',
        ),
      );
      expect(location.fragment, isEmpty);
      expect(location.toString(), 'http://127.0.0.1:4001/#');
    });

    test('a remote peer takes the only usable local address of its family', () {
      expect(
        canonicalPageHost(
          peer: InternetAddress('192.168.12.50'),
          addresses: {'192.168.12.64'},
        ),
        '192.168.12.64',
      );
      expect(
        canonicalPageHost(
          peer: InternetAddress('172.16.5.9'),
          addresses: {'10.0.0.7'},
        ),
        '10.0.0.7',
        reason:
            'a single local address is the only possible destination, whatever '
            'subnet the peer is on',
      );
      expect(
        canonicalPageHost(
          peer: InternetAddress('2001:db8:1::7'),
          addresses: {'192.168.12.64', '2001:db8:1::5'},
        ),
        '2001:db8:1::5',
        reason: 'addresses of another family are never chosen',
      );
    });

    test('two same-family local addresses are ambiguous on any subnet', () {
      expect(
        canonicalPageHost(
          peer: InternetAddress('192.168.12.50'),
          addresses: {'192.168.12.64', '192.168.12.65'},
        ),
        isNull,
        reason:
            'a shared /24 is a guess: either address may be the interface the '
            'client reached',
      );
      expect(
        canonicalPageHost(
          peer: InternetAddress('192.168.12.50'),
          addresses: {'192.168.12.64', '10.0.0.7'},
        ),
        isNull,
      );
      expect(
        canonicalPageHost(
          peer: InternetAddress('2001:db8:1::7'),
          addresses: {'2001:db8:1::5', '2001:db8:2::5'},
        ),
        isNull,
        reason: 'a shared /64 is not evidence of which address was reached',
      );
    });

    test('unusable and non numeric destinations are never chosen', () {
      for (final address in [
        '0.0.0.0',
        '224.0.0.9',
        '239.1.2.3',
        '255.255.255.255',
        '::ffff:224.0.0.9',
        'localhost',
        _aliasHost,
      ]) {
        expect(
          canonicalPageHost(
            peer: InternetAddress('192.168.12.50'),
            addresses: {address},
          ),
          isNull,
          reason: '$address is not a usable destination',
        );
      }
      for (final address in [
        '::',
        'ff02::1',
        'ff0e::1',
        'fe80::1',
        'fe80::1%en0',
      ]) {
        expect(
          canonicalPageHost(
            peer: InternetAddress('2001:db8:12::50'),
            addresses: {address},
          ),
          isNull,
          reason:
              '$address is an IPv6 candidate of the peer\'s own family, so only '
              'the usability filter can reject it',
        );
      }
      expect(
        canonicalPageHost(
          peer: InternetAddress('192.168.12.50'),
          addresses: {'::', 'ff02::1', 'fe80::2'},
        ),
        isNull,
      );
      expect(
        canonicalPageHost(
          peer: InternetAddress('2001:db8:12::50'),
          addresses: {'0.0.0.0', '224.0.0.9', '255.255.255.255'},
        ),
        isNull,
      );
      expect(
        canonicalPageHost(
          peer: InternetAddress('192.168.12.50'),
          addresses: {'127.0.0.1'},
        ),
        isNull,
        reason:
            'a remote peer is never sent to loopback: 127.0.0.1 would be the '
            'client machine',
      );
      expect(
        canonicalPageHost(
          peer: InternetAddress('2001:db8:12::50'),
          addresses: {'::1'},
        ),
        isNull,
        reason:
            'a remote peer is never sent to loopback: ::1 would be the client '
            'machine',
      );
    });

    test('a usable local address of the peer family is chosen', () {
      expect(
        canonicalPageHost(
          peer: InternetAddress('2001:db8:12::50'),
          addresses: {'2001:db8:12::64'},
        ),
        '2001:db8:12::64',
        reason:
            'the safety filter rejects unusable IPv6 candidates; it does not '
            'reject IPv6 as a destination family',
      );
      expect(
        canonicalPageHost(
          peer: _ScopedPeerAddress(),
          addresses: {'2001:db8:12::64'},
        ),
        isNull,
        reason: 'a scoped peer address is not usable provenance',
      );
    });

    test('equivalent address forms are one destination', () {
      expect(
        canonicalPageHost(
          peer: InternetAddress('2001:db8::7'),
          addresses: {'2001:0DB8:0:0:0:0:0:5', '2001:db8::5'},
        ),
        '2001:db8::5',
        reason: 'the same interface in two spellings is still one destination',
      );
      expect(
        canonicalPageHost(
          peer: InternetAddress('192.168.12.50'),
          addresses: {'192.168.12.64', '::ffff:192.168.12.64'},
        ),
        '192.168.12.64',
        reason: 'an IPv4-mapped form of the same address is not a second one',
      );
      expect(
        canonicalPageHost(
          peer: InternetAddress('::ffff:192.168.12.50'),
          addresses: {'10.0.0.7', '::ffff:10.0.0.7', '192.168.12.64'},
        ),
        isNull,
        reason:
            'a mapped peer is an IPv4 peer, so two distinct IPv4 addresses '
            'remain ambiguous',
      );
      expect(
        canonicalPageHost(
          peer: InternetAddress('::ffff:192.168.12.50'),
          addresses: {'::ffff:10.0.0.7'},
        ),
        '10.0.0.7',
      );
      expect(
        canonicalPageHost(
          peer: InternetAddress('::ffff:127.0.0.1'),
          addresses: const {},
        ),
        '127.0.0.1',
        reason: 'a mapped loopback peer keeps the loopback destination',
      );
    });

    test(
      'a concrete bound listener address outranks the interface listing',
      () {
        expect(
          canonicalPageHost(
            peer: InternetAddress('192.168.12.50'),
            addresses: {'192.168.12.64', '10.0.0.7'},
            boundAddress: '10.0.0.7',
          ),
          '10.0.0.7',
        );
        expect(
          canonicalPageHost(
            peer: InternetAddress('2001:db8:1::7'),
            addresses: {'2001:db8:1::5', '2001:db8:2::5'},
            boundAddress: '2001:db8:2::5',
          ),
          '2001:db8:2::5',
        );
        expect(
          canonicalPageHost(
            peer: InternetAddress('192.168.12.50'),
            addresses: {'10.0.0.7'},
            boundAddress: '0.0.0.0',
          ),
          '10.0.0.7',
          reason: 'a wildcard bind names no address',
        );
        expect(
          canonicalPageHost(
            peer: InternetAddress('192.168.12.50'),
            addresses: {'10.0.0.7'},
            boundAddress: '127.0.0.1',
          ),
          '10.0.0.7',
          reason: 'a remote peer is never sent to loopback',
        );
        expect(
          canonicalPageHost(
            peer: InternetAddress('2001:db8:1::7'),
            addresses: {'2001:db8:2::5'},
            boundAddress: '10.0.0.7',
          ),
          '2001:db8:2::5',
          reason: 'a bound address of another family cannot serve this peer',
        );
      },
    );
  });

  group('the page entry fails closed when the destination is not unique', () {
    test('two candidate interfaces refuse the alias entry', () async {
      final addresses = <String>{'192.168.12.64', '10.0.0.7'};
      final handler = _pageEntryHandler(deviceAddresses: () async => addresses);

      final ambiguous = await _pageEntry(
        handler,
        peer: InternetAddress('192.168.12.50'),
      );
      expect(
        ambiguous.statusCode,
        403,
        reason: _wanted(
          'two current interfaces leave the destination unknown, so the alias '
          'entry is refused rather than guessed.\n'
          'status=${ambiguous.statusCode} '
          'location=${ambiguous.headers['location']}',
        ),
      );
      expect(
        await ambiguous.readAsString(),
        jsonEncode({'error': builtinPageAddressUnavailableError}),
      );

      addresses.remove('10.0.0.7');
      final unique = await _pageEntry(
        handler,
        peer: InternetAddress('192.168.12.50'),
      );
      expect(unique.statusCode, 302);
      expect(unique.headers['location'], 'http://192.168.12.64:4001/#');

      addresses.add('192.168.12.65');
      final reacquired = await _pageEntry(
        handler,
        peer: InternetAddress('192.168.12.50'),
      );
      expect(
        reacquired.statusCode,
        403,
        reason:
            'the address set is read per request, so an address that appears '
            'later makes the entry ambiguous again',
      );
    });

    test('a failing address enumeration refuses the alias entry', () async {
      final handler = _pageEntryHandler(
        deviceAddresses: () async => throw const SocketException('no listing'),
      );
      final reply = await _pageEntry(
        handler,
        peer: InternetAddress('192.168.12.50'),
      );
      expect(reply.statusCode, 403);
      expect(
        await reply.readAsString(),
        jsonEncode({'error': builtinPageAddressUnavailableError}),
      );
    });

    test('an unbound listener refuses the alias entry', () async {
      final handler = _pageEntryHandler(
        deviceAddresses: () async => {'192.168.12.64'},
        port: () => null,
      );
      final reply = await _pageEntry(handler, peer: InternetAddress('::1'));
      expect(reply.statusCode, 403);
    });

    test('a missing or malformed Host header refuses the page entry', () async {
      final handler = _pageEntryHandler(
        deviceAddresses: () async => {'192.168.12.64'},
      );
      for (final host in [
        null,
        '',
        'user@$_aliasHost',
        '$_aliasHost:abc',
        '$_aliasHost:4001:4001',
        '$_aliasHost:0',
        '$_aliasHost:65536',
        '$_aliasHost:99999',
        '[::1',
        '[localhost]',
        '[evil]',
        '[127.0.0.1]',
        '[::1]:0',
        '$_aliasHost:4001/path',
        'evil/path',
        'evil?x',
        'evil#x',
        'evil,other',
        'evil;other',
        'evil host',
        'evil\thost',
        'evil\x01host',
      ]) {
        final reply = await _pageEntry(
          handler,
          host: host,
          peer: InternetAddress('192.168.12.50'),
        );
        expect(
          reply.statusCode,
          403,
          reason:
              'the Host header ${host ?? '<absent>'} cannot be classified, so '
              'the alias page must not be served or redirected from it',
        );
      }
    });

    test('valid DNS names still reach the numeric entry', () async {
      final handler = _pageEntryHandler(
        deviceAddresses: () async => {'192.168.12.64'},
      );
      for (final host in [
        'de1tablet.home',
        'de1tablet.home.',
        'DE1TABLET.HOME:4001',
        'de1-tablet.home',
        'xn--de1tablet-9ya.example',
        'a.b.c.d.e.f',
      ]) {
        final reply = await _pageEntry(
          handler,
          host: host,
          peer: InternetAddress('192.168.12.50'),
        );
        expect(
          reply.statusCode,
          302,
          reason:
              'Host $host is a valid name that is not a numeric entry, so it '
              'still needs the redirect.\nstatus=${reply.statusCode}',
        );
        expect(reply.headers['location'], 'http://192.168.12.64:4001/#');
      }
    });

    test('a raw malformed Host is refused on the served listener', () async {
      Future<int> pageStatus(String host) async {
        final socket = await Socket.connect(
          InternetAddress.loopbackIPv4,
          surface.apiPort,
        );
        try {
          socket.write(
            'GET $_settingsPagePath HTTP/1.1\r\n'
            'Host: $host\r\n'
            'Connection: close\r\n\r\n',
          );
          await socket.flush();
          final response = await utf8
              .decodeStream(socket)
              .timeout(const Duration(seconds: 10));
          return int.parse(response.split('\r\n').first.split(' ')[1]);
        } finally {
          socket.destroy();
        }
      }

      for (final host in [
        '$_aliasHost:0',
        '$_aliasHost:65536',
        '$_aliasHost:99999',
      ]) {
        expect(
          await pageStatus(host),
          403,
          reason:
              'a raw Host of "$host" carries an unusable port, so the page '
              'entry middleware itself refuses it before the page is served or '
              'redirected',
        );
      }

      for (final host in [
        'evil/path',
        'evil?x',
        'evil#x',
        'evil,other',
        'evil host',
        '[localhost]',
      ]) {
        expect(
          await pageStatus(host),
          isNot(anyOf(200, 302)),
          reason:
              'a raw Host of "$host" cannot be classified, so the page is never '
              'served and never redirected from it',
        );
      }

      expect(
        await pageStatus('$_aliasHost:${surface.apiPort}'),
        302,
        reason: 'a valid alias Host still redirects the page entry',
      );
      expect(
        await pageStatus('127.0.0.1:${surface.apiPort}'),
        200,
        reason: 'a numeric Host still serves the page',
      );
    });

    test('numeric and localhost entries stay entries', () async {
      final handler = _pageEntryHandler(
        deviceAddresses: () async => {'192.168.12.64'},
      );
      for (final host in [
        '192.168.12.64:4001',
        '127.0.0.1:4001',
        '127.0.0.1',
        'localhost:4001',
        'localhost',
        '[::1]:4001',
        '[2001:db8::64]:4001',
      ]) {
        final reply = await _pageEntry(
          handler,
          host: host,
          peer: InternetAddress('192.168.12.50'),
        );
        expect(
          reply.statusCode,
          200,
          reason:
              'Host $host needs no redirect.\n'
              'status=${reply.statusCode}',
        );
      }
    });
  });

  group('bundled settings page', () {
    late String pageHtml;
    late List<_PageRequest> numericRequests;

    setUpAll(() async {
      final page = await surface.get(
        surface.numericPageOrigin,
        _settingsPagePath,
      );
      expect(
        page.status,
        200,
        reason: _evidence('GET $_settingsPagePath', page),
      );
      expect(
        page.header('content-type'),
        contains('text/html'),
        reason: 'the plugin host must deliver the bundled page as HTML',
      );
      expect(page.body, contains('checkSkinUpdates'));
      expect(page.body, contains('updateReaSetting'));
      expect(page.body, contains('Decent Settings'));
      pageHtml = page.body;
      numericRequests = await surface.pageRequests(
        pageHtml: pageHtml,
        pageOrigin: surface.numericPageOrigin,
      );
      for (final request in numericRequests) {
        // ignore: avoid_print
        print(
          'recorded ${request.action}: ${request.method} ${request.url} '
          'body=${request.body}',
        );
      }
    });

    test('delivers a page whose requests stay on the page origin', () {
      expect(numericRequests, hasLength(2));
      expect(numericRequests.map((request) => request.url), [
        '${surface.numericPageOrigin}$_skinUpdatePath',
        '${surface.numericPageOrigin}$_settingsPath',
      ]);
      expect(numericRequests.first.method, 'POST');
      expect(jsonDecode(numericRequests.last.body!), {
        'automaticUpdateCheck': false,
      });
    });

    test('numeric-IP page origin must be able to run its skin update request', () async {
      final request = numericRequests.first;
      final before = List.of(surface.skins.mutations);
      final reply = await _replay(
        surface,
        request,
        pageOrigin: surface.numericPageOrigin,
      );
      expect(
        reply.status,
        200,
        reason: _wanted(
          'the skin update check the page posts to ${request.url} must succeed '
          'from ${surface.numericPageOrigin}.\n'
          '${_evidence('POST $_skinUpdatePath', reply)}',
        ),
      );
      expect(
        _skinUpdateIncrements(surface.skins.mutations, before),
        1,
        reason:
            'this request must record one new skin update check of its own, not '
            'ride on a check an earlier test already recorded',
      );
    });

    test('replayed updateReaSetting request is applied from either page origin', () async {
      addTearDown(() => surface.settingsService.setAutomaticUpdateCheck(true));
      expect(surface.settings.automaticUpdateCheck, isTrue);

      final numeric = numericRequests.last;
      final numericReply = await _replay(
        surface,
        numeric,
        pageOrigin: surface.numericPageOrigin,
      );
      expect(
        numericReply.status,
        200,
        reason: _evidence('POST $_settingsPath', numericReply),
      );
      expect(surface.settings.automaticUpdateCheck, isFalse);

      await surface.settingsService.setAutomaticUpdateCheck(true);
      final aliasRequests = await surface.pageRequests(
        pageHtml: pageHtml,
        pageOrigin: surface.aliasPageOrigin,
      );
      final aliasReply = await _replay(
        surface,
        aliasRequests.last,
        pageOrigin: surface.aliasPageOrigin,
      );
      expect(
        aliasReply.status,
        200,
        reason:
            'automaticUpdateCheck=false is deliberately exempt from the browser '
            'origin gate in both modes, so this safe body is admitted from any '
            'origin. That exemption is unchanged by the redirect.\n'
            '${_evidence('POST $_settingsPath', aliasReply)}',
      );
      expect(surface.settings.automaticUpdateCheck, isFalse);
    });
  });

  group('a DNS alias is never trusted as an origin', () {
    test('the alias page origin cannot preflight a management route', () async {
      final reply = await surface.preflight(
        _skinUpdatePath,
        origin: surface.aliasPageOrigin,
      );
      expect(
        reply.status,
        403,
        reason: _evidence('OPTIONS alias page origin', reply),
      );
      expect(reply.error, untrustedBrowserOriginError);
      expect(reply.corsAllowOrigin, isEmpty);
    });

    test('the alias docs origin cannot preflight a management route', () async {
      final reply = await surface.preflight(
        _skinUpdatePath,
        origin: surface.aliasDocsOrigin,
      );
      expect(
        reply.status,
        403,
        reason: _evidence('OPTIONS alias docs origin', reply),
      );
      expect(reply.corsAllowOrigin, isEmpty);
    });

    test('the alias page origin cannot request a skin update', () async {
      final before = List.of(surface.skins.mutations);
      final reply = await surface.send(
        'POST',
        _skinUpdatePath,
        origin: surface.aliasPageOrigin,
      );
      expect(
        reply.status,
        403,
        reason: _evidence('POST alias page origin', reply),
      );
      expect(reply.error, untrustedBrowserOriginError);
      expect(reply.corsAllowOrigin, isEmpty);
      expect(surface.skins.mutations, before);
    });

    test('the alias docs origin cannot request a skin update', () async {
      final before = List.of(surface.skins.mutations);
      final reply = await surface.send(
        'POST',
        _skinUpdatePath,
        origin: surface.aliasDocsOrigin,
      );
      expect(
        reply.status,
        403,
        reason: _evidence('POST alias docs origin', reply),
      );
      expect(reply.error, untrustedBrowserOriginError);
      expect(surface.skins.mutations, before);
    });

    test('the alias page origin cannot change the default skin', () async {
      final before = List.of(surface.skins.mutations);
      final reply = await surface.send(
        'POST',
        _settingsPath,
        origin: surface.aliasPageOrigin,
        hostHeader: _aliasHost,
        body: {'defaultSkinId': 'recorded-skin'},
      );
      expect(
        reply.status,
        403,
        reason: _evidence('POST alias settings', reply),
      );
      expect(reply.error, untrustedBrowserOriginError);
      expect(reply.corsAllowOrigin, isEmpty);
      expect(surface.skins.mutations, before);
    });
  });

  group('compatibility controls that must not regress', () {
    test('originless clients keep working', () async {
      final reply = await surface.send('POST', _skinUpdatePath);
      expect(reply.status, 200, reason: _evidence('POST originless', reply));
    });

    test(
      'hostile origins are refused before the mutation without CORS',
      () async {
        final before = List.of(surface.skins.mutations);
        final reply = await surface.send(
          'POST',
          _skinUpdatePath,
          origin: _hostileOrigin,
        );
        expect(reply.status, 403, reason: _evidence('POST hostile', reply));
        expect(reply.error, untrustedBrowserOriginError);
        expect(reply.corsAllowOrigin, isEmpty);
        expect(surface.skins.mutations, before);
      },
    );

    test(
      'hostile origins cannot change the default skin without CORS',
      () async {
        final before = List.of(surface.skins.mutations);
        final reply = await surface.send(
          'POST',
          _settingsPath,
          origin: _hostileOrigin,
          body: {'defaultSkinId': 'hostile-skin'},
        );
        expect(
          reply.status,
          403,
          reason: _evidence('POST hostile settings', reply),
        );
        expect(reply.error, untrustedBrowserOriginError);
        expect(reply.corsAllowOrigin, isEmpty);
        expect(surface.skins.mutations, before);
      },
    );

    test('forged canonical Host and forwarding headers do not rescue an alias origin', () async {
      final before = List.of(surface.skins.mutations);
      final plain = await surface.send(
        'POST',
        _skinUpdatePath,
        origin: surface.aliasPageOrigin,
      );
      final forged = await surface.send(
        'POST',
        _skinUpdatePath,
        origin: surface.aliasPageOrigin,
        hostHeader: '127.0.0.1:${surface.apiPort}',
        headers: {
          'x-forwarded-host': '127.0.0.1:${surface.apiPort}',
          'x-forwarded-for': '127.0.0.1',
          'x-real-ip': '127.0.0.1',
          'forwarded': 'host=127.0.0.1:${surface.apiPort}',
        },
      );
      expect(plain.status, 403, reason: _evidence('plain', plain));
      expect(forged.status, 403, reason: _evidence('forged', forged));
      expect(forged.error, untrustedBrowserOriginError);
      expect(surface.skins.mutations, before);
    });

    test(
      'numeric origins that are not current interfaces are refused',
      () async {
        final before = List.of(surface.skins.mutations);
        final reply = await surface.send(
          'POST',
          _skinUpdatePath,
          origin: 'http://$_foreignNumericHost:${surface.apiPort}',
        );
        expect(
          reply.status,
          403,
          reason: _evidence('POST foreign numeric', reply),
        );
        expect(surface.skins.mutations, before);
      },
    );

    test('numeric origins on a current interface stay trusted', () async {
      addTearDown(
        () => surface.skinServer.browserOriginAddresses = {'127.0.0.1'},
      );
      surface.skinServer.browserOriginAddresses = {_managedInterfaceAddress};
      final reply = await surface.send(
        'POST',
        _skinUpdatePath,
        origin: 'http://$_managedInterfaceAddress:${surface.apiPort}',
      );
      expect(
        reply.status,
        200,
        reason: _evidence('POST interface numeric', reply),
      );
    });
  });

  group('scoped mode keeps enforcing credentials', () {
    late _Surface restricted;

    setUpAll(() async {
      restricted = await _Surface.start(
        requireManagementAuthorization: true,
        docsBindPort: 0,
      );
    });

    tearDownAll(() async {
      await restricted.dispose();
    });

    test('page origin without credentials is refused', () async {
      final reply = await restricted.send(
        'POST',
        _skinUpdatePath,
        origin: restricted.numericPageOrigin,
      );
      expect(reply.status, 401, reason: _evidence('POST no token', reply));
      expect(reply.error, 'Missing or malformed bearer token');
      expect(restricted.skins.mutations, isEmpty);
    });

    test('page origin with an extensions:manage token succeeds', () async {
      final before = List.of(restricted.skins.mutations);
      final reply = await restricted.send(
        'POST',
        _skinUpdatePath,
        origin: restricted.numericPageOrigin,
        headers: {'authorization': 'Bearer $managerToken'},
      );
      expect(reply.status, 200, reason: _evidence('POST with token', reply));
      expect(_skinUpdateIncrements(restricted.skins.mutations, before), 1);
    });

    test('hostile origin with a valid token is still refused', () async {
      final before = List.of(restricted.skins.mutations);
      final reply = await restricted.send(
        'POST',
        _skinUpdatePath,
        origin: _hostileOrigin,
        headers: {'authorization': 'Bearer $managerToken'},
      );
      expect(
        reply.status,
        403,
        reason: _evidence('POST hostile with token', reply),
      );
      expect(restricted.skins.mutations, before);
    });

    test('the alias page origin is refused even with a valid token', () async {
      final before = List.of(restricted.skins.mutations);
      final reply = await restricted.send(
        'POST',
        _skinUpdatePath,
        origin: restricted.aliasPageOrigin,
        headers: {'authorization': 'Bearer $managerToken'},
      );
      expect(
        reply.status,
        403,
        reason: _evidence('POST alias with token', reply),
      );
      expect(reply.error, untrustedBrowserOriginError);
      expect(restricted.skins.mutations, before);
    });

    test('the alias docs origin is refused even with a valid token', () async {
      final before = List.of(restricted.skins.mutations);
      final reply = await restricted.send(
        'POST',
        _skinUpdatePath,
        origin: restricted.aliasDocsOrigin,
        headers: {'authorization': 'Bearer $managerToken'},
      );
      expect(
        reply.status,
        403,
        reason: _evidence('POST alias docs with token', reply),
      );
      expect(restricted.skins.mutations, before);
    });

    test('the alias entry still redirects while protection is on', () async {
      final entry = await restricted.get(
        restricted.aliasPageOrigin,
        _settingsPagePath,
      );
      expect(
        entry.status,
        302,
        reason:
            'the canonicalisation is a page-entry concern and happens before '
            'authentication, so protection stays on afterwards.\n'
            '${_evidence('GET alias page', entry)}',
      );
      expect(
        entry.header('location'),
        'http://127.0.0.1:${restricted.apiPort}$_settingsPagePath#',
      );
    });

    test('originless clients still need credentials', () async {
      final reply = await restricted.send('POST', _skinUpdatePath);
      expect(reply.status, 401, reason: _evidence('POST originless', reply));
    });

    test('the docs origin the server bound is trusted but still needs credentials', () async {
      expect(
        restricted.docsPort,
        isNot(apiDocsConfiguration.port),
        reason:
            'this scope binds the docs listener on an ephemeral port, so a 200 '
            'here proves the trusted port is the listener that actually bound '
            'rather than a hardcoded 4001',
      );
      final before = List.of(restricted.skins.mutations);
      final noToken = await restricted.send(
        'POST',
        _skinUpdatePath,
        origin: restricted.numericDocsOrigin,
      );
      expect(
        noToken.status,
        401,
        reason: _evidence('POST docs origin no token', noToken),
      );
      expect(noToken.error, 'Missing or malformed bearer token');
      expect(restricted.skins.mutations, before);

      final withToken = await restricted.send(
        'POST',
        _skinUpdatePath,
        origin: restricted.numericDocsOrigin,
        headers: {'authorization': 'Bearer $managerToken'},
      );
      expect(
        withToken.status,
        200,
        reason: _evidence('POST docs origin with token', withToken),
      );
      expect(_skinUpdateIncrements(restricted.skins.mutations, before), 1);
    });

    test('a hostile docs origin is refused even with a valid token', () async {
      final before = List.of(restricted.skins.mutations);
      final reply = await restricted.send(
        'POST',
        _skinUpdatePath,
        origin: '$_hostileOrigin:${restricted.docsPort}',
        headers: {'authorization': 'Bearer $managerToken'},
      );
      expect(
        reply.status,
        403,
        reason: _evidence('POST hostile docs origin with token', reply),
      );
      expect(reply.error, untrustedBrowserOriginError);
      expect(reply.corsAllowOrigin, isEmpty);
      expect(restricted.skins.mutations, before);
    });

    test('a docs port this server did not bind is not trusted', () async {
      final before = List.of(restricted.skins.mutations);
      final reply = await restricted.send(
        'POST',
        _skinUpdatePath,
        origin: 'http://127.0.0.1:${apiDocsConfiguration.port}',
        headers: {'authorization': 'Bearer $managerToken'},
      );
      expect(
        reply.status,
        403,
        reason:
            'this scope bound its docs listener on ${restricted.docsPort}, so '
            'port ${apiDocsConfiguration.port} (never bound by this server) must '
            'stay untrusted even with a valid token.\n'
            '${_evidence('POST unbound docs port with token', reply)}',
      );
      expect(reply.error, untrustedBrowserOriginError);
      expect(restricted.skins.mutations, before);
    });
  });
}
