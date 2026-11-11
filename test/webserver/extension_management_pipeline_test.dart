import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/plugins/plugin_loader_service.dart';
import 'package:reaprime/src/plugins/plugin_source_service.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/account/decent_proxy_service.dart';
import 'package:reaprime/src/services/account/proxy_token_service.dart';
import 'package:reaprime/src/services/webserver/extension_management_auth.dart';
import 'package:reaprime/src/services/webserver_service.dart';
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
const _origin = 'http://skin.example';

const _missingBearer = 'Missing or malformed bearer token';
const _invalidToken = 'Invalid token';
const _unscoped = 'Token is not scoped for extensions:manage';

class _RecordingWebUIStorage extends Fake implements WebUIStorage {
  _RecordingWebUIStorage(String root)
    : _skins = {
        for (final id in [_defaultSkinId, _otherSkinId])
          id: WebUISkin(id: id, name: id, path: '$root/skins/$id'),
      };

  final Map<String, WebUISkin> _skins;
  final List<String> calls = [];
  String defaultSkinId = _defaultSkinId;

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
  late HttpServer server;
  late HttpClient client;
  late List<HttpServer> extraServers;

  late String managerToken;
  late String accountToken;
  late String accountWriteToken;
  late String revokedToken;
  late String unknownToken;

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

  Handler pipeline({AdmissionGate? gate}) => buildWebServerHandler(
    routes,
    proxyTokenService: tokens,
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

  Future<_Reply> send(
    String method,
    String path, {
    String? authorization,
    Object? body,
    Map<String, String> headers = const {},
    HttpServer? to,
  }) async {
    final port = (to ?? server).port;
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$path'),
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

  Future<void> installLocalPlugin(String id, {required bool load}) async {
    final dir = Directory('${tempDir.path}/source_$id')
      ..createSync(recursive: true);
    File('${dir.path}/manifest.json')
        .writeAsStringSync(jsonEncode(_manifestJson(id)));
    File('${dir.path}/plugin.js').writeAsStringSync(_echoPluginJs(id));
    await service.addPlugin(dir.path);
    if (load) await service.enablePlugin(id);
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

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    tempDir = Directory.systemTemp.createTempSync('extension_mgmt_pipeline');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => tempDir.path,
        );
    gitHubRequests = [];
    accountUpstream = [];
    extraServers = [];
    releaseTag = 'v1.0.0';
    releaseArchive = _releaseArchive();

    kvStore = FakeKeyValueStoreService();
    service = PluginLoaderService(kvStore: kvStore);
    await service.initialize();
    for (final plugin in service.availablePlugins) {
      await service.removePlugin(plugin.id);
    }
    sources = PluginSourceService(service);
    await installLocalPlugin(_echoId, load: true);
    await installLocalPlugin(_idleId, load: false);

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

    server = await serve(pipeline());
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    for (final listener in extraServers) {
      await listener.close(force: true);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await service.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
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

  group('authorized management requests keep their handler semantics', () {
    String bearer() => 'Bearer $managerToken';

    test(
      'every table route reaches its real handler with extensions:manage',
      () async {
        for (final route in extensionManagementRoutes) {
          final reply = await send(
            route.method,
            _concretePath(route),
            authorization: bearer(),
            body: _bodyFor(route),
          );
          expect(reply.status, isNot(anyOf(401, 403)), reason: '$route');
          expect(reply.body, isNot(contains('Route not found')));
        }
      },
    );

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

    test('skin default, install, removal and the skin server apply', () async {
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
    });
  });

  group('scope independence', () {
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
        expect(read.body, '{"error":"Token is not scoped for account:proxy"}');

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
        expect(reply.headers.value(HttpHeaders.wwwAuthenticateHeader), isNull);
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

    test('an account:proxy token still reaches the account proxy', () async {
      final reply = await send(
        'GET',
        proxyPath,
        authorization: 'Bearer $accountToken',
      );
      expect(reply.status, 200, reason: '$reply');
      expect(accountUpstream, isNotEmpty);
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

  group('bearer removal before plugin endpoints', () {
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
