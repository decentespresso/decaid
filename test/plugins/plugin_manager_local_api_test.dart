import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:reaprime/src/plugins/plugin_manager.dart';
import 'package:reaprime/src/plugins/plugin_manifest.dart';
import 'package:shelf/shelf.dart' as shelf;

import 'extension_management_harness.dart';
import 'plugin_test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ExtensionManagementHarness harness;
  var seq = 0;
  String uniqueId(String name) => '$name${++seq}.reaplugin';

  setUp(() async {
    harness = await ExtensionManagementHarness.start();
  });

  tearDown(() async {
    await harness.dispose();
  });

  group('authorized host.localApi', () {
    test('performs plugin operations on other plugins', () async {
      final actor = uniqueId('actor');
      final target = uniqueId('target');
      final dormant = uniqueId('dormant');
      final removable = uniqueId('removable');
      await harness.install(actor, permissions: privilegedPermissions);
      await harness.install(target);
      await harness.install(dormant, load: false);
      await harness.install(removable);

      final source = await harness.localApi(
        actor,
        '/api/v1/plugins/$target/source',
        options: {
          'method': 'PUT',
          'body': {
            'manifest': pluginManifestJson(target, version: '2.0.0'),
            'plugin': probePluginJs(target),
          },
        },
      );
      expect(source.status, 200, reason: '$source');
      expect(
        source.response.keys,
        unorderedEquals(['status', 'headers', 'body']),
      );
      expect(source.response['headers'], isA<Map>());
      expect(source.header('content-type'), contains('application/json'));
      expect(source.jsonBody, containsPair('version', '2.0.0'));
      expect(harness.loader.getPluginManifest(target)?.version, '2.0.0');
      expect(harness.loader.isPluginLoaded(target), isTrue);

      final enable = await harness.localApi(
        actor,
        '/api/v1/plugins/$dormant/enable',
        options: {'method': 'POST'},
      );
      expect(enable.status, 200, reason: '$enable');
      expect(harness.loader.isPluginLoaded(dormant), isTrue);

      final settings = await harness.localApi(
        actor,
        '/api/v1/plugins/$dormant/settings',
        options: {
          'method': 'POST',
          'body': {'mode': 'fleet'},
        },
      );
      expect(settings.status, 200, reason: '$settings');
      expect(
        await harness.loader.pluginSettings(dormant),
        containsPair('mode', 'fleet'),
      );

      final disable = await harness.localApi(
        actor,
        '/api/v1/plugins/$target/disable',
        options: {'method': 'POST'},
      );
      expect(disable.status, 200, reason: '$disable');
      expect(harness.loader.isPluginLoaded(target), isFalse);
      expect(await harness.loader.shouldAutoLoad(target), isFalse);

      final removal = await harness.localApi(
        actor,
        '/api/v1/plugins/$removable',
        options: {'method': 'DELETE'},
      );
      expect(removal.status, 200, reason: '$removal');
      expect(harness.loader.getPluginManifest(removable), isNull);
    });

    test('performs skin operations', () async {
      final actor = uniqueId('actor');
      await harness.install(actor, permissions: privilegedPermissions);

      final skin = await harness.localApi(
        actor,
        '/api/v1/webui/skins/default',
        options: {
          'method': 'PUT',
          'body': {'skinId': recordedSkinId},
        },
      );
      final stop = await harness.localApi(
        actor,
        '/api/v1/webui/server/stop',
        options: {'method': 'POST'},
      );

      expect(skin.status, 200, reason: '$skin');
      expect(harness.skins.mutations, ['setDefaultSkin $recordedSkinId']);
      expect(stop.status, 200, reason: '$stop');
      expect(harness.skinServer.mutations, ['stopServing']);
    });

    test('serves read-only routes and resolves 404 and validation errors as responses', () async {
      final actor = uniqueId('actor');
      await harness.install(actor, permissions: privilegedPermissions);

      final skins = await harness.localApi(actor, '/api/v1/webui/skins');
      final settings = await harness.localApi(
        actor,
        '/api/v1/plugins/$actor/settings',
      );
      final unknownPlugin = await harness.localApi(
        actor,
        '/api/v1/plugins/nope.reaplugin/enable',
        options: {'method': 'POST'},
      );
      final invalidSkin = await harness.localApi(
        actor,
        '/api/v1/webui/skins/default',
        options: {'method': 'PUT', 'body': <String, Object?>{}},
      );
      final status = await harness.localApi(
        actor,
        '/api/v1/webui/server/status',
      );
      final plugins = await harness.localApi(actor, '/api/v1/plugins');

      expect(skins.status, 200);
      expect(
        (jsonDecode(skins.response['body'] as String) as List).single,
        containsPair('id', recordedSkinId),
      );
      expect(settings.status, 200);
      expect(unknownPlugin.status, 404);
      expect(invalidSkin.status, 400);
      expect(status.status, 200);
      expect(plugins.status, 200);
      expect(harness.skins.mutations, isEmpty);
    });

    test('exposes no registered bearer to plugin code', () async {
      final actor = uniqueId('actor');
      final endpoint = uniqueId('endpoint');
      final target = uniqueId('target');
      await harness.install(actor, permissions: privilegedPermissions);
      await harness.install(endpoint);
      await harness.install(target);
      final registered = [managerToken, accountToken, harness.tokens.skinToken];

      final mutation = await harness.localApi(
        actor,
        '/api/v1/plugins/$target/settings',
        options: {
          'method': 'POST',
          'body': {'mode': 'x'},
        },
      );
      final echoedByPlugin = await harness.localApi(
        actor,
        '/api/v1/plugins/$endpoint/echo',
        options: {
          'method': 'POST',
          'body': {'ping': 1},
        },
      );
      final echoedByRoute = await harness.localApi(
        actor,
        fixtureEcho,
        options: {'method': 'POST', 'body': 'x'},
      );
      final external = await harness.externalRequest(
        'POST',
        '/api/v1/plugins/$endpoint/echo',
        bearer: managerToken,
        body: {'ping': 2},
      );
      final globals = await harness.probe(actor, r'''
        (() => {
          const strings = [];
          const seen = new Set();
          const queue = [globalThis];
          while (queue.length > 0 && seen.size < 5000) {
            const value = queue.shift();
            if (value === null || (typeof value !== "object" && typeof value !== "function")) continue;
            if (seen.has(value)) continue;
            seen.add(value);
            for (const name of Object.getOwnPropertyNames(value)) {
              let child;
              try { child = value[name]; } catch (_) { continue; }
              if (typeof child === "string") strings.push(child);
              else queue.push(child);
            }
          }
          return strings.join("\n");
        })()
      ''');
      final ownFetch = await harness.fetch(
        actor,
        harness.url(harness.loopback, '/api/v1/plugins/$target/disable'),
        method: 'POST',
      );

      expect(mutation.status, 200);
      expect(echoedByPlugin.resolved, isFalse, reason: '$echoedByPlugin');
      final routeSeen = echoedByRoute.jsonBody;
      expect(
        (routeSeen['headers'] as Map).keys,
        isNot(contains('authorization')),
      );
      expect(routeSeen['hasGrant'], isTrue);
      expect(external.status, 200);
      expect(
        ((jsonDecode(external.body) as Map)['headers'] as Map).keys.map(
          (k) => k.toString().toLowerCase(),
        ),
        isNot(contains('authorization')),
      );
      for (final token in registered) {
        for (final text in [
          jsonEncode(mutation),
          jsonEncode(echoedByPlugin),
          jsonEncode(echoedByRoute),
          external.body,
          globals.value as String,
        ]) {
          expect(text, isNot(contains(token)));
        }
      }
      expect(ownFetch.status, 401, reason: '$ownFetch');
      expect(harness.loader.isPluginLoaded(target), isTrue);
    });

    test('with manage.extensions and without api manages plugins and skins '
        'and reaches nothing else', () async {
      final manager = uniqueId('manager');
      final target = uniqueId('target');
      final endpoint = uniqueId('endpoint');
      await harness.install(manager, permissions: managementOnlyPermissions);
      await harness.install(target);
      await harness.install(endpoint);

      final disable = await harness.localApi(
        manager,
        '/api/v1/plugins/$target/disable',
        options: {'method': 'POST'},
      );
      final skin = await harness.localApi(
        manager,
        '/api/v1/webui/skins/default',
        options: {
          'method': 'PUT',
          'body': {'skinId': recordedSkinId},
        },
      );
      final listed = await harness.localApi(manager, '/api/v1/plugins');
      expect(disable.status, 200, reason: '$disable');
      expect(harness.loader.isPluginLoaded(target), isFalse);
      expect(skin.status, 200, reason: '$skin');
      expect(harness.skins.mutations, ['setDefaultSkin $recordedSkinId']);
      expect(listed.status, 200, reason: '$listed');
      harness.bridged.clear();

      final unrelated = <(String, String, Object?)>[
        ('PUT', machineStatePath, null),
        ('GET', '/api/v1/machine/state', null),
        ('POST', '/api/v1/workflow', <String, Object?>{}),
        ('GET', '/api/v1/settings', null),
        ('POST', '/api/v1/settings', {'gatewayMode': 'full'}),
        ('POST', '/api/v1/data/import', <String, Object?>{}),
        ('POST', '/api/v1/store/$target/key', 'value'),
        ('GET', '/api/v1/account/proxy/me', null),
        ('POST', '/api/v1/plugins/$endpoint/echo', {'ping': 1}),
        ('GET', '/api/v1/plugins/$endpoint/echo', null),
        ('PUT', '/api/v1/plugins/$target/../../machine/state/espresso', null),
      ];
      for (final (method, path, body) in unrelated) {
        final outcome = await harness.localApi(
          manager,
          path,
          options: {'method': method, 'body': ?body},
        );
        expect(outcome.resolved, isFalse, reason: '$method $path: $outcome');
        expect(
          outcome.errorMessage,
          anyOf(
            contains('only the plugin and skin management routes'),
            contains('localApi changes only these settings'),
          ),
          reason: '$method $path',
        );
      }
      final ownFetch = await harness.fetch(
        manager,
        harness.url(harness.loopback, machineStatePath),
        method: 'PUT',
      );

      expect(ownFetch.resolved, isFalse, reason: '$ownFetch');
      expect(ownFetch.errorName, 'PluginPermissionError');
      expect(harness.bridged, isEmpty);
      expect(harness.machineHits, isEmpty);
      expect(harness.accountProxyHits, isEmpty);
      expect(harness.settingsPosts, isEmpty);
      expect(harness.routed, isEmpty);
    });

    test('with api and manage.extensions keeps the general API on fetch '
        'and off localApi', () async {
      final actor = uniqueId('actor');
      await harness.install(actor, permissions: privilegedPermissions);

      final bridged = await harness.localApi(
        actor,
        machineStatePath,
        options: {'method': 'PUT'},
      );
      final fetched = await harness.fetch(
        actor,
        harness.url(harness.loopback, machineStatePath),
        method: 'PUT',
      );

      expect(bridged.resolved, isFalse, reason: '$bridged');
      expect(harness.bridged, isEmpty);
      expect(fetched.status, 200, reason: '$fetched');
      expect(harness.machineHits.single.grant, isNull);
      expect(harness.machineHits.single.mayManage, isFalse);
    });

    test('changes the extension settings and no other setting', () async {
      final manager = uniqueId('manager');
      await harness.install(manager, permissions: managementOnlyPermissions);

      final mixed = await harness.localApi(
        manager,
        '/api/v1/settings',
        options: {
          'method': 'POST',
          'body': {'defaultSkinId': recordedSkinId, 'logLevel': 'FINE'},
        },
      );
      final allowed = await harness.localApi(
        manager,
        '/api/v1/settings',
        options: {
          'method': 'POST',
          'body': {'defaultSkinId': recordedSkinId},
        },
      );

      expect(mixed.resolved, isFalse, reason: '$mixed');
      expect(
        mixed.errorMessage,
        contains('localApi changes only these settings'),
      );
      expect(allowed.status, 200, reason: '$allowed');
      expect(harness.bridged, ['POST /api/v1/settings']);
      final posted = harness.settingsPosts.single;
      expect(jsonDecode(posted.body), {'defaultSkinId': recordedSkinId});
      expect(posted.mayManage, isTrue);
    });

    test('accepts only a path under /api/v1/ and a supported method', () async {
      final actor = uniqueId('actor');
      await harness.install(actor, permissions: privilegedPermissions);
      final base = harness.url(harness.loopback, '');
      final refused = <(Object?, Map<String, Object?>)>[
        ('$base$fixtureEcho', const {}),
        ('//127.0.0.1:${harness.port}$fixtureEcho', const {}),
        ('http:$fixtureEcho', const {}),
        ('api/v1/test/echo', const {}),
        ('/api/v2/test/echo', const {}),
        ('/api/v1', const {}),
        ('/ws/v1/plugins/$actor/echo', const {}),
        ('/api/v1/../../ws/v1/plugins/$actor/echo', const {}),
        ('/api/v1/%2e%2e/test/echo', const {}),
        ('$fixtureEcho#fragment', const {}),
        (42, const {}),
        (null, const {}),
        (const {'path': fixtureEcho}, const {}),
        (fixtureEcho, const {'method': 'OPTIONS'}),
        (fixtureEcho, const {'method': 'HEAD'}),
        (fixtureEcho, const {'method': 'TRACE'}),
        (fixtureEcho, const {'method': 'CONNECT'}),
        (fixtureEcho, const {'method': 'PATCH'}),
      ];

      for (final (path, options) in refused) {
        final outcome = await harness.localApi(actor, path, options: options);
        expect(outcome.resolved, isFalse, reason: '$path $options: $outcome');
        expect(outcome.errorName, 'Error', reason: '$path $options');
      }

      expect(harness.bridged, isEmpty);
      expect(harness.routed, isEmpty);
    });

    test('ignores plugin-supplied headers and authorization options', () async {
      final actor = uniqueId('actor');
      await harness.install(actor, permissions: privilegedPermissions);

      final outcome = await harness.localApi(
        actor,
        '$fixtureEcho?x=1',
        options: {
          'method': 'post',
          'body': 'payload',
          'contentType': 'text/plain',
          'headers': {
            'authorization': 'Bearer $managerToken',
            'x-forwarded-for': '127.0.0.1',
            'host': 'evil.example',
            'origin': 'http://localhost',
          },
          'authorization': 'Bearer $managerToken',
          'host': 'evil.example',
          'url': 'http://evil.example$fixtureEcho',
        },
      );

      expect(outcome.status, 200, reason: '$outcome');
      final seen = harness.routed.single;
      expect(seen.method, 'POST');
      expect(seen.body, 'payload');
      expect(seen.headers['content-type'], 'text/plain');
      expect(seen.headers.keys, isNot(contains('authorization')));
      expect(seen.headers.keys, isNot(contains('x-forwarded-for')));
      expect(seen.headers.keys, isNot(contains('origin')));
      expect(seen.headers['host'], isNot('evil.example'));
      expect(harness.bridged.single, 'POST $fixtureEcho');
    });

    test(
      'returns a redirect from a handler as data without following it',
      () async {
        final actor = uniqueId('actor');
        await harness.install(actor, permissions: privilegedPermissions);

        final outcome = await harness.localApi(actor, fixtureRedirect);

        expect(outcome.status, 307);
        expect(outcome.header('location'), fixtureEcho);
        expect(outcome.response['body'], 'moved');
        expect(harness.routed, isEmpty);
        expect(harness.bridged, ['GET $fixtureRedirect']);
      },
    );

    test(
      'sends a string body verbatim and JSON-encodes other bodies',
      () async {
        final actor = uniqueId('actor');
        await harness.install(actor, permissions: privilegedPermissions);

        await harness.localApi(
          actor,
          fixtureEcho,
          options: {'method': 'POST', 'body': '{"raw": true }'},
        );
        await harness.localApi(
          actor,
          fixtureEchoSource,
          options: {
            'method': 'PUT',
            'body': {
              'nested': [1, 'two'],
            },
          },
        );
        await harness.localApi(
          actor,
          fixtureEcho,
          options: {
            'method': 'POST',
            'body': 'a=1',
            'contentType': 'application/x-www-form-urlencoded',
          },
        );
        await harness.localApi(actor, fixtureEcho);

        final [raw, encoded, form, empty] = harness.routed;
        expect(raw.body, '{"raw": true }');
        expect(raw.headers['content-type'], 'application/json');
        expect(jsonDecode(encoded.body), {
          'nested': [1, 'two'],
        });
        expect(encoded.headers['content-type'], 'application/json');
        expect(form.body, 'a=1');
        expect(
          form.headers['content-type'],
          'application/x-www-form-urlencoded',
        );
        expect(empty.method, 'GET');
        expect(empty.body, isEmpty);
        expect(empty.headers.keys, isNot(contains('content-type')));
      },
    );

    test('cannot reach the account proxy', () async {
      final actor = uniqueId('actor');
      await harness.install(actor, permissions: privilegedPermissions);

      final read = await harness.localApi(actor, '/api/v1/account/proxy/me');
      final write = await harness.localApi(
        actor,
        '/api/v1/account/proxy/shots',
        options: {'method': 'POST', 'body': <String, Object?>{}},
      );

      expect(read.resolved, isFalse, reason: '$read');
      expect(write.resolved, isFalse, reason: '$write');
      expect(harness.bridged, isEmpty);
      expect(harness.accountProxyHits, isEmpty);
    });
  });

  group('generation-bound grant', () {
    late String actor;
    late String observer;
    late String target;

    setUp(() async {
      actor = uniqueId('actor');
      observer = uniqueId('observer');
      target = uniqueId('target');
      await harness.install(actor, permissions: privilegedPermissions);
      await harness.install(observer, permissions: privilegedPermissions);
      await harness.install(target);
    });

    Future<void> expectStaleCallRefused() async {
      harness.bridged.clear();
      final state = await harness.settledState(
        observer,
        harness.staleLocalApi(
          '/api/v1/plugins/$target/disable',
          options: {'method': 'POST'},
        ),
      );

      expect(state, isNot(startsWith('resolved')), reason: state);
      expect(harness.bridged, ['GET $fixtureMarker']);
      expect(harness.loader.isPluginLoaded(target), isTrue);
      printOnFailure('stale call state: $state');
    }

    final lifecycleChanges =
        <String, Future<void> Function(ExtensionManagementHarness, String)>{
          'reloadPlugin': (h, id) => h.loader.reloadPlugin(id),
          'unloadPlugin': (h, id) => h.loader.unloadPlugin(id),
          'disablePlugin': (h, id) => h.loader.disablePlugin(id),
          'removePlugin': (h, id) => h.loader.removePlugin(id),
        };
    for (final MapEntry(key: name, value: change) in lifecycleChanges.entries) {
      test('a closure from before $name is refused before dispatch', () async {
        final before = await harness.localApi(actor, fixtureMarker);
        expect(before.status, 200);
        harness.stash(actor);

        await change(harness, actor);

        await expectStaleCallRefused();
      });
    }

    test('a call made from onUnload is refused', () async {
      final unloading = uniqueId('unloading');
      await harness.install(
        unloading,
        permissions: privilegedPermissions,
        onUnload:
            'globalThis.__unloadAttempt = host.localApi("/api/v1/plugins/$target/disable", { method: "POST" });',
      );

      await harness.loader.unloadPlugin(unloading);
      harness.bridged.clear();
      final state = await harness.settledState(
        observer,
        'globalThis.__unloadAttempt',
      );

      expect(state, startsWith('rejected'), reason: state);
      expect(harness.bridged, ['GET $fixtureMarker']);
      expect(harness.loader.isPluginLoaded(target), isTrue);
    });

    test('a reload into a manifest without the permission leaves no authority', () async {
      harness.stash(actor);
      final dropped = await harness.externalRequest(
        'PUT',
        '/api/v1/plugins/$actor/source',
        bearer: managerToken,
        body: {
          'manifest': pluginManifestJson(actor, version: '1.1.0'),
          'plugin': probePluginJs(actor),
        },
      );
      expect(dropped.status, 200, reason: dropped.body);
      expect(harness.loader.isPluginLoaded(actor), isTrue);
      harness.bridged.clear();

      final viaHost = await harness.localApi(
        actor,
        '/api/v1/plugins/$target/disable',
        options: {'method': 'POST'},
      );
      final viaBridge = await harness.probe(
        actor,
        'globalThis.__reaprimePluginBridge.localApi(pluginId, pluginGeneration, pluginBridgeToken, "/api/v1/plugins/$target/disable", "POST", null, null)',
      );

      expect(viaHost.errorName, 'PluginPermissionError');
      expect(viaHost.errorMessage, contains('manage.extensions'));
      expect(viaBridge.resolved, isFalse);
      expect(viaBridge.errorMessage, contains('PluginPermissionError'));
      expect(viaBridge.errorMessage, contains('manage.extensions'));
      expect(harness.bridged, isEmpty);
      await expectStaleCallRefused();
    });

    test('an in-flight request is rejected on unload and the old identity stays refused', () async {
      final slow = harness.slowRoute('inflight');
      harness.stash(actor);
      final outcome = harness.localApi(
        actor,
        fixtureSlow('inflight'),
        options: {'method': 'POST'},
        reportVia: observer,
      );
      final entered = await slow.entered.future;
      expect(entered.mayManage, isTrue);
      expect(entered.grant?.isActive, isTrue);

      await harness.loader.unloadPlugin(actor);
      final rejected = await outcome;
      slow.release.complete();
      final mayManageAfterUnload = await slow.finished.future;

      expect(rejected.resolved, isFalse);
      expect(rejected.errorMessage, contains('unloaded'));
      expect(entered.grant?.isActive, isFalse);
      expect(mayManageAfterUnload, isFalse);
      await expectStaleCallRefused();
    });

    final selfOperations = <String, Map<String, Object?> Function(String)>{
      'disables': (id) => {
        'path': '/api/v1/plugins/$id/disable',
        'options': {'method': 'POST'},
      },
      'reloads': (id) => {
        'path': '/api/v1/plugins/$id/settings',
        'options': {
          'method': 'POST',
          'body': {'mode': 'self'},
        },
      },
      'removes': (id) => {
        'path': '/api/v1/plugins/$id',
        'options': {'method': 'DELETE'},
      },
    };
    for (final MapEntry(key: name, value: operation)
        in selfOperations.entries) {
      test(
        'a plugin that $name itself does not deadlock the manager',
        () async {
          final request = operation(actor);
          harness.stash(actor);

          final outcome = await harness.localApi(
            actor,
            request['path'],
            options: request['options'] as Map<String, Object?>,
            reportVia: observer,
          );
          await harness.settleBridgedHandlers();

          expect(outcome.resolved, isFalse, reason: '$outcome');
          expect(outcome.errorMessage, 'plugin unloaded');

          switch (name) {
            case 'disables':
              expect(harness.loader.isPluginLoaded(actor), isFalse);
              expect(await harness.loader.shouldAutoLoad(actor), isFalse);
            case 'reloads':
              expect(harness.loader.isPluginLoaded(actor), isTrue);
              expect(
                await harness.loader.pluginSettings(actor),
                containsPair('mode', 'self'),
              );
              final fresh = await harness.localApi(actor, fixtureMarker);
              expect(fresh.status, 200);
            case 'removes':
              expect(harness.loader.getPluginManifest(actor), isNull);
          }
          await expectStaleCallRefused();
        },
      );
    }

    test('PluginManager.dispose ends every grant', () async {
      await harness.localApi(actor, fixtureEcho);
      await harness.localApi(observer, fixtureEcho);
      final grants = harness.routed.map((seen) => seen.grant!).toList();
      expect(grants.map((grant) => grant.isActive), [true, true]);

      await harness.loader.dispose();

      expect(grants.map((grant) => grant.isActive), [false, false]);
    });
  });

  group('standalone manager', () {
    Future<String> runLocalApi(PluginManager manager, String id) async {
      final result = Completer<String>();
      final sub = manager.emitStream.listen((event) {
        if (!result.isCompleted) result.complete(event['payload'] as String);
      });
      addTearDown(sub.cancel);
      await manager.loadPlugin(
        id: id,
        manifest: testManifest(
          id,
          permissions: const {
            PluginPermissions.emit,
            PluginPermissions.manageExtensions,
          },
        ),
        settings: {},
        jsCode:
            '''
          function createPlugin(host) {
            return {
              id: ${jsonEncode(id)},
              onLoad() {
                host.localApi("$fixtureEcho", { method: "POST" }).then(
                  (response) => host.emit("result", "ok:" + response.status),
                  (error) => host.emit("result", "err:" + error.message)
                );
              }
            };
          }
        ''',
      );
      return result.future.timeout(const Duration(seconds: 10));
    }

    test('rejects with a clear error before attachLocalApi', () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);

      final result = await runLocalApi(manager, uniqueId('unattached'));

      expect(result, 'err:Bad state: The local API is not available');
    });

    test('rejects when the handler outlasts localApiTimeout', () async {
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        localApiTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(manager.dispose);
      final never = Completer<shelf.Response>();
      manager.attachLocalApi((_) => never.future);

      final result = await runLocalApi(manager, uniqueId('slow'));

      expect(result, 'err:Local API request timed out');
      expect(manager.activePendingOpCount, 0);
    });

    test('rejects a response larger than maxFetchResponseBytes', () async {
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        maxFetchResponseBytes: 64,
      );
      addTearDown(manager.dispose);
      manager.attachLocalApi((_) => shelf.Response.ok('x' * 1024));

      final result = await runLocalApi(manager, uniqueId('big'));

      expect(result, startsWith('err:'));
      expect(result, contains('exceeds 64 bytes'));
      expect(manager.activePendingOpCount, 0);
    });

    test('a reused request id does not displace the pending request', () async {
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      final release = Completer<shelf.Response>();
      var dispatched = 0;
      manager.attachLocalApi((_) {
        dispatched += 1;
        return release.future;
      });
      final id = uniqueId('reuse');
      await manager.loadPlugin(
        id: id,
        manifest: testManifest(
          id,
          permissions: const {PluginPermissions.manageExtensions},
        ),
        settings: {},
        jsCode:
            '''
          function createPlugin(host) {
            return {
              id: ${jsonEncode(id)},
              onLoad() {
                for (let i = 0; i < 2; i++) {
                  sendMessage("host", JSON.stringify({
                    bridgeToken: pluginBridgeToken,
                    generation: pluginGeneration,
                    type: "localApi",
                    requestId: "reused",
                    path: "$fixtureEcho",
                    method: "POST"
                  }));
                }
              }
            };
          }
        ''',
      );
      await pumpEventQueue();

      expect(dispatched, 1);
      expect(manager.activePendingOpsByType, {'localApi': 1});

      release.complete(shelf.Response.ok('done'));
      await pumpEventQueue();
      expect(manager.activePendingOpCount, 0);
    });

    test('bridge messages are logged without the bridge token', () async {
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final logged = <String>[];
      final sub = Logger.root.onRecord.listen(
        (record) => logged.add(record.message),
      );
      addTearDown(() {
        Logger.root.level = previousLevel;
        return sub.cancel();
      });
      final manager = PluginManager(kvStore: FakeKeyValueStoreService());
      addTearDown(manager.dispose);
      manager.attachLocalApi((_) => shelf.Response.ok('ok'));
      final id = uniqueId('logged');
      await manager.loadPlugin(
        id: id,
        manifest: testManifest(
          id,
          permissions: const {
            PluginPermissions.emit,
            PluginPermissions.manageExtensions,
          },
        ),
        settings: {},
        jsCode:
            '''
          function createPlugin(host) {
            return {
              id: ${jsonEncode(id)},
              onLoad() {
                globalThis.__loggedPluginToken = pluginBridgeToken;
                host.emit("marker", {});
                host.localApi("$fixtureEcho");
              }
            };
          }
        ''',
      );
      await pumpEventQueue();
      final bridgeToken = manager.js
          .evaluate('globalThis.__loggedPluginToken')
          .stringResult;

      expect(bridgeToken, hasLength(greaterThan(20)));
      expect(logged.where((line) => line.contains('marker')), isNotEmpty);
      expect(logged.where((line) => line.contains(bridgeToken)), isEmpty);
    });

    test('resolves a response within maxFetchResponseBytes', () async {
      final manager = PluginManager(
        kvStore: FakeKeyValueStoreService(),
        maxFetchResponseBytes: 64,
      );
      addTearDown(manager.dispose);
      manager.attachLocalApi((_) => shelf.Response.ok('x' * 64));

      final result = await runLocalApi(manager, uniqueId('fits'));

      expect(result, 'ok:200');
    });
  });
}
