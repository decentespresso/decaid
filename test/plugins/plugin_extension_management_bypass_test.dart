import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/services/webserver/extension_management_auth.dart';

import 'extension_management_harness.dart';

class FakeGitHub {
  final Map<String, Map<String, List<String>>> _releases = {};
  final Map<String, String> _latest = {};
  final List<String> requests = [];

  void publish(
    String repo,
    String pluginId,
    String version, {
    required List<String> permissions,
  }) {
    _releases.putIfAbsent(repo, () => {})['v$version'] = [
      pluginId,
      ...permissions,
    ];
    _latest[repo] = 'v$version';
  }

  http.Client get client => MockClient((request) async {
    final url = request.url.toString();
    requests.add(url);
    final release = RegExp(
      r'^https://api\.github\.com/repos/([^/]+/[^/]+)/releases/(?:latest|tags/(.+))$',
    ).firstMatch(url);
    if (release != null) {
      final repo = release.group(1)!;
      final tag = release.group(2) ?? _latest[repo];
      if (tag == null || _releases[repo]?[tag] == null) {
        return http.Response('not found', 404);
      }
      return http.Response(
        jsonEncode({
          'tag_name': tag,
          'assets': [
            {
              'name': 'plugin.zip',
              'browser_download_url': 'https://example.test/$repo/$tag.zip',
            },
          ],
        }),
        200,
      );
    }
    final download = RegExp(
      r'^https://example\.test/([^/]+/[^/]+)/(v[^/]+)\.zip$',
    ).firstMatch(url);
    final entry = download == null
        ? null
        : _releases[download.group(1)!]?[download.group(2)!];
    if (entry == null) return http.Response('not found', 404);
    final [pluginId, ...permissions] = entry;
    final version = download!.group(2)!.substring(1);
    final archive = Archive()
      ..addFile(
        ArchiveFile.string(
          'repo-main/manifest.json',
          jsonEncode(
            pluginManifestJson(
              pluginId,
              permissions: permissions,
              version: version,
            ),
          ),
        ),
      )
      ..addFile(
        ArchiveFile.string('repo-main/plugin.js', probePluginJs(pluginId)),
      );
    return http.Response.bytes(ZipEncoder().encode(archive), 200);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  var seq = 0;
  String uniqueId(String name) => '$name${++seq}.reaplugin';

  group('a plugin with api and network permissions but no manage.extensions', () {
    late ExtensionManagementHarness harness;
    late String attacker;
    late String steward;
    late String target;
    late String dormant;
    late Map<String, Object?> before;

    setUp(() async {
      harness = await ExtensionManagementHarness.start();
      attacker = uniqueId('attacker');
      steward = uniqueId('steward');
      target = uniqueId('target');
      dormant = uniqueId('dormant');
      await harness.install(attacker);
      await harness.install(steward, permissions: privilegedPermissions);
      await harness.install(target);
      await harness.install(dormant, load: false);
      before = await harness.extensionState();
    });

    tearDown(() async {
      await harness.dispose();
    });

    Future<void> expectNoSideEffect() async {
      expect(await harness.extensionState(), before);
    }

    List<({String method, String path, Object? body})> managementRequests() => [
      for (final route in extensionManagementRoutes)
        concreteManagementRequest(route, targetId: target, dormantId: dormant),
    ];

    Future<void> expectEveryRouteRefused(
      String host, {
      Map<String, String> headers = const {},
      int status = 401,
    }) async {
      for (final request in managementRequests()) {
        final outcome = await harness.fetch(
          attacker,
          harness.url(host, request.path),
          method: request.method,
          headers: {
            if (request.body != null) 'content-type': 'application/json',
            ...headers,
          },
          body: request.body == null ? null : jsonEncode(request.body),
        );
        expect(
          outcome.status,
          status,
          reason: '${request.method} ${request.path} via $host: $outcome',
        );
      }
    }

    test('fetch to 127.0.0.1 is refused on every protected route', () async {
      await expectEveryRouteRefused('127.0.0.1');

      expect(harness.socketHits, hasLength(extensionManagementRoutes.length));
      await expectNoSideEffect();
    });

    test('fetch to localhost is refused on every protected route', () async {
      await expectEveryRouteRefused('localhost');

      await expectNoSideEffect();
    });

    test(
      'fetch to the LAN address is refused on every protected route',
      () async {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLoopback: false,
        );
        final addresses = [
          for (final interface in interfaces) ...interface.addresses,
        ];
        if (addresses.isEmpty) {
          markTestSkipped(
            'No non-loopback IPv4 address; LAN alias case not exercised',
          );
          return;
        }

        await expectEveryRouteRefused(addresses.first.address);

        await expectNoSideEffect();
      },
    );

    test('a self-supplied Authorization header does not authorize', () async {
      final ownBridgeToken =
          (await harness.probe(attacker, 'pluginBridgeToken')).value as String;
      expect(ownBridgeToken, isNotEmpty);

      for (final authorization in [
        'Bearer garbage',
        'Bearer $ownBridgeToken',
        'Basic YWRtaW46YWRtaW4=',
        'garbage',
        'Bearer ',
      ]) {
        await expectEveryRouteRefused(
          '127.0.0.1',
          headers: {'authorization': authorization},
        );
      }
      await expectEveryRouteRefused(
        '127.0.0.1',
        headers: {'authorization': 'Bearer $accountToken'},
        status: 403,
      );

      await expectNoSideEffect();
    });

    test(
      'loopback Host, Origin and forwarding headers do not authorize',
      () async {
        await expectEveryRouteRefused(
          '127.0.0.1',
          headers: {
            'host': 'localhost',
            'origin': 'http://localhost',
            'referer': 'http://localhost/',
            'x-forwarded-for': '127.0.0.1',
            'x-real-ip': '127.0.0.1',
            'forwarded': 'for=127.0.0.1;host=localhost',
            'x-forwarded-host': 'localhost',
          },
        );

        await expectNoSideEffect();
      },
    );

    test('redirects to a protected route never reach a mutation', () async {
      final redirector = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => redirector.close(force: true));
      final protected = harness.url(
        harness.loopback,
        '/api/v1/plugins/$target/disable',
      );
      redirector.listen((request) async {
        final status = int.parse(request.uri.pathSegments.last);
        request.response
          ..statusCode = status
          ..headers.set('location', protected);
        await request.response.close();
      });

      final observed = <String, Object?>{};
      for (final method in ['GET', 'POST']) {
        for (final status in [301, 302, 303, 307, 308]) {
          harness.socketHits.clear();
          final outcome = await harness.fetch(
            attacker,
            'http://127.0.0.1:${redirector.port}/redirect/$status',
            method: method,
            body: method == 'POST' ? '{}' : null,
          );
          observed['$method $status'] = {
            'status': outcome.resolved ? outcome.status : outcome['rejected'],
            'reachedApi': List.of(harness.socketHits),
          };
        }
      }
      printOnFailure(const JsonEncoder.withIndent('  ').convert(observed));

      for (final status in [301, 302, 303, 307, 308]) {
        expect(observed['GET $status'], {
          'status': 404,
          'reachedApi': ['GET /api/v1/plugins/$target/disable'],
        }, reason: 'GET $status');
      }
      for (final status in [301, 302, 307, 308]) {
        expect(observed['POST $status'], {
          'status': status,
          'reachedApi': <String>[],
        }, reason: 'POST $status');
      }
      expect(observed['POST 303'], {
        'status': 404,
        'reachedApi': ['GET /api/v1/plugins/$target/disable'],
      });
      await expectNoSideEffect();
    });

    test('raw HTTP over host.transport tcp gets 401', () async {
      for (final (method, path) in [
        ('POST', '/api/v1/plugins/$target/disable'),
        ('POST', '/api/v1/plugins/$target/update/approve'),
        ('DELETE', '/api/v1/plugins/$target'),
        ('POST', '/api/v1/webui/server/stop'),
      ]) {
        final raw = base64Encode(
          utf8.encode(
            '$method $path HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n',
          ),
        );
        final outcome = await harness.probe(attacker, '''
          new Promise((resolve, reject) => {
            host.transport.open({ kind: "tcp", host: "127.0.0.1", port: ${harness.port} }).then((opened) => {
              const chunks = [];
              host.transport.onEvent(opened.handle, (event) => {
                if (event.type === "data") {
                  chunks.push(event.data);
                  resolve(chunks);
                  host.transport.close(opened.handle).catch(() => {});
                } else if (event.type === "close") {
                  resolve(chunks);
                } else if (event.type === "error") {
                  reject(new Error(event.message));
                }
              });
              return host.transport.send(opened.handle, { type: "binary", data: ${jsonEncode(raw)} });
            }).catch(reject);
          })
        ''');
        expect(outcome.resolved, isTrue, reason: '$outcome');
        final response = utf8.decode([
          for (final chunk in outcome.value as List) ...base64Decode(chunk),
        ]);

        expect(
          response.split('\r\n').first,
          'HTTP/1.1 401 Unauthorized',
          reason: '$method $path',
        );
      }

      await expectNoSideEffect();
    });

    test('a WebSocket upgrade to a management route changes nothing', () async {
      final observed = <String, Object?>{};
      for (final path in [
        '/api/v1/plugins/$dormant/enable',
        '/api/v1/plugins/$target/disable',
        '/api/v1/plugins/$target/update/approve',
        '/api/v1/plugins/$target',
        '/api/v1/webui/server/stop',
        '/ws/v1/plugins/$target/disable',
      ]) {
        final outcome = await harness.probe(attacker, '''
          host.transport.open({ kind: "websocket", url: ${jsonEncode('ws://127.0.0.1:${harness.port}$path')} }).then(
            (opened) => host.transport.close(opened.handle).then(() => "opened"),
            (error) => "refused: " + error.message
          )
        ''');
        observed[path] = outcome.value;
      }
      printOnFailure(const JsonEncoder.withIndent('  ').convert(observed));

      for (final entry in observed.entries) {
        expect(entry.value, startsWith('refused'), reason: entry.key);
      }
      await expectNoSideEffect();
    });

    test('host.localApi rejects with PluginPermissionError', () async {
      final outcome = await harness.localApi(
        attacker,
        '/api/v1/plugins/$target/disable',
        options: {'method': 'POST'},
      );

      expect(outcome.errorName, 'PluginPermissionError');
      expect(outcome.errorMessage, contains('manage.extensions'));
      expect(harness.bridged, isEmpty);
      await expectNoSideEffect();
    });

    test('a direct bridge call is refused by the Dart side', () async {
      final outcome = await harness.probe(
        attacker,
        'globalThis.__reaprimePluginBridge.localApi(pluginId, pluginGeneration, pluginBridgeToken, "/api/v1/plugins/$target/disable", "POST", null, null)',
      );

      expect(outcome.resolved, isFalse);
      expect(outcome.errorMessage, contains('PluginPermissionError'));
      expect(outcome.errorMessage, contains('manage.extensions'));
      expect(harness.bridged, isEmpty);
      await expectNoSideEffect();
    });

    test('a forged generation is refused before dispatch', () async {
      final outcome = await harness.probe(
        attacker,
        'globalThis.__reaprimePluginBridge.localApi(pluginId, pluginGeneration + 1, pluginBridgeToken, "/api/v1/plugins/$target/disable", "POST", null, null)',
      );

      expect(outcome.resolved, isFalse);
      expect(harness.bridged, isEmpty);
      await expectNoSideEffect();
    });

    test(
      'it cannot claim the identity of a plugin that holds the grant',
      () async {
        final state = await harness.settledState(
          steward,
          'globalThis.__probes[${jsonEncode(attacker)}].run(${jsonEncode('globalThis.__reaprimePluginBridge.localApi(${jsonEncode(steward)}, pluginGeneration, pluginBridgeToken, "/api/v1/webui/server/stop", "POST", null, null)')})',
        );

        expect(state, isNot(startsWith('resolved')), reason: state);
        expect(harness.bridged, ['GET /api/v1/test/marker']);
        await expectNoSideEffect();
      },
    );
  });

