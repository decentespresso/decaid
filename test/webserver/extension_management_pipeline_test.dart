import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_source.dart';
import 'package:reaprime/src/plugins/plugin_source_service.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/account/decent_proxy_service.dart';
import 'package:reaprime/src/services/account/proxy_token_service.dart';
import 'package:reaprime/src/services/webserver/extension_management_auth.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/util/remote_update_report.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_plus/shelf_plus.dart';

import '../plugins/plugin_test_helpers.dart';

const _echoId = 'echo.reaplugin';
const _idleId = 'idle.reaplugin';
const _releasedId = 'installed.reaplugin';
const _defaultSkinId = 'streamline.js';
const _otherSkinId = 'other.skin';
const _trustedPagePort = 25707;
const _nextPagePort = 34101;
const _trustedDeviceAddress = '192.168.12.64';
const _untrustedLanAddress = '192.168.12.99';
const _trustedOrigin = 'http://127.0.0.1:$_trustedPagePort';
const _origin = _trustedOrigin;
const _untrustedOrigin = 'https://evil.example';
const _originRefused =
    'Extension management is not allowed from this browser origin';
const _bundledPluginIds = [
  'time-to-ready.reaplugin',
  'visualizer.reaplugin',
  'settings.reaplugin',
  'dye2.reaplugin',
  'decent-profile.reaplugin',
  'shot-upload.reaplugin',
  'dcamp.reaplugin',
];

const _missingBearer = 'Missing or malformed bearer token';
const _invalidToken = 'Invalid token';
const _unscoped = 'Token is not scoped for extensions:manage';

class _RecordingWebUIStorage extends Fake implements WebUIStorage {
  _RecordingWebUIStorage(this.root)
    : _skins = {
        for (final id in [_defaultSkinId, _otherSkinId])
          id: WebUISkin(id: id, name: id, path: '$root/skins/$id'),
      };

  final String root;
  final Map<String, WebUISkin> _skins;

  void addSkin(String id) {
    _skins[id] = WebUISkin(id: id, name: id, path: '$root/skins/$id');
  }

  final List<String> calls = [];
  String defaultSkinId = _defaultSkinId;
  RemoteUpdateReport? skinUpdateReport;

  List<String> get skinIds => _skins.keys.toList();

  @override
  List<WebUISkin> get installedSkins {
    calls.add('installedSkins');
    return _skins.values.toList();
  }

  @override
  WebUISkin? getSkin(String id) {
    calls.add('getSkin $id');
    return _skins[id];
  }

  @override
  WebUISkin? get defaultSkin {
    calls.add('defaultSkin');
    return _skins[defaultSkinId];
  }

  @override
  bool isSkinInstalled(String skinId) {
    calls.add('isSkinInstalled $skinId');
    return _skins.containsKey(skinId);
  }

  @override
  Future<void> setDefaultSkin(String skinId) async {
    calls.add('setDefaultSkin $skinId');
    if (!_skins.containsKey(skinId)) throw Exception('Skin not found: $skinId');
    defaultSkinId = skinId;
  }

  @override
  Future<void> installFromGitHubRelease(
    String repo, {
    String? assetName,
    bool includePrerelease = false,
  }) async {
    calls.add('installFromGitHubRelease $repo');
  }

  @override
  Future<void> installFromGitHub(String repo, {String branch = 'main'}) async {
    calls.add('installFromGitHub $repo $branch');
  }

  @override
  Future<void> installFromUrl(
    String url, {
    String? sourceIdentifier,
    String? releaseAssetName,
    bool? includePrerelease,
  }) async {
    calls.add('installFromUrl $url');
  }

  @override
  Future<void> updateAllSkins() async {
    calls.add('updateAllSkins');
  }

  @override
  Future<RemoteUpdateReport> checkForSkinUpdates() async {
    calls.add('checkForSkinUpdates');
    return skinUpdateReport ?? const RemoteUpdateReport([]);
  }

  @override
  Future<void> removeSkin(String skinId) async {
    calls.add('removeSkin $skinId');
    _skins.remove(skinId);
  }
}

class _RecordingWebUIService extends Fake implements WebUIService {
  final List<String> calls = [];
  bool serving = false;
  String path = '';

  @override
  int port = 3000;

  @override
  bool get isServing {
    calls.add('isServing');
    return serving;
  }

  @override
  Future<void> serveFolderAtPath(String path, {int port = 3000}) async {
    calls.add('serveFolderAtPath $path');
    this.path = path;
    serving = true;
  }

  @override
  Future<void> stopServing() async {
    calls.add('stopServing');
    serving = false;
  }

  @override
  String serverPath() {
    calls.add('serverPath');
    return path;
  }

  @override
  String serverIP() {
    calls.add('serverIP');
    return '127.0.0.1';
  }
}

class _MemoryCredentialStore implements CredentialStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read({required String key}) async => _values[key];

  @override
  Future<void> write({required String key, required String value}) async =>
      _values[key] = value;

  @override
  Future<void> delete({required String key}) async => _values.remove(key);
}

final class _Reply {
  _Reply(this.status, this.headers, this.body);

  final int status;
  final HttpHeaders headers;
  final String body;

  dynamic get json => jsonDecode(body);

  String? get error => (json as Map)['error'] as String?;

  @override
  String toString() => '$status $body';
}

final class _Credential {
  const _Credential(this.name, this.authorization, this.status, this.error);

  final String name;
  final String? authorization;
  final int status;
  final String error;
}

typedef _Caller = ({String name, String? authorization});

typedef _RouteProbe = Future<void> Function(_Caller caller);

Map<String, dynamic> _manifestJson(
  String id, {
  String version = '1.0.0',
  List<String> permissions = const ['api', 'log'],
}) => {
  'id': id,
  'author': 'Test',
  'name': id,
  'description': 'Test plugin',
  'version': version,
  'apiVersion': 1,
  'permissions': permissions,
  'settings': {
    'Label': {'type': 'string'},
  },
  'api': [
    for (final endpoint in ['echo', 'enable', 'source', 'approve'])
      {'id': endpoint, 'type': 'http', 'data': <String, dynamic>{}},
  ],
};

String _echoPluginJs(String id) =>
    '''
function createPlugin(host) {
  return {
    id: ${jsonEncode(id)},
    onLoad() {},
    handleHttpRequest: (request) => ({
      status: 200,
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({
        plugin: ${jsonEncode(id)},
        endpoint: request.endpoint,
        method: request.method,
        headers: request.headers,
      }),
    }),
  };
}
''';

List<int> _releaseArchive({
  String version = '1.0.0',
  List<String> permissions = const ['log'],
}) {
  final archive = Archive()
    ..addFile(
      ArchiveFile.string(
        'repo-main/manifest.json',
        jsonEncode(
          _manifestJson(
            _releasedId,
            version: version,
            permissions: permissions,
          ),
        ),
      ),
    )
    ..addFile(
      ArchiveFile.string('repo-main/plugin.js', _echoPluginJs(_releasedId)),
    );
  return ZipEncoder().encode(archive);
}

void _copyDirectorySync(Directory source, Directory destination) {
  destination.createSync(recursive: true);
  for (final entity in source.listSync()) {
    final target = p.join(destination.path, p.basename(entity.path));
    if (entity is Directory) {
      _copyDirectorySync(entity, Directory(target));
    } else if (entity is File) {
      entity.copySync(target);
    }
  }
}

void _expectBundledPluginFixtureShape(Directory root) {
  for (final id in _bundledPluginIds) {
    final pluginDir = Directory('${root.path}/plugins/$id');
    expect(pluginDir.existsSync(), isTrue, reason: pluginDir.path);
    expect(
      File('${pluginDir.path}/manifest.json').existsSync(),
      isTrue,
      reason: pluginDir.path,
    );
    expect(
      File('${pluginDir.path}/plugin.js').existsSync(),
      isTrue,
      reason: pluginDir.path,
    );
  }
}

String _concretePath(ExtensionManagementRoute route) {
  final id = route.path.startsWith('/api/v1/webui/')
      ? _otherSkinId
      : route.path.endsWith('/enable')
      ? _idleId
      : _echoId;
  return route.path.replaceAll('<id>', id);
}

