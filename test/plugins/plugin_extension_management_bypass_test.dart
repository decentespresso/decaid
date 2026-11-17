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
            'origin': 'http://localhost:3000',
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

    test('it cannot claim the identity of a plugin that holds the grant', () async {
      final state = await harness.settledState(
        steward,
        'globalThis.__probes[${jsonEncode(attacker)}].run(${jsonEncode('globalThis.__reaprimePluginBridge.localApi(${jsonEncode(steward)}, pluginGeneration, pluginBridgeToken, "/api/v1/webui/server/stop", "POST", null, null)')})',
      );

      expect(state, isNot(startsWith('resolved')), reason: state);
      expect(harness.bridged, ['GET $fixtureMarker']);
      await expectNoSideEffect();
    });
  });

  group('a plugin with api and network permissions in compatibility mode', () {
    late ExtensionManagementHarness harness;
    late String client;
    late String target;
    late String dormant;

    setUp(() async {
      harness = await ExtensionManagementHarness.start(
        requireExtensionManagementAuthorization: false,
      );
      client = uniqueId('legacy');
      target = uniqueId('legacytarget');
      dormant = uniqueId('legacydormant');
      await harness.install(client);
      await harness.install(target);
      await harness.install(dormant, load: false);
    });

    tearDown(() async {
      await harness.dispose();
    });

    Future<List<String>> nonLoopbackAddresses() async {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      return [
        for (final interface in interfaces)
          for (final address in interface.addresses) address.address,
      ];
    }

    test('the Streamline workflow through fetch mutates the fixtures without '
        'a bearer', () async {
      final enable = await harness.fetch(
        client,
        harness.url(harness.loopback, '/api/v1/plugins/$dormant/enable'),
        method: 'POST',
      );
      expect(enable.status, 200, reason: '$enable');
      expect(harness.loader.isPluginLoaded(dormant), isTrue);

      final settings = await harness.fetch(
        client,
        harness.url(harness.loopback, '/api/v1/plugins/$target/settings'),
        method: 'POST',
        headers: {'content-type': 'application/json'},
        body: jsonEncode({'mode': 'streamline'}),
      );
      expect(settings.status, 200, reason: '$settings');
      expect(
        await harness.loader.pluginSettings(target),
        containsPair('mode', 'streamline'),
      );

      final disable = await harness.fetch(
        client,
        harness.url(harness.loopback, '/api/v1/plugins/$target/disable'),
        method: 'POST',
      );
      expect(disable.status, 200, reason: '$disable');
      expect(harness.loader.isPluginLoaded(target), isFalse);
      expect(await harness.loader.shouldAutoLoad(target), isFalse);

      final sourceWrite = await harness.fetch(
        client,
        harness.url(harness.loopback, '/api/v1/plugins/$target/source'),
        method: 'PUT',
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'manifest': pluginManifestJson(target, version: '2.0.0'),
          'plugin': probePluginJs(target),
        }),
      );
      expect(sourceWrite.status, 200, reason: '$sourceWrite');
      expect(harness.loader.getPluginManifest(target)?.version, '2.0.0');
    });

    test(
      'a tokenless LAN caller reaches the same handlers through fetch',
      () async {
        final addresses = await nonLoopbackAddresses();
        if (addresses.isEmpty) {
          markTestSkipped(
            'No non-loopback IPv4 address; the LAN caller case was not '
            'exercised',
          );
          return;
        }
        for (final host in [harness.loopback, 'localhost', addresses.first]) {
          final outcome = await harness.fetch(
            client,
            harness.url(host, '/api/v1/plugins/$dormant/enable'),
            method: 'POST',
          );
          expect(outcome.status, 200, reason: '$host: $outcome');
          expect(harness.loader.isPluginLoaded(dormant), isTrue, reason: host);
          await harness.loader.disablePlugin(dormant);
        }
      },
    );

    test('raw HTTP over host.transport tcp reaches the handler', () async {
      final raw = base64Encode(
        utf8.encode(
          'POST /api/v1/plugins/$dormant/enable HTTP/1.1\r\n'
          'Host: localhost\r\nContent-Length: 0\r\n\r\n',
        ),
      );
      final outcome = await harness.probe(client, '''
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
      expect(response.split('\r\n').first, 'HTTP/1.1 200 OK', reason: response);
      expect(harness.loader.isPluginLoaded(dormant), isTrue);
    });

    test(
      'a plugin without manage.extensions still cannot use host.localApi',
      () async {
        final outcome = await harness.localApi(
          client,
          '/api/v1/plugins/$dormant/enable',
          options: {'method': 'POST'},
        );

        expect(outcome.errorName, 'PluginPermissionError');
        expect(outcome.errorMessage, contains('manage.extensions'));
        expect(harness.bridged, isEmpty);
        expect(harness.loader.isPluginLoaded(dormant), isFalse);
      },
    );
  });

  group('the manage.extensions grant in both modes', () {
    for (final required in [true, false]) {
      group(required ? 'protected mode' : 'compatibility mode', () {
        late ExtensionManagementHarness harness;
        late String steward;
        late String plain;
        late String target;
        late String dormant;

        setUp(() async {
          harness = await ExtensionManagementHarness.start(
            requireExtensionManagementAuthorization: required,
          );
          steward = uniqueId('grantsteward');
          plain = uniqueId('grantplain');
          target = uniqueId('granttarget');
          dormant = uniqueId('grantdormant');
          await harness.install(steward, permissions: privilegedPermissions);
          await harness.install(plain);
          await harness.install(target);
          await harness.install(dormant, load: false);
        });

        tearDown(() async {
          await harness.dispose();
        });

        test('an approved plugin reaches management handlers through '
            'host.localApi and a forged generation is still refused', () async {
          final enabled = await harness.localApi(
            steward,
            '/api/v1/plugins/$dormant/enable',
            options: {'method': 'POST'},
          );
          expect(enabled.status, 200, reason: '$enabled');
          expect(harness.loader.isPluginLoaded(dormant), isTrue);

          final echo = await harness.localApi(steward, fixtureEcho);
          expect(echo.status, 200, reason: '$echo');
          expect(echo.jsonBody['hasGrant'], isTrue);
          expect(echo.jsonBody['mayManage'], isTrue);

          final forged = await harness.probe(
            steward,
            'globalThis.__reaprimePluginBridge.localApi(pluginId, pluginGeneration + 1, pluginBridgeToken, "/api/v1/plugins/$dormant/disable", "POST", null, null)',
          );
          expect(forged.resolved, isFalse, reason: '$forged');
          expect(harness.loader.isPluginLoaded(dormant), isTrue);
        });

        test(
          'a plugin without manage.extensions is refused before dispatch',
          () async {
            final outcome = await harness.localApi(
              plain,
              '/api/v1/plugins/$dormant/enable',
              options: {'method': 'POST'},
            );

            expect(outcome.errorName, 'PluginPermissionError');
            expect(outcome.errorMessage, contains('manage.extensions'));
            expect(harness.bridged, isEmpty);
            expect(harness.loader.isPluginLoaded(dormant), isFalse);
          },
        );

        test('fetch never carries the host grant', () async {
          final outcome = await harness.fetch(
            steward,
            harness.url(harness.loopback, fixtureEcho),
          );
          expect(outcome.status, 200, reason: '$outcome');
          final seen = harness.routed.last;
          expect(seen.grant, isNull);
          expect(
            seen.headers.keys.map((name) => name.toLowerCase()),
            isNot(contains('authorization')),
          );
          expect(seen.mayManage, required ? isFalse : isTrue);
          expect(harness.bridged, isEmpty);
        });
      });
    }
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
        final echo = await harness.localApi(climber, fixtureEcho);

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
        final echo = await harness.localApi(climber, fixtureEcho);

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
        final fresh = await harness.localApi(steward, fixtureEcho);

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

  group('manual update checks', () {
    const pluginsUpdate = '/api/v1/plugins/update';
    const skinsUpdate = '/api/v1/webui/skins/update';
    const forgedLoopbackHeaders = {
      'origin': 'http://localhost:3000',
      'referer': 'http://localhost/',
      'x-forwarded-for': '127.0.0.1',
      'x-real-ip': '127.0.0.1',
      'forwarded': 'for=127.0.0.1;host=localhost',
      'x-forwarded-host': 'localhost',
    };

    late FakeGitHub gitHub;

    setUp(() => gitHub = FakeGitHub());

    Future<List<String>> nonLoopbackAddresses() async {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      return [
        for (final interface in interfaces)
          for (final address in interface.addresses) address.address,
      ];
    }

    Future<void> withManagement(
      bool protected,
      Future<void> Function(ExtensionManagementHarness harness) body,
    ) => http.runWithClient(() async {
      final harness = await ExtensionManagementHarness.start(
        requireExtensionManagementAuthorization: protected,
      );
      try {
        await body(harness);
      } finally {
        await harness.dispose();
      }
    }, () => gitHub.client);

    Future<String> installGitHubSource(
      ExtensionManagementHarness harness,
      String name,
    ) async {
      final id = uniqueId(name);
      gitHub.publish(
        'acme/$name',
        id,
        '1.0.0',
        permissions: unprivilegedPermissions,
      );
      await harness.sourceService.installFromGitHubRelease('acme/$name');
      await harness.loader.enablePlugin(id);
      return id;
    }

    Future<void> expectBothManualChecksRun(
      ExtensionManagementHarness harness,
      String host,
      String pluginId,
    ) async {
      final pollsBefore = gitHub.requests.length;
      final checkedBefore = harness.sourceService
          .sourceFor(pluginId)
          ?.lastChecked;
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(
        gitHub.requests.length,
        pollsBefore,
        reason: 'nothing polls GitHub before a manual check',
      );
      expect(
        harness.sourceService.sourceFor(pluginId)?.lastChecked,
        checkedBefore,
        reason: 'no background scheduler is wired into the harness',
      );
      expect(harness.skins.mutations, isEmpty);

      final skins = await harness.externalRequestFrom(
        host,
        'POST',
        skinsUpdate,
      );
      expect(skins.status, 200, reason: skins.body);
      expect(harness.skins.mutations, ['checkForSkinUpdates']);

      final plugins = await harness.externalRequestFrom(
        host,
        'POST',
        pluginsUpdate,
      );
      expect(plugins.status, 200, reason: plugins.body);
      expect(
        gitHub.requests.length,
        greaterThan(pollsBefore),
        reason: 'the manual check must poll the installed source',
      );
      expect(
        harness.sourceService.sourceFor(pluginId)?.lastChecked,
        isNot(checkedBefore),
      );
    }

    group('compatibility mode', () {
      test(
        'a tokenless localhost caller runs both manual checks',
        () => withManagement(false, (harness) async {
          final id = await installGitHubSource(harness, 'compatlocal');
          for (final host in ['127.0.0.1', 'localhost']) {
            harness.skins.mutations.clear();
            await expectBothManualChecksRun(harness, host, id);
          }
        }),
      );

      test(
        'a tokenless LAN caller runs both manual checks',
        () => withManagement(false, (harness) async {
          final addresses = await nonLoopbackAddresses();
          if (addresses.isEmpty) {
            markTestSkipped(
              'No non-loopback IPv4 address; LAN peer case not exercised',
            );
            return;
          }
          final id = await installGitHubSource(harness, 'compatlan');
          await expectBothManualChecksRun(harness, addresses.first, id);
        }),
      );

      test(
        'a tokenless manual check keeps a permission escalation pending '
        'until it is approved',
        () => withManagement(false, (harness) async {
          final climber = uniqueId('climber');
          gitHub.publish(
            'acme/climber',
            climber,
            '1.0.0',
            permissions: unprivilegedPermissions,
          );
          await harness.sourceService.installFromGitHubRelease('acme/climber');
          await harness.loader.enablePlugin(climber);
          gitHub.publish(
            'acme/climber',
            climber,
            '1.1.0',
            permissions: [...unprivilegedPermissions, 'manage.extensions'],
          );

          final check = await harness.externalRequest('POST', pluginsUpdate);
          expect(check.status, 200, reason: check.body);

          final pending = harness.sourceService
              .sourceFor(climber)
              ?.pendingUpdate;
          expect(pending?.version, '1.1.0');
          expect(pending?.addedPermissions, ['manage.extensions']);
          expect(harness.loader.getPluginManifest(climber)?.version, '1.0.0');

          final approve = await harness.externalRequest(
            'POST',
            '/api/v1/plugins/$climber/update/approve',
          );
          expect(approve.status, 200, reason: approve.body);
          expect(harness.loader.getPluginManifest(climber)?.version, '1.1.0');
          expect(harness.loader.isPluginLoaded(climber), isTrue);
        }),
      );
    });

    group('protected mode', () {
      Future<void> withProtected(
        Future<void> Function(
          ExtensionManagementHarness harness,
          String target,
          String dormant,
          Map<String, Object?> before,
        )
        body,
      ) => withManagement(true, (harness) async {
        final target = uniqueId('target');
        final dormant = uniqueId('dormant');
        await harness.install(target);
        await harness.install(dormant, load: false);
        await body(harness, target, dormant, await harness.extensionState());
      });

      List<({String method, String path, Object? body})> requests(
        String target,
        String dormant,
      ) => [
        for (final route in extensionManagementRoutes)
          concreteManagementRequest(
            route,
            targetId: target,
            dormantId: dormant,
          ),
      ];

      Future<void> expectEveryRouteRefused(
        ExtensionManagementHarness harness,
        String host,
        String target,
        String dormant, {
        Map<String, String> headers = const {},
        int status = 401,
      }) async {
        for (final request in requests(target, dormant)) {
          final outcome = await harness.externalRequestFrom(
            host,
            request.method,
            request.path,
            headers: {
              ...headers,
              if (request.body != null) 'content-type': 'application/json',
            },
            body: request.body,
          );
          expect(
            outcome.status,
            status,
            reason:
                '${request.method} ${request.path} via $host: '
                '${outcome.body}',
          );
          if (status == 401) {
            expect(
              outcome.headers['www-authenticate'],
              'Bearer',
              reason: '${request.method} ${request.path} via $host',
            );
          } else {
            expect(jsonDecode(outcome.body), {
              'error':
                  'Extension management is not allowed from this browser '
                  'origin',
            }, reason: '${request.method} ${request.path} via $host');
          }
        }
      }

      test(
        'a tokenless caller is refused on every management route',
        () => withProtected((harness, target, dormant, before) async {
          for (final host in ['127.0.0.1', 'localhost']) {
            await expectEveryRouteRefused(harness, host, target, dormant);
            await expectEveryRouteRefused(
              harness,
              host,
              target,
              dormant,
              headers: forgedLoopbackHeaders,
            );
          }
          expect(await harness.extensionState(), before);
        }),
      );

      test(
        'a tokenless LAN caller is refused on every route',
        () => withProtected((harness, target, dormant, before) async {
          final addresses = await nonLoopbackAddresses();
          if (addresses.isEmpty) {
            markTestSkipped(
              'No non-loopback IPv4 address; LAN peer case not exercised',
            );
            return;
          }
          await expectEveryRouteRefused(
            harness,
            addresses.first,
            target,
            dormant,
          );
          await expectEveryRouteRefused(
            harness,
            addresses.first,
            target,
            dormant,
            headers: forgedLoopbackHeaders,
            status: 403,
          );
          expect(await harness.extensionState(), before);
        }),
      );

      test(
        'both manual update routes are refused and do no work',
        () => withProtected((harness, target, dormant, before) async {
          final id = await installGitHubSource(harness, 'protectedupdate');
          final withSource = await harness.extensionState();
          final pollsBefore = gitHub.requests.length;

          for (final path in [pluginsUpdate, skinsUpdate]) {
            for (final headers in const [
              <String, String>{},
              forgedLoopbackHeaders,
            ]) {
              final outcome = await harness.externalRequest(
                'POST',
                path,
                headers: headers,
              );
              expect(outcome.status, 401, reason: '$path $headers');
            }
          }

          expect(harness.skins.mutations, isEmpty);
          expect(gitHub.requests.length, pollsBefore);
          expect(harness.sourceService.sourceFor(id)?.pendingUpdate, isNull);
          expect(await harness.extensionState(), withSource);
        }),
      );

      test(
        'a valid manager token still runs both manual checks',
        () => withProtected((harness, target, dormant, before) async {
          final id = await installGitHubSource(harness, 'managedupdate');
          final pollsBefore = gitHub.requests.length;

          final skins = await harness.externalRequest(
            'POST',
            skinsUpdate,
            bearer: managerToken,
          );
          expect(skins.status, 200, reason: skins.body);
          expect(harness.skins.mutations, ['checkForSkinUpdates']);

          final plugins = await harness.externalRequest(
            'POST',
            pluginsUpdate,
            bearer: managerToken,
          );
          expect(plugins.status, 200, reason: plugins.body);
          expect(
            gitHub.requests.length,
            greaterThan(pollsBefore),
            reason: 'the manual check must poll the installed source',
          );
          expect(harness.sourceService.sourceFor(id)?.lastChecked, isNotNull);
        }),
      );

      test(
        'malformed credentials are 401 and wrong-scope credentials are 403',
        () => withProtected((harness, target, dormant, before) async {
          for (final request in requests(target, dormant)) {
            for (final (authorization, status) in [
              ('Bearer not-a-token', 401),
              ('Bearer $accountToken', 403),
            ]) {
              final outcome = await harness.externalRequestFrom(
                harness.loopback,
                request.method,
                request.path,
                headers: {'authorization': authorization},
                body: request.body,
              );
              expect(
                outcome.status,
                status,
                reason: '${request.method} ${request.path} $authorization',
              );
              if (status == 403) {
                expect(
                  (jsonDecode(outcome.body) as Map)['error'],
                  contains('extensions:manage'),
                );
              }
            }
          }
          expect(await harness.extensionState(), before);
        }),
      );
    });
  });

  group('pre-existing CORS policy', () {
    const origin = 'http://localhost:3000';
    const pluginsUpdate = '/api/v1/plugins/update';
    const corsHeaderNames = [
      'access-control-allow-origin',
      'access-control-allow-credentials',
      'access-control-expose-headers',
      'access-control-allow-headers',
      'access-control-allow-methods',
    ];

    Map<String, String?> corsOf(
      ({int status, String body, Map<String, String> headers}) outcome,
    ) => {for (final name in corsHeaderNames) name: outcome.headers[name]};

    Future<void> withMode(
      bool protected,
      Future<void> Function(ExtensionManagementHarness harness) body,
    ) => http.runWithClient(() async {
      final harness = await ExtensionManagementHarness.start(
        requireExtensionManagementAuthorization: protected,
      );
      try {
        await body(harness);
      } finally {
        await harness.dispose();
      }
    }, () => FakeGitHub().client);

    test('a management request keeps the existing CORS headers in both modes '
        'while authorization differs', () async {
      final observed = <String, ({int status, Map<String, String?> cors})>{};

      await withMode(false, (harness) async {
        final outcome = await harness.externalRequest(
          'POST',
          pluginsUpdate,
          headers: const {'origin': origin},
        );
        observed['compatibility'] = (
          status: outcome.status,
          cors: corsOf(outcome),
        );
      });

      await withMode(true, (harness) async {
        final refused = await harness.externalRequest(
          'POST',
          pluginsUpdate,
          headers: const {'origin': origin},
        );
        observed['protected tokenless'] = (
          status: refused.status,
          cors: corsOf(refused),
        );

        final managed = await harness.externalRequest(
          'POST',
          pluginsUpdate,
          bearer: managerToken,
          headers: const {'origin': origin},
        );
        observed['protected manager'] = (
          status: managed.status,
          cors: corsOf(managed),
        );
      });

      expect(observed['compatibility']!.status, 200);
      expect(observed['protected tokenless']!.status, 401);
      expect(observed['protected manager']!.status, 200);

      final openCors = observed['compatibility']!.cors;
      expect(openCors['access-control-allow-origin'], origin);
      expect(openCors['access-control-allow-credentials'], 'true');
      expect(openCors['access-control-expose-headers'], isNotEmpty);
      expect(openCors['access-control-allow-headers'], isNotEmpty);
      expect(observed['protected tokenless']!.cors, openCors);
      expect(observed['protected manager']!.cors, openCors);
    });

    test(
      'OPTIONS keeps its pre-existing CORS preflight in both modes',
      () async {
        for (final protected in [false, true]) {
          await withMode(protected, (harness) async {
            final outcome = await harness.externalRequest(
              'OPTIONS',
              pluginsUpdate,
              headers: const {
                'origin': origin,
                'access-control-request-method': 'POST',
              },
            );
            expect(outcome.status, 200, reason: 'protected: $protected');
            expect(
              outcome.headers['access-control-allow-origin'],
              origin,
              reason: 'protected: $protected',
            );
            expect(
              outcome.headers['access-control-allow-methods'],
              isNotEmpty,
              reason: 'protected: $protected',
            );
          });
        }
      },
    );

    test('the account proxy keeps its restrictive ACAO rule', () async {
      await withMode(false, (harness) async {
        final proxied = await harness.externalRequest(
          'POST',
          '/api/v1/account/proxy/models',
          bearer: accountToken,
          headers: const {'origin': origin},
          body: const {'ping': 1},
        );
        expect(proxied.status, 200, reason: proxied.body);
        expect(harness.accountProxyHits, hasLength(1));
        expect(proxied.headers['access-control-allow-origin'], isNull);

        final management = await harness.externalRequest(
          'POST',
          pluginsUpdate,
          headers: const {'origin': origin},
        );
        expect(management.status, 200, reason: management.body);
        expect(management.headers['access-control-allow-origin'], origin);
      });
    });
  });

  group('browser origin boundary', () {
    const untrustedOrigin = 'https://evil.example';
    const refusedError =
        'Extension management is not allowed from this browser origin';

    Future<void> withProtected(
      Future<void> Function(ExtensionManagementHarness harness) body,
    ) => http.runWithClient(() async {
      final harness = await ExtensionManagementHarness.start(
        requireExtensionManagementAuthorization: true,
      );
      try {
        await body(harness);
      } finally {
        await harness.dispose();
      }
    }, () => FakeGitHub().client);

    test(
      'an explicit untrusted origin is refused even with a valid bearer',
      () => withProtected((harness) async {
        final before = await harness.extensionState();
        for (final path in [
          '/api/v1/plugins/update',
          '/api/v1/webui/skins/update',
        ]) {
          final outcome = await harness.externalRequest(
            'POST',
            path,
            bearer: managerToken,
            headers: const {'origin': untrustedOrigin},
          );
          expect(outcome.status, 403, reason: '$path: ${outcome.body}');
          expect(jsonDecode(outcome.body), {
            'error': refusedError,
          }, reason: path);
          expect(
            outcome.headers['access-control-allow-origin'],
            isNull,
            reason: path,
          );
        }
        expect(await harness.extensionState(), before);
        expect(harness.skins.mutations, isEmpty);
        expect(harness.skinServer.mutations, isEmpty);
      }),
    );

    test(
      'an untrusted origin keeps the account proxy rule unchanged',
      () => withProtected((harness) async {
        final proxied = await harness.externalRequest(
          'POST',
          '/api/v1/account/proxy/models',
          bearer: accountToken,
          headers: const {'origin': untrustedOrigin},
          body: const {'ping': 1},
        );
        expect(proxied.status, 200, reason: proxied.body);
        expect(harness.accountProxyHits, hasLength(1));
        expect(proxied.headers['access-control-allow-origin'], isNull);
      }),
    );

    test('a loopback origin from a non-loopback socket peer needs that peer to '
        'be a live device address', () async {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final addresses = [
        for (final interface in interfaces)
          for (final address in interface.addresses) address.address,
      ];
      if (addresses.isEmpty) {
        markTestSkipped(
          'No non-loopback IPv4 address; the LAN peer case was not '
          'exercised',
        );
        return;
      }
      final peer = addresses.first;
      const origin = 'http://localhost:3000';
      const path = '/api/v1/webui/skins/update';

      for (final protected in [false, true]) {
        await http.runWithClient(() async {
          final harness = await ExtensionManagementHarness.start(
            requireExtensionManagementAuthorization: protected,
          );
          try {
            final before = await harness.extensionState();
            final refused = await harness.externalRequestFrom(
              peer,
              'POST',
              path,
              bearer: protected ? managerToken : null,
              headers: const {'origin': origin},
            );
            expect(
              refused.status,
              403,
              reason: '$peer protected=$protected: ${refused.body}',
            );
            expect(jsonDecode(refused.body), {'error': refusedError});
            expect(
              refused.headers['access-control-allow-origin'],
              isNull,
              reason: 'protected=$protected',
            );
            expect(await harness.extensionState(), before);
            expect(harness.skins.mutations, isEmpty);

            harness.skinServer.browserOriginAddresses = {peer};
            final sameDevice = await harness.externalRequestFrom(
              peer,
              'POST',
              path,
              bearer: protected ? managerToken : null,
              headers: const {'origin': origin},
            );
            expect(
              sameDevice.status,
              200,
              reason: '$peer protected=$protected: ${sameDevice.body}',
            );
            expect(harness.skins.mutations, ['checkForSkinUpdates']);

            harness.skinServer.browserOriginAddresses = const {};
            final retired = await harness.externalRequestFrom(
              peer,
              'POST',
              path,
              bearer: protected ? managerToken : null,
              headers: const {'origin': origin},
            );
            expect(
              retired.status,
              403,
              reason: '$peer protected=$protected: ${retired.body}',
            );
            expect(harness.skins.mutations, hasLength(1));
          } finally {
            await harness.dispose();
          }
        }, () => FakeGitHub().client);
      }
    });

    test(
      'the live skin port and the API listener port stay trusted',
      () => withProtected((harness) async {
        final skinOrigin = 'http://localhost:${harness.skinServer.port}';
        final apiOrigin = 'http://localhost:${harness.port}';
        for (final origin in [skinOrigin, apiOrigin]) {
          final outcome = await harness.externalRequest(
            'POST',
            '/api/v1/webui/skins/update',
            bearer: managerToken,
            headers: {'origin': origin},
          );
          expect(outcome.status, 200, reason: '$origin: ${outcome.body}');
          expect(
            outcome.headers['access-control-allow-origin'],
            origin,
            reason: origin,
          );
        }
        expect(harness.skins.mutations, [
          'checkForSkinUpdates',
          'checkForSkinUpdates',
        ]);

        harness.skinServer.serving = false;
        final retired = await harness.externalRequest(
          'POST',
          '/api/v1/webui/skins/update',
          bearer: managerToken,
          headers: {'origin': skinOrigin},
        );
        expect(retired.status, 403, reason: retired.body);
        expect(harness.skins.mutations, hasLength(2));
      }),
    );
  });
}