  group('self-escalation', () {
    late FakeGitHub gitHub;

    setUp(() => gitHub = FakeGitHub());

    Future<void> withHarness(
      Future<void> Function(ExtensionManagementHarness harness) body,
    ) => http.runWithClient(() async {
      final harness = await ExtensionManagementHarness.start();
      try {
        await body(harness);
      } finally {
        await harness.dispose();
      }
    }, () => gitHub.client);

    Future<void> installWithPendingUpdate(
      ExtensionManagementHarness harness,
      String id, {
      required List<String> installed,
      required List<String> update,
    }) async {
      final repo = 'acme/${id.split('.').first}';
      gitHub.publish(repo, id, '1.0.0', permissions: installed);
      await harness.sourceService.installFromGitHubRelease(repo);
      await harness.loader.enablePlugin(id);
      gitHub.publish(repo, id, '1.1.0', permissions: update);
      await harness.sourceService.updateAllPlugins();
      expect(
        harness.sourceService.sourceFor(id)?.pendingUpdate?.version,
        '1.1.0',
      );
    }

    test(
      'a plugin whose pending update adds manage.extensions cannot approve it',
      () => withHarness((harness) async {
        final climber = uniqueId('climber');
        await installWithPendingUpdate(
          harness,
          climber,
          installed: unprivilegedPermissions,
          update: [...unprivilegedPermissions, 'manage.extensions'],
        );
        expect(
          harness.sourceService
              .sourceFor(climber)
              ?.pendingUpdate
              ?.addedPermissions,
          ['manage.extensions'],
        );
        final before = await harness.extensionState();
        final downloadsBefore = gitHub.requests.length;

        final approveByFetch = await harness.fetch(
          climber,
          harness.url(
            harness.loopback,
            '/api/v1/plugins/$climber/update/approve',
          ),
          method: 'POST',
        );
        final updateByFetch = await harness.fetch(
          climber,
          harness.url(harness.loopback, '/api/v1/plugins/update'),
          method: 'POST',
        );
        final approveByLocalApi = await harness.localApi(
          climber,
          '/api/v1/plugins/$climber/update/approve',
          options: {'method': 'POST'},
        );
        final approveByBridge = await harness.probe(
          climber,
          'globalThis.__reaprimePluginBridge.localApi(pluginId, pluginGeneration, pluginBridgeToken, "/api/v1/plugins/$climber/update/approve", "POST", null, null)',
        );
        final rewriteByFetch = await harness.fetch(
          climber,
          harness.url(harness.loopback, '/api/v1/plugins/$climber/source'),
          method: 'PUT',
          headers: {'content-type': 'application/json'},
          body: jsonEncode({
            'manifest': pluginManifestJson(
              climber,
              permissions: [...unprivilegedPermissions, 'manage.extensions'],
              version: '1.2.0',
            ),
            'plugin': probePluginJs(climber),
          }),
        );

        expect(approveByFetch.status, 401);
        expect(updateByFetch.status, 401);
        expect(approveByLocalApi.errorName, 'PluginPermissionError');
        expect(approveByBridge.errorMessage, contains('PluginPermissionError'));
        expect(rewriteByFetch.status, 401);
        expect(harness.bridged, isEmpty);
        expect(gitHub.requests.length, downloadsBefore);
        expect(await harness.extensionState(), before);
        expect(harness.loader.getPluginManifest(climber)?.version, '1.0.0');
      }),
    );

    test(
      'after approval with an extensions:manage token the plugin holds the grant',
      () => withHarness((harness) async {
        final climber = uniqueId('climber');
        await installWithPendingUpdate(
          harness,
          climber,
          installed: unprivilegedPermissions,
          update: [...unprivilegedPermissions, 'manage.extensions'],
        );

        final approved = await harness.externalRequest(
          'POST',
          '/api/v1/plugins/$climber/update/approve',
          bearer: managerToken,
        );
        final echo = await harness.localApi(climber, '/api/v1/test/echo');

        expect(approved.status, 200, reason: approved.body);
        expect(harness.loader.getPluginManifest(climber)?.version, '1.1.0');
        expect(harness.loader.isPluginLoaded(climber), isTrue);
        expect(echo.status, 200, reason: '$echo');
        expect(echo.jsonBody['hasGrant'], isTrue);
        expect(echo.jsonBody['mayManage'], isTrue);
      }),
    );

    test(
      'a plugin that holds the grant can approve another plugin escalation',
      () => withHarness((harness) async {
        final delegate = uniqueId('delegate');
        final climber = uniqueId('climber');
        await harness.install(delegate, permissions: privilegedPermissions);
        await installWithPendingUpdate(
          harness,
          climber,
          installed: unprivilegedPermissions,
          update: [...unprivilegedPermissions, 'manage.extensions'],
        );

        final approved = await harness.localApi(
          delegate,
          '/api/v1/plugins/$climber/update/approve',
          options: {'method': 'POST'},
        );
        final echo = await harness.localApi(climber, '/api/v1/test/echo');

        expect(approved.status, 200, reason: '$approved');
        expect(harness.loader.getPluginManifest(climber)?.version, '1.1.0');
        expect(echo.status, 200, reason: '$echo');
        expect(echo.jsonBody['hasGrant'], isTrue);
      }),
    );

    test(
      'a plugin that holds the grant can approve its own pending update',
      () => withHarness((harness) async {
        final observer = uniqueId('observer');
        final steward = uniqueId('steward');
        await harness.install(observer, permissions: privilegedPermissions);
        await installWithPendingUpdate(
          harness,
          steward,
          installed: privilegedPermissions,
          update: [...privilegedPermissions, 'network.tcp'],
        );

        final outcome = await harness.localApi(
          steward,
          '/api/v1/plugins/$steward/update/approve',
          options: {'method': 'POST'},
          reportVia: observer,
        );
        await harness.settleBridgedHandlers();
        final approval = await harness.bridgedResponses.single;
        final fresh = await harness.localApi(steward, '/api/v1/test/echo');

        expect(outcome.errorMessage, 'plugin unloaded');
        expect(approval.statusCode, 200);
        final manifest = harness.loader.getPluginManifest(steward)!;
        expect(manifest.version, '1.1.0');
        expect(
          manifest.permissions.map((p) => p.wireName),
          containsAll(['manage.extensions', 'network.tcp']),
        );
        expect(harness.loader.isPluginLoaded(steward), isTrue);
        expect(fresh.status, 200);
        expect(fresh.jsonBody['hasGrant'], isTrue);
      }),
    );
  });
}