Object? _bodyFor(ExtensionManagementRoute route) {
  final path = route.path;
  if (path.endsWith('/settings')) return {'Label': 'refused'};
  if (path.endsWith('/source')) {
    return {
      'manifest': _manifestJson(_echoId, version: '9.0.0'),
      'plugin': _echoPluginJs(_echoId),
    };
  }
  if (path.endsWith('/skins/default')) return {'skinId': _otherSkinId};
  if (path.contains('/install')) {
    return {'repo': 'acme/plugin', 'url': 'https://example.test/skin.zip'};
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  late Directory tempDir;
  late Directory fixtureDir;
  late Directory supportDir;
  late FakeKeyValueStoreService kvStore;
  late PluginLoaderService service;
  late PluginSourceService sources;
  late _RecordingWebUIStorage storage;
  late _RecordingWebUIService webUi;
  late ProxyTokenService tokens;
  late List<http.BaseRequest> gitHubRequests;
  late List<http.BaseRequest> accountUpstream;
  late String releaseTag;
  late List<int> releaseArchive;
  late Handler routes;
  Handler? activeHandler;
  late HttpServer server;
  late int listenerPort;
  late HttpClient client;
  late List<HttpServer> extraServers;

  late String managerToken;
  late String accountToken;
  late String accountWriteToken;
  late String revokedToken;
  late String unknownToken;
  late String staleToken;
  late bool protectedMode;
  late int securityReads;
  late Set<int> browserPagePorts;
  late Set<String> browserDeviceAddresses;
  late _MemoryCredentialStore pluginCredentials;
  final connections = <({String remote, int remotePort, int localPort})>[];

  List<_Caller> legacyCredentials() => [
    (name: 'no bearer', authorization: null),
    (name: 'a stale bearer', authorization: 'Bearer $staleToken'),
    (name: 'a revoked bearer', authorization: 'Bearer $revokedToken'),
    (name: 'an unknown bearer', authorization: 'Bearer $unknownToken'),
    (name: 'a wrong-scope bearer', authorization: 'Bearer $accountToken'),
    (name: 'a malformed header', authorization: 'Basic $managerToken'),
    (name: 'an empty bearer', authorization: 'Bearer '),
  ];
  List<_Credential> refusedCredentials() => [
    const _Credential('no bearer', null, 401, _missingBearer),
    _Credential(
      'a malformed bearer',
      'Basic $managerToken',
      401,
      _missingBearer,
    ),
    const _Credential('an empty bearer', 'Bearer ', 401, _missingBearer),
    _Credential(
      'an unknown bearer',
      'Bearer $unknownToken',
      401,
      _invalidToken,
    ),
    _Credential('a revoked bearer', 'Bearer $revokedToken', 401, _invalidToken),
    _Credential(
      'an account:proxy token',
      'Bearer $accountToken',
      403,
      _unscoped,
    ),
    _Credential(
      'an account:proxy + account:proxy:write token',
      'Bearer $accountWriteToken',
      403,
      _unscoped,
    ),
    _Credential('the skin token', 'Bearer ${tokens.skinToken}', 403, _unscoped),
  ];

  http.Client gitHubClient() => MockClient((request) async {
    gitHubRequests.add(request);
    final url = request.url.toString();
    if (url.contains('/releases/latest') || url.contains('/releases/tags/')) {
      return http.Response(
        jsonEncode({
          'tag_name': releaseTag,
          'assets': [
            {
              'name': 'plugin.zip',
              'browser_download_url': 'https://example.test/plugin.zip',
            },
          ],
        }),
        200,
      );
    }
    if (url.contains('/commits/')) {
      return http.Response(jsonEncode({'sha': 'commit-1'}), 200);
    }
    return http.Response.bytes(releaseArchive, 200);
  });

  Future<HttpServer> serve(Handler handler) async {
    final listener = await http.runWithClient(
      () => shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0),
      gitHubClient,
    );
    extraServers.add(listener);
    return listener;
  }

  Future<HttpServer> bind(InternetAddress address) => shelf_io.serve(
    (Request request) async {
      final info = request.context['shelf.io.connection_info'];
      if (info is HttpConnectionInfo) {
        connections.add((
          remote: info.remoteAddress.address,
          remotePort: info.remotePort,
          localPort: info.localPort,
        ));
      }
      final handler = activeHandler;
      if (handler == null) return Response.internalServerError();
      return http.runWithClient(() => handler(request), gitHubClient);
    },
    address,
    0,
  );

  Future<T> withGitHub<T>(Future<T> Function() body) =>
      http.runWithClient(body, gitHubClient);

  Handler pipeline({AdmissionGate? gate}) => buildWebServerHandler(
    routes,
    proxyTokenService: tokens,
    requireExtensionManagementAuthorization: () async {
      securityReads += 1;
      return protectedMode;
    },
    browserOrigins: ExtensionManagementBrowserOrigins(
      apiListenerPort: () => listenerPort,
      pagePorts: () => browserPagePorts,
      deviceAddresses: () async => browserDeviceAddresses,
    ),
    admissionGate:
        gate ??
        AdmissionGate(
          globalConcurrent: 512,
          perClientConcurrent: 512,
          globalRate: 100000,
          perClientRate: 100000,
          maxTrackedClients: 16,
        ),
  );

  void useMode(bool required) {
    protectedMode = required;
    activeHandler = pipeline();
  }

  Future<_Reply> send(
    String method,
    String path, {
    String? authorization,
    Object? body,
    Map<String, String> headers = const {},
    HttpServer? to,
    String host = '127.0.0.1',
  }) async {
    final port = (to ?? server).port;
    final request = await client.openUrl(
      method,
      Uri(scheme: 'http', host: host, port: port, path: path),
    );
    request.followRedirects = false;
    if (authorization != null) {
      request.headers.set(HttpHeaders.authorizationHeader, authorization);
    }
    headers.forEach(request.headers.set);
    if (body != null) {
      request.headers.contentType = ContentType.json;
      request.write(body is String ? body : jsonEncode(body));
    }
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    return _Reply(response.statusCode, response.headers, text);
  }

  Future<({int status, String body})> rawSocketRequest(
    InternetAddress target,
    int port,
    String method,
    String path, {
    InternetAddress? sourceAddress,
    String? authorization,
    Map<String, String> headers = const {},
    Object? body,
    String hostHeader = '127.0.0.1',
  }) async {
    final socket = await Socket.connect(
      target,
      port,
      sourceAddress: sourceAddress,
    );
    try {
      final payload = body == null ? null : jsonEncode(body);
      final head = StringBuffer()
        ..write('$method $path HTTP/1.1\r\n')
        ..write('Host: $hostHeader\r\n')
        ..write('Connection: close\r\n');
      if (authorization != null) {
        head.write('Authorization: $authorization\r\n');
      }
      headers.forEach((name, value) => head.write('$name: $value\r\n'));
      if (payload == null) {
        head.write('Content-Length: 0\r\n');
      } else {
        head
          ..write('Content-Type: application/json\r\n')
          ..write('Content-Length: ${utf8.encode(payload).length}\r\n');
      }
      head.write('\r\n');
      socket.write(head.toString());
      if (payload != null) socket.write(payload);
      await socket.flush();
      final raw = await utf8.decoder.bind(socket).join();
      final status = int.parse(raw.split('\r\n').first.split(' ')[1]);
      return (status: status, body: raw.substring(raw.indexOf('\r\n\r\n') + 4));
    } finally {
      socket.destroy();
    }
  }

  Future<_Reply> sendRaw(String requestLine, {HttpServer? to}) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      (to ?? server).port,
    );
    socket.write(
      '$requestLine\r\nHost: 127.0.0.1\r\nContent-Length: 0\r\n'
      'Connection: close\r\n\r\n',
    );
    await socket.flush();
    final raw = await utf8.decoder.bind(socket).join();
    socket.destroy();
    final status = int.parse(raw.split('\r\n').first.split(' ')[1]);
    final body = raw.substring(raw.indexOf('\r\n\r\n') + 4);
    return _Reply(status, _NoHeaders(), body);
  }

  void copyLocalPlugin(String id) {
    _copyDirectorySync(
      Directory('${fixtureDir.path}/source_$id'),
      Directory('${tempDir.path}/plugins/$id'),
    );
  }

  Future<Map<String, Object?>> snapshot() async {
    final pluginsDir = Directory('${tempDir.path}/plugins');
    final files = <String, String>{};
    if (pluginsDir.existsSync()) {
      for (final entity in pluginsDir.listSync(recursive: true)) {
        if (entity is File) {
          files[entity.path] = base64Encode(entity.readAsBytesSync());
        }
      }
    }
    return {
      'plugins': [
        for (final manifest in service.availablePlugins)
          {
            'id': manifest.id,
            'version': manifest.version,
            'permissions': manifest.permissions.map((p) => p.name).toList(),
            'loaded': service.isPluginLoaded(manifest.id),
            'autoLoad': await service.shouldAutoLoad(manifest.id),
            'settings': await service.pluginSettings(manifest.id),
            'source': sources.sourceFor(manifest.id)?.toJson(),
          },
      ],
      'files': files,
      'kv': {
        for (final namespace in kvStore.namespaces)
          namespace: await kvStore.getAll(namespace: namespace),
      },
      'storageCalls': List.of(storage.calls),
      'skins': storage.skinIds,
      'defaultSkin': storage.defaultSkinId,
      'webUiCalls': List.of(webUi.calls),
      'serving': webUi.serving,
      'gitHubRequests': gitHubRequests.length,
      'accountUpstream': accountUpstream.length,
    };
  }

  Future<Map<String, dynamic>> listedPlugin(String id) async {
    final reply = await send('GET', '/api/v1/plugins');
    return (reply.json as List).cast<Map<String, dynamic>>().firstWhere(
      (plugin) => plugin['id'] == id,
    );
  }

  setUpAll(() async {
    fixtureDir = Directory.systemTemp.createTempSync(
      'extension_mgmt_pipeline_fixture',
    );
    supportDir = fixtureDir;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => supportDir.path,
        );

    SharedPreferences.setMockInitialValues({
      for (final id in _bundledPluginIds) 'plugin.autoload.$id': false,
    });
    final fixtureService = PluginLoaderService(
      kvStore: FakeKeyValueStoreService(),
    );
    await fixtureService.initialize();
    await fixtureService.dispose();

    for (final id in [_echoId, _idleId]) {
      final source = Directory('${fixtureDir.path}/source_$id')
        ..createSync(recursive: true);
      File('${source.path}/manifest.json')
          .writeAsStringSync(jsonEncode(_manifestJson(id)));
      File('${source.path}/plugin.js').writeAsStringSync(_echoPluginJs(id));
    }

    server = await bind(InternetAddress.loopbackIPv4);
    listenerPort = server.port;
  });

  Future<void> initializeTestContext() async {
    SharedPreferences.setMockInitialValues({
      for (final id in _bundledPluginIds) 'plugin.autoload.$id': false,
      'plugin.autoload.$_echoId': true,
      'plugin.autoload.$_idleId': false,
    });
    tempDir = Directory.systemTemp.createTempSync('extension_mgmt_pipeline');
    supportDir = tempDir;
    _copyDirectorySync(
      Directory('${fixtureDir.path}/plugins'),
      Directory('${tempDir.path}/plugins'),
    );
    _expectBundledPluginFixtureShape(tempDir);
    copyLocalPlugin(_echoId);
    copyLocalPlugin(_idleId);
    gitHubRequests = [];
    accountUpstream = [];
    extraServers = [];
    releaseTag = 'v1.0.0';
    releaseArchive = _releaseArchive();

    kvStore = FakeKeyValueStoreService();
    pluginCredentials = _MemoryCredentialStore();
    service = PluginLoaderService(
      kvStore: kvStore,
      credentialStore: pluginCredentials,
    );
    await service.initialize();
    for (final id in _bundledPluginIds) {
      if (service.getPluginManifest(id) != null) await service.removePlugin(id);
    }
    sources = PluginSourceService(service);

    storage = _RecordingWebUIStorage(tempDir.path);
    webUi = _RecordingWebUIService();

    managerToken = ProxyTokenService.generateToken();
    accountToken = ProxyTokenService.generateToken();
    accountWriteToken = ProxyTokenService.generateToken();
    revokedToken = ProxyTokenService.generateToken();
    unknownToken = ProxyTokenService.generateToken();
    tokens = ProxyTokenService()
      ..registerToken(
        managerToken,
        const ProxyCaller(
          id: 'api:fleet',
          scopes: {ProxyTokenService.scopeExtensionsManage},
          label: 'fleet',
        ),
      )
      ..registerToken(
        accountToken,
        const ProxyCaller(
          id: 'api:account',
          scopes: {ProxyTokenService.scopeAccountProxy},
        ),
      )
      ..registerToken(
        accountWriteToken,
        const ProxyCaller(
          id: 'api:account-write',
          scopes: {
            ProxyTokenService.scopeAccountProxy,
            ProxyTokenService.scopeAccountProxyWrite,
          },
        ),
      )
      ..registerToken(
        revokedToken,
        const ProxyCaller(
          id: 'api:revoked',
          scopes: {ProxyTokenService.scopeExtensionsManage},
        ),
      )
      ..revokeToken(revokedToken);
    staleToken = tokens.skinToken;
    tokens.rotateSkinToken(const ProxyCaller(id: 'skin', scopes: {}));

    final credentials = _MemoryCredentialStore();
    await credentials.write(key: 'email', value: 'user@example.com');
    await credentials.write(key: 'password', value: 'cryptpw_abc123');
    final proxy = DecentProxyService(
      requireConsent: (_) async => true,
      httpClient: MockClient((request) async {
        accountUpstream.add(request);
        return http.Response('SN001\nSN002', 200);
      }),
      credentialStore: credentials,
    );

    final app = createApiRouter();
    PluginsHandler(
      pluginManager: service.pluginManager,
      pluginService: service,
      pluginSourceService: sources,
    ).addRoutes(app);
    WebUIHandler(storage: storage, service: webUi).addRoutes(app);
    AccountProxyHandler(proxy: proxy, enableWrites: true).addRoutes(app);
    routes = app.call;
    protectedMode = true;
    securityReads = 0;
    browserPagePorts = {_trustedPagePort};
    browserDeviceAddresses = {_trustedDeviceAddress};
    activeHandler = pipeline();
    client = HttpClient();
  }

  Future<void> disposeTestContext() async {
    activeHandler = null;
    client.close(force: true);
    for (final listener in extraServers) {
      await listener.close(force: true);
    }
    await service.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  }

  setUp(initializeTestContext);

  tearDown(disposeTestContext);

  tearDownAll(() async {
    await server.close(force: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (fixtureDir.existsSync()) fixtureDir.deleteSync(recursive: true);
  });

  group('refused management requests over HTTP', () {
    for (final route in extensionManagementRoutes) {
      test('$route is refused for every missing or unscoped credential '
          'with no side effect', () async {
        final before = await snapshot();
        for (final credential in refusedCredentials()) {
          final reply = await send(
            route.method,
            _concretePath(route),
            authorization: credential.authorization,
            body: _bodyFor(route),
          );
          expect(reply.status, credential.status, reason: credential.name);
          expect(reply.error, credential.error, reason: credential.name);
          expect(
            reply.headers.value(HttpHeaders.wwwAuthenticateHeader),
            credential.status == 401 ? 'Bearer' : isNull,
            reason: credential.name,
          );
        }
        expect(await snapshot(), before);
        expect(gitHubRequests, isEmpty);
        expect(storage.calls, isEmpty);
        expect(webUi.calls, isEmpty);
      });
    }

    test(
      'a rotated-away skin token is a stale credential when protected',
      () async {
        final before = await snapshot();
        final reply = await send(
          'POST',
          '/api/v1/plugins/$_idleId/enable',
          authorization: 'Bearer $staleToken',
        );
        expect(reply.status, 401, reason: '$reply');
        expect(reply.error, _invalidToken);
        expect(await snapshot(), before);
        expect(service.isPluginLoaded(_idleId), isFalse);
      },
    );

    test('path spellings the router canonicalises are still refused', () async {
      final before = await snapshot();
      for (final requestLine in [
        'POST /api/v1/plugins/$_idleId/%65nable HTTP/1.1',
        'POST /api/v1/plugins/$_idleId/./enable HTTP/1.1',
        'POST /api/v1/plugins/x/../$_idleId/enable HTTP/1.1',
        'DELETE /api/v1/plugins/%69dle.reaplugin HTTP/1.1',
      ]) {
        final reply = await sendRaw(requestLine);
        expect(reply.status, 401, reason: requestLine);
        expect(reply.error, _missingBearer, reason: requestLine);
      }
      expect(await snapshot(), before);
    });

    test(
      'path spellings the router does not route reach no management handler',
      () async {
        final before = await snapshot();
        for (final requestLine in [
          'POST /api/v1/plugins/$_idleId/enable/ HTTP/1.1',
          'POST /api/v1/plugins/$_idleId/ENABLE HTTP/1.1',
          'POST /API/v1/plugins/$_idleId/enable HTTP/1.1',
          'POST /api/v1/plugins/$_idleId%2Fenable HTTP/1.1',
        ]) {
          final reply = await sendRaw(requestLine);
          expect(reply.status, 404, reason: '$requestLine -> $reply');
        }
        expect(await snapshot(), before);
        expect(service.isPluginLoaded(_idleId), isFalse);
      },
    );
  });

  for (final required in [true, false]) {
    group('authorized management requests keep their handler semantics '
        '(${required ? 'protected' : 'compatibility'})', () {
      setUp(() => useMode(required));

      String? bearer() => required ? 'Bearer $managerToken' : null;

      test('PUT source creates a plugin and validation stays 400', () async {
        const id = 'fresh.reaplugin';
        final created = await send(
          'PUT',
          '/api/v1/plugins/$id/source',
          authorization: bearer(),
          body: {'manifest': _manifestJson(id), 'plugin': _echoPluginJs(id)},
        );
        expect(created.status, 200, reason: '$created');
        expect(created.json, containsPair('version', '1.0.0'));
        expect(service.getPluginManifest(id), isNotNull);
        expect(
          File('${tempDir.path}/plugins/$id/plugin.js').existsSync(),
          isTrue,
        );

        final invalid = await send(
          'PUT',
          '/api/v1/plugins/$id/source',
          authorization: bearer(),
          body: {'plugin': _echoPluginJs(id)},
        );
        expect(invalid.status, 400);
        expect(invalid.error, 'manifest object is required');
      });

      test(
        'enable, disable, settings and delete apply; unknown ids are 404',
        () async {
          final enabled = await send(
            'POST',
            '/api/v1/plugins/$_idleId/enable',
            authorization: bearer(),
          );
          expect(enabled.status, 200, reason: '$enabled');
          expect(service.isPluginLoaded(_idleId), isTrue);

          final disabled = await send(
            'POST',
            '/api/v1/plugins/$_idleId/disable',
            authorization: bearer(),
          );
          expect(disabled.status, 200, reason: '$disabled');
          expect(service.isPluginLoaded(_idleId), isFalse);
          expect(await service.shouldAutoLoad(_idleId), isFalse);

          final saved = await send(
            'POST',
            '/api/v1/plugins/$_idleId/settings',
            authorization: bearer(),
            body: {'Label': 'remote'},
          );
          expect(saved.status, 200, reason: '$saved');
          expect(
            await service.pluginSettings(_idleId),
            containsPair('Label', 'remote'),
          );

          final removed = await send(
            'DELETE',
            '/api/v1/plugins/$_idleId',
            authorization: bearer(),
          );
          expect(removed.status, 200, reason: '$removed');
          expect(service.getPluginManifest(_idleId), isNull);

          for (final (method, path) in [
            ('POST', '/api/v1/plugins/$_idleId/enable'),
            ('POST', '/api/v1/plugins/$_idleId/disable'),
            ('DELETE', '/api/v1/plugins/$_idleId'),
            ('POST', '/api/v1/plugins/$_idleId/update/approve'),
          ]) {
            final missing = await send(method, path, authorization: bearer());
            expect(missing.status, 404, reason: '$method $path');
          }
        },
      );

      test('GitHub install, update, approval and the 409 without a pending '
          'update', () async {
        final installed = await send(
          'POST',
          '/api/v1/plugins/install/github-release',
          authorization: bearer(),
          body: {'repo': 'acme/plugin'},
        );
        expect(installed.status, 200, reason: '$installed');
        expect(installed.json, containsPair('id', _releasedId));
        expect(gitHubRequests, isNotEmpty);
        expect(
          (await listedPlugin(_releasedId))['source']['repo'],
          'acme/plugin',
        );

        final noPending = await send(
          'POST',
          '/api/v1/plugins/$_releasedId/update/approve',
          authorization: bearer(),
        );
        expect(noPending.status, 409, reason: '$noPending');

        releaseTag = 'v1.1.0';
        releaseArchive = _releaseArchive(
          version: '1.1.0',
          permissions: ['log', 'proxy.decent_api'],
        );
        final updated = await send(
          'POST',
          '/api/v1/plugins/update',
          authorization: bearer(),
        );
        expect(updated.status, 200, reason: '$updated');
        final pending = await listedPlugin(_releasedId);
        expect(pending['version'], '1.0.0');
        expect(pending['pendingUpdate']['addedPermissions'], [
          'proxy.decent_api',
        ]);

        final approved = await send(
          'POST',
          '/api/v1/plugins/$_releasedId/update/approve',
          authorization: bearer(),
        );
        expect(approved.status, 200, reason: '$approved');
        final after = await listedPlugin(_releasedId);
        expect(after['version'], '1.1.0');
        expect(after['pendingUpdate'], isNull);

        final missingRepo = await send(
          'POST',
          '/api/v1/plugins/install/github-release',
          authorization: bearer(),
          body: <String, dynamic>{},
        );
        expect(missingRepo.status, 400);

        final urlInstall = await send(
          'POST',
          '/api/v1/plugins/install',
          authorization: bearer(),
          body: {'url': 'https://example.test/plugin.zip'},
        );
        expect(urlInstall.status, 501);
      });

      test(
        'skin update returns 200 with per-item results on partial failure',
        () async {
          storage.skinUpdateReport = const RemoteUpdateReport([
            RemoteUpdateItemResult(
              item: 'a/b',
              status: RemoteUpdateStatus.updated,
            ),
            RemoteUpdateItemResult(
              item: 'c/d',
              status: RemoteUpdateStatus.failed,
              error: SocketException('offline'),
            ),
          ]);

          final reply = await send(
            'POST',
            '/api/v1/webui/skins/update',
            authorization: bearer(),
          );
          expect(reply.status, 200, reason: '$reply');
          final json = reply.json as Map<String, dynamic>;
          expect(json['message'], 'Skin update check completed');
          final results = (json['results'] as List)
              .cast<Map<String, dynamic>>();
          expect(results, hasLength(2));
          expect(results[0], {'item': 'a/b', 'status': 'updated'});
          expect(results[1], {
            'item': 'c/d',
            'status': 'failed',
            'error': 'Check your internet connection and try again.',
          });
        },
      );

      test(
        'skin default, install, removal and the skin server apply',
        () async {
          final setDefault = await send(
            'PUT',
            '/api/v1/webui/skins/default',
            authorization: bearer(),
            body: {'skinId': _otherSkinId},
          );
          expect(setDefault.status, 200, reason: '$setDefault');
          expect(storage.defaultSkinId, _otherSkinId);

          final missingId = await send(
            'PUT',
            '/api/v1/webui/skins/default',
            authorization: bearer(),
            body: <String, dynamic>{},
          );
          expect(missingId.status, 400);

          final unknownSkin = await send(
            'PUT',
            '/api/v1/webui/skins/default',
            authorization: bearer(),
            body: {'skinId': 'nope.skin'},
          );
          expect(unknownSkin.status, 404);

          final installed = await send(
            'POST',
            '/api/v1/webui/skins/install/github-release',
            authorization: bearer(),
            body: {'repo': 'acme/skin'},
          );
          expect(installed.status, 200, reason: '$installed');
          expect(storage.calls, contains('installFromGitHubRelease acme/skin'));

          final noRepo = await send(
            'POST',
            '/api/v1/webui/skins/install/github-branch',
            authorization: bearer(),
            body: <String, dynamic>{},
          );
          expect(noRepo.status, 400);

          final started = await send(
            'POST',
            '/api/v1/webui/server/start',
            authorization: bearer(),
          );
          expect(started.status, 200, reason: '$started');
          expect(webUi.serving, isTrue);
          expect(webUi.path, '${tempDir.path}/skins/$_otherSkinId');

          final stopped = await send(
            'POST',
            '/api/v1/webui/server/stop',
            authorization: bearer(),
          );
          expect(stopped.status, 200, reason: '$stopped');
          expect(webUi.serving, isFalse);

          final removed = await send(
            'DELETE',
            '/api/v1/webui/skins/$_otherSkinId',
            authorization: bearer(),
          );
          expect(removed.status, 200, reason: '$removed');
          expect(storage.skinIds, isNot(contains(_otherSkinId)));
        },
      );
    });
  }

  group('every management route runs its real handler', () {
    var fresh = 0;
    String freshId(String name) => '$name-${++fresh}.reaplugin';

    final probes = <String, _RouteProbe>{
      'POST /api/v1/plugins/install': (caller) async {
        final reply = await send(
          'POST',
          '/api/v1/plugins/install',
          authorization: caller.authorization,
          body: {'url': 'https://example.test/plugin.zip'},
        );
        expect(reply.status, 501, reason: '${caller.name}: $reply');
        expect(reply.error, contains('not supported'), reason: caller.name);
      },
      'POST /api/v1/plugins/install/github-release': (caller) async {
        final polls = gitHubRequests.length;
        final reply = await send(
          'POST',
          '/api/v1/plugins/install/github-release',
          authorization: caller.authorization,
          body: {'repo': 'acme/plugin'},
        );
        expect(reply.status, 200, reason: '${caller.name}: $reply');
        expect(
          reply.json,
          containsPair('id', _releasedId),
          reason: caller.name,
        );
        expect(gitHubRequests.length, greaterThan(polls), reason: caller.name);
        expect(
          sources.sourceFor(_releasedId)?.kind,
          PluginSourceKind.githubRelease,
          reason: caller.name,
        );
      },
      'POST /api/v1/plugins/install/github-branch': (caller) async {
        final reply = await send(
          'POST',
          '/api/v1/plugins/install/github-branch',
          authorization: caller.authorization,
          body: {'repo': 'acme/branch'},
        );
        expect(reply.status, 200, reason: '${caller.name}: $reply');
        expect(
          sources.sourceFor(_releasedId)?.kind,
          PluginSourceKind.githubBranch,
          reason: caller.name,
        );
        expect(
          sources.sourceFor(_releasedId)?.commit,
          'commit-1',
          reason: caller.name,
        );
      },
      'POST /api/v1/plugins/update': (caller) async {
        await withGitHub(() => sources.installFromGitHubRelease('acme/plugin'));
        final checked = sources.sourceFor(_releasedId)?.lastChecked;
        final reply = await send(
          'POST',
          '/api/v1/plugins/update',
          authorization: caller.authorization,
        );
        expect(reply.status, 200, reason: '${caller.name}: $reply');
        expect(
          (reply.json as Map)['message'],
          'Plugin update check complete',
          reason: caller.name,
        );
        expect(
          sources.sourceFor(_releasedId)?.lastChecked,
          isNot(checked),
          reason: caller.name,
        );
      },
      'POST /api/v1/plugins/<id>/settings': (caller) async {
        final reply = await send(
          'POST',
          '/api/v1/plugins/$_echoId/settings',
          authorization: caller.authorization,
          body: {'Label': 'legacy'},
        );
        expect(reply.status, 200, reason: '${caller.name}: $reply');
        expect(
          await service.pluginSettings(_echoId),
          containsPair('Label', 'legacy'),
          reason: caller.name,
        );
      },
      'PUT /api/v1/plugins/<id>/source': (caller) async {
        final id = freshId('source');
        final reply = await send(
          'PUT',
          '/api/v1/plugins/$id/source',
          authorization: caller.authorization,
          body: {
            'manifest': _manifestJson(id, version: '1.0.1'),
            'plugin': _echoPluginJs(id),
          },
        );
        expect(reply.status, 200, reason: '${caller.name}: $reply');
        expect(
          service.getPluginManifest(id)?.version,
          '1.0.1',
          reason: caller.name,
        );
        expect(
          File('${tempDir.path}/plugins/$id/plugin.js').existsSync(),
          isTrue,
          reason: caller.name,
        );
      },
      'POST /api/v1/plugins/<id>/enable': (caller) async {
        final reply = await send(
          'POST',
          '/api/v1/plugins/$_idleId/enable',
          authorization: caller.authorization,
        );
        expect(reply.status, 200, reason: '${caller.name}: $reply');
        expect(service.isPluginLoaded(_idleId), isTrue, reason: caller.name);
        await service.disablePlugin(_idleId);
      },
      'POST /api/v1/plugins/<id>/disable': (caller) async {
        final reply = await send(
          'POST',
          '/api/v1/plugins/$_echoId/disable',
          authorization: caller.authorization,
        );
        expect(reply.status, 200, reason: '${caller.name}: $reply');
        expect(service.isPluginLoaded(_echoId), isFalse, reason: caller.name);
        expect(
          await service.shouldAutoLoad(_echoId),
          isFalse,
          reason: caller.name,
        );
        await service.enablePlugin(_echoId);
      },
      'POST /api/v1/plugins/<id>/update/approve': (caller) async {
        final reply = await send(
          'POST',
          '/api/v1/plugins/$_echoId/update/approve',
          authorization: caller.authorization,
        );
        expect(reply.status, 409, reason: '${caller.name}: $reply');
        expect(
          reply.error,
          contains('no update awaiting approval'),
          reason: caller.name,
        );
      },
      'DELETE /api/v1/plugins/<id>': (caller) async {
        final id = freshId('delete');
        await service.updatePluginSource(
          id,
          manifestJson: _manifestJson(id),
          pluginJs: _echoPluginJs(id),
        );
        final reply = await send(
          'DELETE',
          '/api/v1/plugins/$id',
          authorization: caller.authorization,
        );
        expect(reply.status, 200, reason: '${caller.name}: $reply');
        expect(service.getPluginManifest(id), isNull, reason: caller.name);
        expect(
          Directory('${tempDir.path}/plugins/$id').existsSync(),
          isFalse,
          reason: caller.name,
        );
      },
      'PUT /api/v1/webui/skins/default': (caller) async {
        final reply = await send(
          'PUT',
          '/api/v1/webui/skins/default',
          authorization: caller.authorization,
          body: {'skinId': _otherSkinId},
        );
        expect(reply.status, 200, reason: '${caller.name}: $reply');
        expect(storage.defaultSkinId, _otherSkinId, reason: caller.name);
        storage.defaultSkinId = _defaultSkinId;
      },
      'POST /api/v1/webui/skins/install/github-release': (caller) async {
        final reply = await send(
          'POST',
          '/api/v1/webui/skins/install/github-release',
          authorization: caller.authorization,
          body: {'repo': 'acme/skin'},
        );
        expect(reply.status, 200, reason: '${caller.name}: $reply');
        expect(
          storage.calls,
          contains('installFromGitHubRelease acme/skin'),
          reason: caller.name,
        );
      },
      'POST /api/v1/webui/skins/install/github-branch': (caller) async {
        final reply = await send(
          'POST',
          '/api/v1/webui/skins/install/github-branch',
          authorization: caller.authorization,
          body: {'repo': 'acme/skin'},
        );
        expect(reply.status, 200, reason: '${caller.name}: $reply');
        expect(
          storage.calls,
          contains('installFromGitHub acme/skin main'),
          reason: caller.name,
        );
      },
      'POST /api/v1/webui/skins/install/url': (caller) async {
        final reply = await send(
          'POST',
          '/api/v1/webui/skins/install/url',
          authorization: caller.authorization,
          body: {'url': 'https://example.test/skin.zip'},
        );
        expect(reply.status, 200, reason: '${caller.name}: $reply');
        expect(
          storage.calls,
          contains('installFromUrl https://example.test/skin.zip'),
          reason: caller.name,
        );
      },
      'POST /api/v1/webui/skins/update': (caller) async {
        storage.calls.clear();
        final reply = await send(
          'POST',
          '/api/v1/webui/skins/update',
          authorization: caller.authorization,
        );
        expect(reply.status, 200, reason: '${caller.name}: $reply');
        expect(
          storage.calls,
          contains('checkForSkinUpdates'),
          reason: caller.name,
        );
      },
      'DELETE /api/v1/webui/skins/<id>': (caller) async {
        storage.addSkin(_otherSkinId);
        final reply = await send(
          'DELETE',
          '/api/v1/webui/skins/$_otherSkinId',
          authorization: caller.authorization,
        );
        expect(reply.status, 200, reason: '${caller.name}: $reply');
        expect(
          storage.skinIds,
          isNot(contains(_otherSkinId)),
          reason: caller.name,
        );
      },
      'POST /api/v1/webui/server/start': (caller) async {
        webUi
          ..serving = false
          ..calls.clear();
        final reply = await send(
          'POST',
          '/api/v1/webui/server/start',
          authorization: caller.authorization,
        );
        expect(reply.status, 200, reason: '${caller.name}: $reply');
        expect(
          webUi.calls,
          contains('serveFolderAtPath ${tempDir.path}/skins/$_defaultSkinId'),
          reason: caller.name,
        );
        expect(webUi.serving, isTrue, reason: caller.name);
      },
      'POST /api/v1/webui/server/stop': (caller) async {
        webUi
          ..serving = true
          ..calls.clear();
        final reply = await send(
          'POST',
          '/api/v1/webui/server/stop',
          authorization: caller.authorization,
        );
        expect(reply.status, 200, reason: '${caller.name}: $reply');
        expect(webUi.calls, contains('stopServing'), reason: caller.name);
        expect(webUi.serving, isFalse, reason: caller.name);
      },
    };

    test('the probe table covers all 18 gated routes', () {
      expect(probes.keys.toSet(), {
        for (final route in extensionManagementRoutes) route.toString(),
      });
    });

    for (final required in [true, false]) {
      group(required ? 'protected mode' : 'compatibility mode', () {
        setUp(() => useMode(required));

        for (final route in extensionManagementRoutes) {
          test('$route', () async {
            final probe = probes[route.toString()]!;
            for (final caller
                in required
                    ? <_Caller>[
                        (
                          name: 'an extensions:manage token',
                          authorization: 'Bearer $managerToken',
                        ),
                      ]
                    : legacyCredentials()) {
              storage.calls.clear();
              await probe(caller);
            }
          });
        }
      });
    }
  });

  for (final required in [true, false]) {
    group(
      'scope independence (${required ? 'protected' : 'compatibility'})',
      () {
        setUp(() => useMode(required));

        const proxyPath = '/api/v1/account/proxy/support/api/sn';

        test(
          'an extensions:manage token is refused by the account proxy',
          () async {
            final read = await send(
              'GET',
              proxyPath,
              authorization: 'Bearer $managerToken',
            );
            expect(read.status, 403);
            expect(
              read.body,
              '{"error":"Token is not scoped for account:proxy"}',
            );

            final write = await send(
              'POST',
              proxyPath,
              authorization: 'Bearer $managerToken',
              body: <String, dynamic>{},
            );
            expect(write.status, 403);
            expect(
              write.body,
              '{"error":"Token is not scoped for account:proxy:write"}',
            );
            expect(accountUpstream, isEmpty);
          },
        );

        test('account-proxy 401 and 403 bodies are unchanged', () async {
          for (final (authorization, status, body) in [
            (null, 401, '{"error":"Missing or malformed bearer token"}'),
            ('Basic abc', 401, '{"error":"Missing or malformed bearer token"}'),
            ('Bearer $unknownToken', 401, '{"error":"Invalid token"}'),
            ('Bearer $revokedToken', 401, '{"error":"Invalid token"}'),
          ]) {
            final reply = await send(
              'GET',
              proxyPath,
              authorization: authorization,
            );
            expect(reply.status, status, reason: authorization);
            expect(reply.body, body, reason: authorization);
            expect(
              reply.headers.value(HttpHeaders.wwwAuthenticateHeader),
              isNull,
            );
          }
          final readOnlyWrite = await send(
            'POST',
            proxyPath,
            authorization: 'Bearer $accountToken',
            body: <String, dynamic>{},
          );
          expect(readOnlyWrite.status, 403);
          expect(
            readOnlyWrite.body,
            '{"error":"Token is not scoped for account:proxy:write"}',
          );
          expect(accountUpstream, isEmpty);
        });

        test(
          'an account:proxy token still reaches the account proxy',
          () async {
            final reply = await send(
              'GET',
              proxyPath,
              authorization: 'Bearer $accountToken',
            );
            expect(reply.status, 200, reason: '$reply');
            expect(accountUpstream, isNotEmpty);
          },
        );
      },
    );
  }

  group('security setting reads', () {
    test('unrelated traffic never reads the security setting', () async {
      useMode(true);
      securityReads = 0;
      for (final (method, path) in [
        ('GET', '/api/v1/plugins'),
        ('GET', '/api/v1/webui/skins'),
        ('GET', '/api/v1/webui/server/status'),
        ('GET', '/api/v1/plugins/$_echoId/echo'),
        ('GET', '/api/v1/account/proxy/support/api/sn'),
      ]) {
        final reply = await send(
          method,
          path,
          authorization: path.startsWith('/api/v1/account/proxy/')
              ? 'Bearer $accountToken'
              : null,
        );
        expect(
          reply.status,
          isNot(anyOf(401, 403)),
          reason: '$method $path -> $reply',
        );
      }
      expect(securityReads, 0);
    });

    test('an origin refusal short-circuits before the security read', () async {
      useMode(true);
      securityReads = 0;
      final reply = await send(
        'POST',
        '/api/v1/plugins/$_idleId/enable',
        headers: {'origin': _untrustedOrigin},
      );
      expect(reply.status, 403, reason: '$reply');
      expect(securityReads, 0);
      expect(service.isPluginLoaded(_idleId), isFalse);
    });

    test('a management mutation reads the security setting once', () async {
      useMode(true);
      securityReads = 0;
      final reply = await send(
        'POST',
        '/api/v1/plugins/$_idleId/enable',
        authorization: 'Bearer $managerToken',
      );
      expect(reply.status, 200, reason: '$reply');
      expect(securityReads, 1);
      await service.disablePlugin(_idleId);
    });
  });

  group('open routes', () {
    test('read-only routes answer without a bearer', () async {
      for (final path in [
        '/api/v1/plugins',
        '/api/v1/plugins/$_echoId/settings',
        '/api/v1/webui/skins',
        '/api/v1/webui/skins/default',
        '/api/v1/webui/skins/$_otherSkinId',
        '/api/v1/webui/server/status',
      ]) {
        final reply = await send('GET', path);
        expect(reply.status, 200, reason: '$path -> $reply');
      }
    });

    test('plugin-defined endpoints answer without a bearer, including '
        'reserved names on other methods', () async {
      final before = await snapshot();
      for (final (method, endpoint) in [
        ('GET', 'echo'),
        ('POST', 'echo'),
        ('GET', 'enable'),
        ('PUT', 'enable'),
        ('DELETE', 'enable'),
        ('GET', 'source'),
        ('POST', 'source'),
        ('POST', 'approve'),
      ]) {
        final reply = await send(
          method,
          '/api/v1/plugins/$_echoId/$endpoint',
          body: method == 'GET' ? null : <String, dynamic>{},
        );
        expect(reply.status, 200, reason: '$method $endpoint -> $reply');
        expect(reply.json, containsPair('endpoint', endpoint));
        expect(reply.json, containsPair('method', method));
      }

      final idle = await send('GET', '/api/v1/plugins/$_idleId/enable');
      expect(idle.status, 404);
      expect(idle.error, 'plugin with $_idleId not loaded');
      expect(await snapshot(), before);
    });
  });

  for (final required in [true, false]) {
    group('bearer removal before plugin endpoints '
        '(${required ? 'protected' : 'compatibility'})', () {
      setUp(() => useMode(required));

      Future<Map<String, dynamic>> echoedHeaders(String? authorization) async {
        final reply = await send(
          'GET',
          '/api/v1/plugins/$_echoId/echo',
          authorization: authorization,
        );
        expect(reply.status, 200, reason: '$reply');
        return Map<String, dynamic>.from(reply.json['headers'] as Map);
      }

      test('a recognised bearer never reaches plugin code', () async {
        for (final token in [managerToken, accountToken, tokens.skinToken]) {
          final headers = await echoedHeaders('Bearer $token');
          expect(
            headers.keys.map((name) => name.toLowerCase()),
            isNot(contains('authorization')),
          );
          expect(jsonEncode(headers), isNot(contains(token)));
        }
      });

      test('an unknown bearer is passed through unchanged', () async {
        final headers = await echoedHeaders('Bearer $unknownToken');
        expect(headers['authorization'], 'Bearer $unknownToken');
      });
    });
  }

  for (final required in [true, false]) {
    group('browser origins (${required ? 'protected' : 'compatibility'})', () {
      setUp(() => useMode(required));

      String? bearer() => required ? 'Bearer $managerToken' : null;

      List<String> untrustedOrigins() => [
        _untrustedOrigin,
        'http://$_untrustedLanAddress:$_trustedPagePort',
        'http://decaid.local:$_trustedPagePort',
        'http://localhost:3000',
        'http://localhost:8080',
        'https://$_trustedDeviceAddress:$_trustedPagePort',
        'http://localhost',
        'null',
        'http://localhost:$_trustedPagePort, https://evil.example',
      ];

      List<String> trustedOrigins() => [
        'http://localhost:$_trustedPagePort',
        'http://127.0.0.1:$_trustedPagePort',
        'http://[::1]:$_trustedPagePort',
        'http://$_trustedDeviceAddress:$_trustedPagePort',
        'http://$_trustedDeviceAddress:$listenerPort',
        'http://127.0.0.1:$listenerPort',
      ];

      test('an untrusted origin is refused on every management route with no '
          'work, even with a valid bearer', () async {
        final before = await snapshot();
        for (final route in extensionManagementRoutes) {
          for (final origin in untrustedOrigins()) {
            final reply = await send(
              route.method,
              _concretePath(route),
              authorization: bearer(),
              body: _bodyFor(route),
              headers: {'origin': origin},
            );
            expect(reply.status, 403, reason: '$route $origin');
            expect(reply.error, _originRefused, reason: '$route $origin');
            expect(
              reply.headers.value('access-control-allow-origin'),
              isNull,
              reason: '$route $origin',
            );
          }
        }
        expect(await snapshot(), before);
        expect(gitHubRequests, isEmpty);
        expect(storage.calls, isEmpty);
        expect(webUi.calls, isEmpty);
      });

      test('a trusted skin page or same-origin API origin is admitted when '
          'the credential policy allows', () async {
        for (final origin in trustedOrigins()) {
          final reply = await send(
            'POST',
            '/api/v1/plugins/$_idleId/enable',
            authorization: bearer(),
            headers: {'origin': origin},
          );
          expect(reply.status, 200, reason: '$origin: $reply');
          expect(reply.error, isNull, reason: origin);
          expect(
            reply.headers.value('access-control-allow-origin'),
            origin,
            reason: origin,
          );
          expect(service.isPluginLoaded(_idleId), isTrue, reason: origin);
          await service.disablePlugin(_idleId);
        }
      });

      test('a trusted origin does not replace the credential policy', () async {
        final reply = await send(
          'POST',
          '/api/v1/plugins/$_idleId/enable',
          headers: {'origin': 'http://localhost:$_trustedPagePort'},
        );
        expect(reply.status, required ? 401 : 200, reason: '$reply');
        expect(service.isPluginLoaded(_idleId), required ? isFalse : isTrue);
        await service.disablePlugin(_idleId);
      });

      test('the trusted page origin follows the live skin port, restart and '
          'stop', () async {
        final live = 'http://localhost:$_trustedPagePort';
        final next = 'http://localhost:$_nextPagePort';

        Future<int> attempt(String origin) async => (await send(
          'POST',
          '/api/v1/plugins/$_idleId/enable',
          authorization: bearer(),
          headers: {'origin': origin},
        )).status;

        expect(await attempt(live), 200);
        await service.disablePlugin(_idleId);

        browserPagePorts = {_nextPagePort};
        expect(await attempt(live), 403);
        expect(await attempt(next), 200);
        await service.disablePlugin(_idleId);

        browserPagePorts = const {};
        expect(await attempt(next), 403);
        expect(service.isPluginLoaded(_idleId), isFalse);

        browserPagePorts = {_nextPagePort};
        expect(
          await attempt('http://$_trustedDeviceAddress:$_nextPagePort'),
          200,
        );
        await service.disablePlugin(_idleId);

        browserDeviceAddresses = {'192.168.12.65'};
        expect(
          await attempt('http://$_trustedDeviceAddress:$_nextPagePort'),
          403,
        );
        expect(await attempt('http://192.168.12.65:$_nextPagePort'), 200);
        await service.disablePlugin(_idleId);
      });

      test('a loopback origin needs a socket peer that belongs to this '
          'device', () async {
        final lanServer = await bind(InternetAddress.anyIPv4);
        addTearDown(() => lanServer.close(force: true));
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLoopback: false,
        );
        final addresses = [
          for (final interface in interfaces)
            for (final address in interface.addresses) address,
        ].where((address) => !address.isLoopback).toList();
        if (addresses.isEmpty) {
          markTestSkipped(
            'No non-loopback IPv4 address; the LAN peer case was not '
            'exercised',
          );
          return;
        }
        final peer = addresses.first;
        const origin = 'http://localhost:$_trustedPagePort';

        connections.clear();
        final before = await snapshot();
        browserDeviceAddresses = {_untrustedLanAddress};
        final remote = await send(
          'POST',
          '/api/v1/plugins/$_idleId/enable',
          authorization: bearer(),
          headers: const {'origin': origin},
          to: lanServer,
          host: peer.address,
        );
        expect(remote.status, 403, reason: '${peer.address}: $remote');
        expect(remote.error, _originRefused);
        expect(remote.headers.value('access-control-allow-origin'), isNull);
        expect(connections.last.remote, peer.address);
        expect(InternetAddress(connections.last.remote).isLoopback, isFalse);
        expect(await snapshot(), before);
        expect(service.isPluginLoaded(_idleId), isFalse);

        browserDeviceAddresses = {peer.address};
        final sameDevice = await send(
          'POST',
          '/api/v1/plugins/$_idleId/enable',
          authorization: bearer(),
          headers: const {'origin': origin},
          to: lanServer,
          host: peer.address,
        );
        expect(
          sameDevice.status,
          200,
          reason: 'a self peer keeps the local page origin: $sameDevice',
        );
        expect(service.isPluginLoaded(_idleId), isTrue);
        await service.disablePlugin(_idleId);

        browserDeviceAddresses = {_trustedDeviceAddress};
        final numeric = await send(
          'POST',
          '/api/v1/plugins/$_idleId/enable',
          authorization: bearer(),
          headers: {
            'origin': 'http://$_trustedDeviceAddress:$_trustedPagePort',
          },
          to: lanServer,
          host: peer.address,
        );
        expect(
          numeric.status,
          200,
          reason:
              'a remote LAN browser keeps a numeric device origin: '
              '$numeric',
        );
        expect(service.isPluginLoaded(_idleId), isTrue);
        await service.disablePlugin(_idleId);
      });

      test('host, referer and forwarding headers do not make an origin '
          'trusted', () async {
        final before = await snapshot();
        final forged = {
          'origin': _untrustedOrigin,
          'referer': 'http://localhost:$_trustedPagePort/settings',
          'x-forwarded-host': 'localhost:$_trustedPagePort',
          'x-forwarded-for': '127.0.0.1',
          'x-real-ip': '127.0.0.1',
          'forwarded': 'for=127.0.0.1;host=localhost;proto=http',
        };
        final reply = await send(
          'POST',
          '/api/v1/plugins/$_idleId/enable',
          authorization: bearer(),
          headers: forged,
        );
        expect(reply.status, 403, reason: '$reply');
        expect(reply.error, _originRefused);

        final raw = await rawSocketRequest(
          InternetAddress.loopbackIPv4,
          server.port,
          'POST',
          '/api/v1/plugins/$_idleId/enable',
          authorization: bearer(),
          hostHeader: 'localhost:$_trustedPagePort',
          headers: const {'Origin': _untrustedOrigin},
        );
        expect(raw.status, 403, reason: raw.body);
        expect(raw.body, contains(_originRefused));
        expect(await snapshot(), before);
        expect(service.isPluginLoaded(_idleId), isFalse);

        final originless = await rawSocketRequest(
          InternetAddress.loopbackIPv4,
          server.port,
          'POST',
          '/api/v1/plugins/$_idleId/enable',
          authorization: bearer(),
          hostHeader: 'localhost:$_trustedPagePort',
          headers: const {
            'X-Forwarded-For': '127.0.0.1',
            'X-Real-IP': '127.0.0.1',
          },
        );
        expect(originless.status, 200, reason: originless.body);
        expect(service.isPluginLoaded(_idleId), isTrue);
        await service.disablePlugin(_idleId);
      });

      test('an untrusted preflight for a management mutation gets no '
          'affirmative CORS or preflight headers', () async {
        final before = await snapshot();
        for (final route in extensionManagementRoutes) {
          for (final origin in untrustedOrigins()) {
            final reply = await send(
              'OPTIONS',
              _concretePath(route),
              headers: {
                'origin': origin,
                'access-control-request-method': route.method,
                'access-control-request-headers': 'authorization, content-type',
              },
            );
            expect(reply.status, 403, reason: '$route $origin');
            expect(reply.error, _originRefused, reason: '$route $origin');
            for (final name in [
              'access-control-allow-origin',
              'access-control-allow-credentials',
              'access-control-allow-methods',
              'access-control-allow-headers',
              'access-control-expose-headers',
            ]) {
              expect(
                reply.headers.value(name),
                isNull,
                reason: '$route $origin $name',
              );
            }
          }
        }
        expect(await snapshot(), before);
      });

      test('an untrusted preflight for a body-sensitive operation gets no '
          'affirmative CORS or preflight headers', () async {
        final before = await snapshot();
        for (final path in [
          '/api/v1/settings',
          '/api/v1/data/import',
          '/api/v1/data/sync',
        ]) {
          for (final origin in untrustedOrigins()) {
            final reply = await send(
              'OPTIONS',
              path,
              headers: {
                'origin': origin,
                'access-control-request-method': 'POST',
                'access-control-request-headers': 'authorization, content-type',
              },
            );
            expect(reply.status, 403, reason: '$path $origin');
            expect(reply.error, _originRefused, reason: '$path $origin');
            for (final name in [
              'access-control-allow-origin',
              'access-control-allow-credentials',
              'access-control-allow-methods',
              'access-control-allow-headers',
              'access-control-expose-headers',
              'access-control-max-age',
            ]) {
              expect(
                reply.headers.value(name),
                isNull,
                reason: '$path $origin $name',
              );
            }
          }
        }
        expect(await snapshot(), before);
      });

      test('an untrusted preflight for a read-only method on a shared '
          'management path keeps the general CORS contract', () async {
        final before = await snapshot();
        for (final path in [
          '/api/v1/plugins',
          '/api/v1/plugins/$_echoId/settings',
          '/api/v1/webui/skins',
          '/api/v1/webui/skins/default',
          '/api/v1/webui/skins/$_defaultSkinId',
          '/api/v1/settings',
        ]) {
          for (final origin in [
            _untrustedOrigin,
            'null',
            'http://unknown.example:9999',
          ]) {
            final reply = await send(
              'OPTIONS',
              path,
              headers: {
                'origin': origin,
                'access-control-request-method': 'GET',
              },
            );
            expect(reply.status, 200, reason: '$path $origin');
            expect(reply.body, isEmpty, reason: '$path $origin');
            expect(
              reply.headers.value('access-control-allow-origin'),
              origin,
              reason: '$path $origin',
            );
            expect(
              reply.headers.value('access-control-allow-methods'),
              isNotNull,
              reason: '$path $origin',
            );
            expect(
              reply.headers.value('access-control-max-age'),
              isNotNull,
              reason: '$path $origin',
            );
          }
        }
        expect(await snapshot(), before);
      });

      test('an untrusted preflight for a mutation on a shared path is still '
          'refused', () async {
        final before = await snapshot();
        for (final (method, path) in [
          ('POST', '/api/v1/plugins/$_echoId/settings'),
          ('PUT', '/api/v1/webui/skins/default'),
          ('DELETE', '/api/v1/webui/skins/$_defaultSkinId'),
          ('DELETE', '/api/v1/plugins/$_idleId'),
          ('POST', '/api/v1/settings'),
        ]) {
          for (final origin in [...untrustedOrigins(), 'null']) {
            final reply = await send(
              'OPTIONS',
              path,
              headers: {
                'origin': origin,
                'access-control-request-method': method,
              },
            );
            expect(reply.status, 403, reason: '$method $path $origin');
            expect(reply.error, _originRefused, reason: '$method $path');
            for (final name in [
              'access-control-allow-origin',
              'access-control-allow-credentials',
              'access-control-allow-methods',
              'access-control-allow-headers',
              'access-control-expose-headers',
              'access-control-max-age',
            ]) {
              expect(
                reply.headers.value(name),
                isNull,
                reason: '$method $path $origin $name',
              );
            }
          }
        }
        expect(await snapshot(), before);
      });

      test('an untrusted preflight for a plugin-defined route keeps the '
          'general CORS contract', () async {
        for (final (method, path) in [
          ('POST', '/api/v1/plugins/$_echoId/echo'),
          ('GET', '/api/v1/plugins/$_echoId/status'),
        ]) {
          final reply = await send(
            'OPTIONS',
            path,
            headers: {
              'origin': _untrustedOrigin,
              'access-control-request-method': method,
            },
          );
          expect(reply.status, 200, reason: '$method $path');
          expect(
            reply.headers.value('access-control-allow-origin'),
            _untrustedOrigin,
            reason: '$method $path',
          );
        }
      });

      test('an untrusted preflight without a usable requested method stays '
          'refused on management paths', () async {
        final before = await snapshot();
        for (final value in const <String?>[null, '', 'GET, POST', 'P@ST']) {
          for (final path in [
            '/api/v1/plugins/$_echoId/settings',
            '/api/v1/webui/skins/default',
            '/api/v1/settings',
          ]) {
            final reply = await send(
              'OPTIONS',
              path,
              headers: {
                'origin': _untrustedOrigin,
                'access-control-request-method': ?value,
              },
            );
            expect(reply.status, 403, reason: '$value $path');
            expect(reply.error, _originRefused, reason: '$value $path');
            expect(
              reply.headers.value('access-control-allow-origin'),
              isNull,
              reason: '$value $path',
            );
          }
        }
        expect(await snapshot(), before);
      });

      test('a trusted preflight for a body-sensitive operation keeps its '
          'pre-existing CORS headers', () async {
        for (final path in [
          '/api/v1/settings',
          '/api/v1/data/import',
          '/api/v1/data/sync',
        ]) {
          final reply = await send(
            'OPTIONS',
            path,
            headers: {
              'origin': 'http://localhost:$_trustedPagePort',
              'access-control-request-method': 'POST',
            },
          );
          expect(reply.status, 200, reason: path);
          expect(
            reply.headers.value('access-control-allow-origin'),
            'http://localhost:$_trustedPagePort',
            reason: path,
          );
        }
      });

      test('an untrusted origin keeps read-only, plugin-defined and '
          'unrelated routes unchanged', () async {
        for (final (method, path) in [
          ('GET', '/api/v1/plugins'),
          ('GET', '/api/v1/plugins/$_echoId/echo'),
          ('GET', '/api/v1/webui/server/status'),
          ('POST', '/api/v1/plugins/$_echoId/echo'),
        ]) {
          final reply = await send(
            method,
            path,
            headers: {'origin': _untrustedOrigin},
          );
          expect(
            reply.status,
            isNot(anyOf(401, 403)),
            reason: '$method $path -> $reply',
          );
        }
      });
    });
  }

  group('CORS and preflight', () {
    test('a preflight on every protected path answers without auth and '
        'without reaching a handler', () async {
      final before = await snapshot();
      for (final route in extensionManagementRoutes) {
        final reply = await send(
          'OPTIONS',
          _concretePath(route),
          headers: {
            'origin': _origin,
            'access-control-request-method': route.method,
            'access-control-request-headers': 'authorization, content-type',
          },
        );
        expect(reply.status, 200, reason: '$route');
        expect(reply.body, isEmpty, reason: '$route');
        expect(reply.headers.value('access-control-allow-origin'), _origin);
        expect(
          reply.headers.value('access-control-allow-headers'),
          contains('Authorization'),
        );
      }
      expect(await snapshot(), before);
    });

    test('a refusal sent with an Origin still carries CORS headers', () async {
      final missing = await send(
        'POST',
        '/api/v1/plugins/$_idleId/enable',
        headers: {'origin': _origin},
      );
      expect(missing.status, 401);
      expect(missing.headers.value('access-control-allow-origin'), _origin);

      final unscoped = await send(
        'POST',
        '/api/v1/plugins/$_idleId/enable',
        authorization: 'Bearer $accountToken',
        headers: {'origin': _origin},
      );
      expect(unscoped.status, 403);
      expect(unscoped.headers.value('access-control-allow-origin'), _origin);
      expect(service.isPluginLoaded(_idleId), isFalse);
    });

    test(
      'OPTIONS without an Origin on protected paths changes nothing',
      () async {
        final before = await snapshot();
        for (final route in extensionManagementRoutes) {
          final reply = await send('OPTIONS', _concretePath(route));
          expect(reply.status, isNot(anyOf(401, 403)), reason: '$route');
        }
        expect(await snapshot(), before);
      },
    );
  });

  test(
    'reused listener delegates to isolated per-test handler state',
    () async {
      expect(server.port, listenerPort);
      expect(tempDir.path, isNot(fixtureDir.path));

      final firstToken = managerToken;
      final firstEnabled = await send(
        'POST',
        '/api/v1/plugins/$_idleId/enable',
        authorization: 'Bearer $firstToken',
      );
      expect(firstEnabled.status, 200, reason: '$firstEnabled');
      expect(service.isPluginLoaded(_idleId), isTrue);

      final firstSettings = await send(
        'POST',
        '/api/v1/plugins/$_idleId/settings',
        authorization: 'Bearer $firstToken',
        body: {'Label': 'previous-test'},
      );
      expect(firstSettings.status, 200, reason: '$firstSettings');
      expect(
        await service.pluginSettings(_idleId),
        containsPair('Label', 'previous-test'),
      );
      expect(firstToken, isNotEmpty);

      await disposeTestContext();
      await initializeTestContext();

      expect(server.port, listenerPort);
      expect(tempDir.path, isNot(fixtureDir.path));
      expect(service.isPluginLoaded(_idleId), isFalse);
      expect(await service.pluginSettings(_idleId), isEmpty);
      expect(managerToken, isNot(equals(firstToken)));

      final staleToken = await send(
        'POST',
        '/api/v1/plugins/$_idleId/enable',
        authorization: 'Bearer $firstToken',
      );
      expect(staleToken.status, 401, reason: '$staleToken');
      expect(staleToken.error, _invalidToken);

      final secondEnabled = await send(
        'POST',
        '/api/v1/plugins/$_idleId/enable',
        authorization: 'Bearer $managerToken',
      );
      expect(secondEnabled.status, 200, reason: '$secondEnabled');
      expect(service.isPluginLoaded(_idleId), isTrue);
    },
  );

  test('refused requests do not consume admission capacity', () async {
    final gate = AdmissionGate(
      globalConcurrent: 8,
      perClientConcurrent: 8,
      globalRate: 3,
      perClientRate: 3,
      maxTrackedClients: 4,
      nowMs: () => 0,
    );
    final gated = await serve(pipeline(gate: gate));

    final refused = await Future.wait([
      for (var i = 0; i < 24; i++)
        send(
          'POST',
          '/api/v1/plugins/$_idleId/enable',
          authorization: i.isEven ? null : 'Bearer $accountToken',
          to: gated,
        ),
    ]);
    expect(refused.map((reply) => reply.status).toSet(), {401, 403});

    final authorized = await send(
      'POST',
      '/api/v1/plugins/$_idleId/enable',
      authorization: 'Bearer $managerToken',
      to: gated,
    );
    expect(authorized.status, 200, reason: '$authorized');
    expect(service.isPluginLoaded(_idleId), isTrue);

    for (var i = 0; i < 2; i++) {
      expect((await send('GET', '/api/v1/plugins', to: gated)).status, 200);
    }
    final overLimit = await send('GET', '/api/v1/plugins', to: gated);
    expect(overLimit.status, 429);
    expect(gate.activeCount, 0);
  });

  test('concurrent authorized and refused operations on one plugin', () async {
    final operations = <Future<(bool, String, _Reply)>>[];
    for (var i = 0; i < 30; i++) {
      final authorized = i % 3 != 0;
      final (method, path, body) = switch (i % 4) {
        0 => ('POST', '/api/v1/plugins/$_echoId/disable', null),
        1 => ('POST', '/api/v1/plugins/$_echoId/enable', null),
        _ => (
          'POST',
          '/api/v1/plugins/$_echoId/settings',
          {'Label': authorized ? 'authorized-$i' : 'refused-$i'},
        ),
      };
      operations.add(
        send(
          method,
          path,
          authorization: authorized
              ? 'Bearer $managerToken'
              : i.isEven
              ? null
              : 'Bearer $accountToken',
          body: body,
        ).then((reply) => (authorized, '$method $path', reply)),
      );
    }

    for (final (authorized, operation, reply) in await Future.wait(
      operations,
    )) {
      if (authorized) {
        expect(reply.status, 200, reason: '$operation -> $reply');
      } else {
        expect(reply.status, anyOf(401, 403), reason: operation);
        expect(reply.error, anyOf(_missingBearer, _unscoped));
      }
    }

    final settings = await service.pluginSettings(_echoId);
    expect(settings['Label'], startsWith('authorized-'));
    expect(
      service.isPluginLoaded(_echoId),
      await service.shouldAutoLoad(_echoId),
    );
    expect(
      service.pluginManager.loadedPlugins.any(
        (plugin) => plugin.pluginId == _echoId,
      ),
      service.isPluginLoaded(_echoId),
    );
  });

  group('#1187 visualizer settings save', () {
    const id = 'visualizer.reaplugin';
    const secureKey = 'plugin.settings.secure.$id';
    const secret = 'sk-dye2-visualizer-0123456789abcdef';
    const newerSecret = 'sk-dye2-visualizer-fedcba9876543210';

    Map<String, dynamic> visualizerManifest() => {
      ..._manifestJson(id),
      'settings': {
        'Label': {'type': 'string'},
        'apiKey': {'type': 'string', 'secure': true},
      },
    };

    setUp(() async {
      await service.updatePluginSource(
        id,
        manifestJson: visualizerManifest(),
        pluginJs: _echoPluginJs(id),
      );
    });

    test('a tokenless save is legacy in compatibility mode and 401 in '
        'protected mode, and the stored secret never leaks', () async {
      useMode(false);
      final saved = await send(
        'POST',
        '/api/v1/plugins/$id/settings',
        body: {'Label': 'dye2', 'apiKey': secret},
      );
      expect(saved.status, 200, reason: '$saved');
      expect(saved.body, isNot(contains(secret)));
      expect((saved.json as Map)['apiKey'], {'isSet': true});
      expect(await pluginCredentials.read(key: secureKey), contains(secret));

      final fetched = await send('GET', '/api/v1/plugins/$id/settings');
      expect(fetched.status, 200, reason: '$fetched');
      expect(fetched.body, isNot(contains(secret)));
      expect((fetched.json as Map)['apiKey'], {'isSet': true});
      expect((fetched.json as Map)['Label'], 'dye2');

      final invalid = await send(
        'POST',
        '/api/v1/plugins/$id/settings',
        body: {'apiKey': newerSecret, 'notInTheManifest': 1},
      );
      expect(invalid.status, 400, reason: '$invalid');
      expect(invalid.error, contains('notInTheManifest'));
      expect(invalid.body, isNot(contains(newerSecret)));
      expect(await pluginCredentials.read(key: secureKey), contains(secret));

      useMode(true);
      final refused = await send(
        'POST',
        '/api/v1/plugins/$id/settings',
        body: {'apiKey': newerSecret},
      );
      expect(refused.status, 401, reason: '$refused');
      expect(refused.error, _missingBearer);
      expect(refused.body, isNot(contains(newerSecret)));
      expect(await pluginCredentials.read(key: secureKey), contains(secret));

      final managed = await send(
        'POST',
        '/api/v1/plugins/$id/settings',
        authorization: 'Bearer $managerToken',
        body: {'apiKey': newerSecret},
      );
      expect(managed.status, 200, reason: '$managed');
      expect(managed.body, isNot(contains(newerSecret)));
      expect(
        await pluginCredentials.read(key: secureKey),
        contains(newerSecret),
      );

      final protectedFetch = await send('GET', '/api/v1/plugins/$id/settings');
      expect(protectedFetch.status, 200, reason: '$protectedFetch');
      expect(protectedFetch.body, isNot(contains(newerSecret)));
    });
  });

  group('real socket topologies', () {
    HttpServer? ipv6Server;
    late HttpServer lanServer;
    late InternetAddress lanAddress;

    bool hasLan() => lanAddress.address != '0.0.0.0';

    setUp(() async {
      ipv6Server = null;
      try {
        ipv6Server = await bind(InternetAddress.loopbackIPv6);
      } catch (_) {
        ipv6Server = null;
      }
      lanServer = await bind(InternetAddress.anyIPv4);
      addTearDown(() async {
        await ipv6Server?.close(force: true);
        await lanServer.close(force: true);
      });
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final addresses = [
        for (final interface in interfaces)
          for (final address in interface.addresses) address,
      ].where((address) => !address.isLoopback).toList();
      lanAddress = addresses.isEmpty
          ? InternetAddress('0.0.0.0')
          : InternetAddress(addresses.first.address);
    });

    List<({String name, String host, HttpServer? to, bool bound})> targets() =>
        [
          (name: 'IPv4 127.0.0.1', host: '127.0.0.1', to: null, bound: false),
          (
            name: 'the localhost hostname',
            host: 'localhost',
            to: null,
            bound: false,
          ),
          if (ipv6Server != null)
            (name: 'IPv6 ::1', host: '::1', to: ipv6Server, bound: false),
          if (hasLan())
            (
              name: 'a LAN-bound socket',
              host: lanAddress.address,
              to: lanServer,
              bound: true,
            ),
        ];

    Future<({int status, String body})> requestOver(
      ({String name, String host, HttpServer? to, bool bound}) target,
      String method,
      String path, {
      String? authorization,
      Map<String, String> headers = const {},
    }) async {
      if (target.bound) {
        return rawSocketRequest(
          lanAddress,
          target.to!.port,
          method,
          path,
          sourceAddress: lanAddress,
          authorization: authorization,
          headers: headers,
          hostHeader: target.host,
        );
      }
      final reply = await send(
        method,
        path,
        host: target.host,
        to: target.to,
        authorization: authorization,
        headers: headers,
      );
      return (status: reply.status, body: reply.body);
    }

    test('compatibility mode applies a tokenless management call over every '
        'socket topology', () async {
      printOnFailure('topologies: ${[for (final t in targets()) t.name]}');
      useMode(false);
      for (final target in targets()) {
        final reply = await requestOver(
          target,
          'POST',
          '/api/v1/plugins/$_idleId/enable',
        );
        expect(reply.status, 200, reason: '${target.name}: ${reply.body}');
        expect(service.isPluginLoaded(_idleId), isTrue, reason: target.name);
        await service.disablePlugin(_idleId);
      }
    });

    test('the IPv6 ::1 loopback reaches the management handler in '
        'compatibility mode and is gated in protected mode', () async {
      if (ipv6Server == null) {
        markTestSkipped(
          'No IPv6 loopback listener; the ::1 case was not exercised',
        );
        return;
      }
      useMode(false);
      final legacy = await send(
        'POST',
        '/api/v1/plugins/$_idleId/enable',
        host: '::1',
        to: ipv6Server,
      );
      expect(legacy.status, 200, reason: '$legacy');
      expect(service.isPluginLoaded(_idleId), isTrue);
      await service.disablePlugin(_idleId);

      useMode(true);
      final refused = await send(
        'POST',
        '/api/v1/plugins/$_idleId/enable',
        host: '::1',
        to: ipv6Server,
      );
      expect(refused.status, 401, reason: '$refused');
      expect(refused.error, _missingBearer);
      expect(service.isPluginLoaded(_idleId), isFalse);
      expect(connections.last.remote, '::1');
    });

    test('protected mode refuses every credential over every socket topology '
        'and accepts a manager token', () async {
      for (final target in targets()) {
        for (final credential in refusedCredentials()) {
          final reply = await requestOver(
            target,
            'POST',
            '/api/v1/plugins/$_idleId/enable',
            authorization: credential.authorization,
          );
          expect(
            reply.status,
            credential.status,
            reason: '${target.name} with ${credential.name}: ${reply.body}',
          );
          expect(
            reply.body,
            contains(credential.error),
            reason: '${target.name} with ${credential.name}',
          );
        }
        expect(
          service.isPluginLoaded(_idleId),
          isFalse,
          reason: '${target.name} refused every credential without work',
        );

        final managed = await requestOver(
          target,
          'POST',
          '/api/v1/plugins/$_idleId/enable',
          authorization: 'Bearer $managerToken',
        );
        expect(
          managed.status,
          200,
          reason: '${target.name} with a manager token: ${managed.body}',
        );
        expect(service.isPluginLoaded(_idleId), isTrue, reason: target.name);
        await service.disablePlugin(_idleId);
      }
    });

    test('forged forwarding and Host headers do not authorize over any '
        'socket', () async {
      if (hasLan()) {
        browserDeviceAddresses = {
          ...browserDeviceAddresses,
          lanAddress.address,
        };
      }
      final endpoints = [
        (
          name: 'IPv4',
          address: InternetAddress.loopbackIPv4,
          port: server.port,
          source: null as InternetAddress?,
        ),
        if (ipv6Server != null)
          (
            name: 'IPv6 ::1',
            address: InternetAddress.loopbackIPv6,
            port: ipv6Server!.port,
            source: null as InternetAddress?,
          ),
        if (hasLan())
          (
            name: 'LAN-bound',
            address: lanAddress,
            port: lanServer.port,
            source: lanAddress as InternetAddress?,
          ),
      ];
      for (final endpoint in endpoints) {
        final reply = await rawSocketRequest(
          endpoint.address,
          endpoint.port,
          'POST',
          '/api/v1/plugins/$_idleId/enable',
          sourceAddress: endpoint.source,
          hostHeader: 'localhost',
          headers: const {
            'Origin': 'http://localhost:$_trustedPagePort',
            'X-Forwarded-For': '127.0.0.1',
            'X-Real-IP': '127.0.0.1',
            'Forwarded': 'for=127.0.0.1;host=localhost',
            'X-Forwarded-Host': 'localhost',
          },
        );
        expect(reply.status, 401, reason: '${endpoint.name}: ${reply.body}');
        expect(reply.body, contains(_missingBearer), reason: endpoint.name);
        expect(service.isPluginLoaded(_idleId), isFalse, reason: endpoint.name);
      }
    });

    test('a LAN-bound client is observed as a non-loopback remote address '
        'and is still gated in protected mode', () async {
      if (!hasLan()) {
        markTestSkipped(
          'No non-loopback IPv4 address; the LAN-bound peer case was not '
          'exercised',
        );
        return;
      }
      useMode(false);
      connections.clear();
      final reply = await rawSocketRequest(
        lanAddress,
        lanServer.port,
        'POST',
        '/api/v1/plugins/$_idleId/enable',
        sourceAddress: lanAddress,
        hostHeader: lanAddress.address,
      );
      expect(reply.status, 200, reason: reply.body);
      expect(service.isPluginLoaded(_idleId), isTrue);
      final lan = connections.last;
      expect(lan.remote, lanAddress.address);
      expect(InternetAddress(lan.remote).isLoopback, isFalse);

      useMode(true);
      final refused = await rawSocketRequest(
        lanAddress,
        lanServer.port,
        'POST',
        '/api/v1/plugins/$_idleId/disable',
        sourceAddress: lanAddress,
        hostHeader: lanAddress.address,
      );
      expect(refused.status, 401, reason: refused.body);
      expect(refused.body, contains(_missingBearer));
      expect(connections.last.remote, lanAddress.address);
      expect(service.isPluginLoaded(_idleId), isTrue);
      await service.disablePlugin(_idleId);

      final loopback = await send('POST', '/api/v1/plugins/$_idleId/enable');
      expect(loopback.status, 401, reason: '$loopback');
      expect(connections.last.remote, '127.0.0.1');
      expect(InternetAddress(connections.last.remote).isLoopback, isTrue);
    });
  });

  group('alternate listeners', () {
    test('a second listener for the same handler enforces the gate', () async {
      final second = await serve(pipeline());
      expect(second.port, isNot(server.port));
      final before = await snapshot();

      for (final credential in refusedCredentials()) {
        final reply = await send(
          'POST',
          '/api/v1/plugins/$_idleId/enable',
          authorization: credential.authorization,
          to: second,
        );
        expect(reply.status, credential.status, reason: credential.name);
      }
      expect(await snapshot(), before);

      final authorized = await send(
        'POST',
        '/api/v1/plugins/$_idleId/enable',
        authorization: 'Bearer $managerToken',
        to: second,
      );
      expect(authorized.status, 200);
      expect(service.isPluginLoaded(_idleId), isTrue);
    });

    test('the API docs listener exposes no management route', () async {
      final docsDir = Directory('${tempDir.path}/api')..createSync();
      File('${docsDir.path}/index.html').writeAsStringSync('<html></html>');
      File('${docsDir.path}/rest_v1.yml').writeAsStringSync('openapi: 3.0.0');
      final docs = await serve(createApiDocsHandler(docsDir.path));
      final before = await snapshot();

      expect((await send('GET', '/rest_v1.yml', to: docs)).status, 200);
      for (final route in extensionManagementRoutes) {
        final reply = await send(
          route.method,
          _concretePath(route),
          authorization: 'Bearer $managerToken',
          body: _bodyFor(route),
          to: docs,
        );
        expect(reply.status, 404, reason: '$route');
      }
      expect((await send('GET', '/api/v1/plugins', to: docs)).status, 404);
      expect(await snapshot(), before);
    });
  });
}

class _NoHeaders extends Fake implements HttpHeaders {
  @override
  String? value(String name) => null;
}
