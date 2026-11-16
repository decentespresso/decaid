import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/services/account/proxy_token_service.dart';
import 'package:reaprime/src/services/webserver/data_export/settings_export_section.dart';
import 'package:reaprime/src/services/webserver/data_export_handler.dart';
import 'package:reaprime/src/services/webserver/data_sync_handler.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/gateway_mode.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_service.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import '../helpers/mock_settings_service.dart';

const _currentSkinId = 'streamline.js';
const _otherSkinId = 'other.skin';
const _securityKey = 'requireExtensionManagementAuthorization';
const _skinWarning =
    'defaultSkinId was not imported: changing the default skin requires '
    'extensions:manage authorization.';

const _automaticUpdateWarning =
    'automaticUpdateCheck was not turned on: automatic plugin and skin '
    'updates require extensions:manage authorization.';

class _PausableSettingsService extends MockSettingsService {
  Completer<void>? _gatewayWriteStarted;
  Completer<void>? _gatewayWriteMayFinish;

  Future<void> pauseNextGatewayWrite() {
    _gatewayWriteMayFinish = Completer<void>();
    return (_gatewayWriteStarted = Completer<void>()).future;
  }

  void resumeGatewayWrite() => _gatewayWriteMayFinish?.complete();

  @override
  Future<void> updateGatewayMode(GatewayMode mode) async {
    _gatewayWriteStarted?.complete();
    _gatewayWriteStarted = null;
    await _gatewayWriteMayFinish?.future;
    await super.updateGatewayMode(mode);
  }
}

class _RecordingWebUIStorage extends Fake implements WebUIStorage {
  final List<String> calls = [];

  @override
  Future<void> setDefaultSkin(String skinId) async {
    calls.add('setDefaultSkin $skinId');
  }
}

class _RecordingWebUIService extends Fake implements WebUIService {
  final List<String> calls = [];

  @override
  Future<void> serveFolderAtPath(String path, {int port = 3000}) async {
    calls.add('serveFolderAtPath $path');
  }

  @override
  String serverPath() => '';
}

final class _Reply {
  _Reply(this.status, this.body);

  final int status;
  final String body;

  dynamic get json => jsonDecode(body);

  @override
  String toString() => '$status $body';
}

List<int> _settingsArchive(Map<String, dynamic> settings) {
  final archive = Archive()
    ..addFile(
      ArchiveFile.string('settings.json', jsonEncode({'settings': settings})),
    );
  return ZipEncoder().encode(archive);
}

Map<String, dynamic> _archiveSettings(List<int> bytes) {
  final decoded = ZipDecoder().decodeBytes(bytes);
  final entry = decoded.files.firstWhere(
    (file) => file.name == 'settings.json',
  );
  final data = jsonDecode(
    utf8.decode(entry.content as List<int>),
  ) as Map<String, dynamic>;
  return data['settings'] as Map<String, dynamic>;
}

void main() {
  late Directory tempDir;
  late _PausableSettingsService settingsService;
  late SettingsController settings;
  late _RecordingWebUIStorage storage;
  late _RecordingWebUIService webUi;
  late ProxyTokenService tokens;
  late List<int> pullArchive;
  late List<Uint8List> pushedBodies;
  late HttpServer server;
  late HttpClient client;

  late String managerToken;
  late String accountToken;

  Future<bool> storedPolicy() =>
      settingsService.requireExtensionManagementAuthorization();

  Future<void> usePolicy(bool protect) async {
    await settingsService.setRequireExtensionManagementAuthorization(protect);
    expect(
      await settings.currentRequireExtensionManagementAuthorization(),
      protect,
    );
  }

  String? credentialHeader(String kind) => switch (kind) {
    'unknown' => 'Bearer ${ProxyTokenService.generateToken()}',
    'wrong-scope' => 'Bearer $accountToken',
    'manager' => 'Bearer $managerToken',
    _ => null,
  };

  Future<_Reply> send(
    String method,
    String path, {
    String? authorization,
    List<int>? bytes,
    Object? json,
  }) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}$path'),
    );
    if (authorization != null) {
      request.headers.set(HttpHeaders.authorizationHeader, authorization);
    }
    if (bytes != null) {
      request.headers.contentType = ContentType.binary;
      request.add(bytes);
    } else if (json != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(json));
    }
    final response = await request.close();
    return _Reply(
      response.statusCode,
      await utf8.decoder.bind(response).join(),
    );
  }

  Future<(int, List<int>)> sendBytes(String method, String path) async {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:${server.port}$path'),
    );
    final response = await request.close();
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }
    return (response.statusCode, bytes);
  }

  Map<String, Object?> settingsState() => {
    'gatewayMode': settings.gatewayMode,
    'weightFlowMultiplier': settings.weightFlowMultiplier,
    'defaultSkinId': settings.defaultSkinId,
    'storageCalls': List.of(storage.calls),
    'webUiCalls': List.of(webUi.calls),
  };

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('extension_mgmt_settings');
    settingsService = _PausableSettingsService();
    settings = SettingsController(settingsService);
    await settings.loadSettings();
    await usePolicy(true);
    storage = _RecordingWebUIStorage();
    webUi = _RecordingWebUIService();
    pullArchive = _settingsArchive({});
    pushedBodies = [];

    managerToken = ProxyTokenService.generateToken();
    accountToken = ProxyTokenService.generateToken();
    tokens = ProxyTokenService()
      ..registerToken(
        managerToken,
        const ProxyCaller(
          id: 'api:fleet',
          scopes: {ProxyTokenService.scopeExtensionsManage},
        ),
      )
      ..registerToken(
        accountToken,
        const ProxyCaller(
          id: 'api:account',
          scopes: {
            ProxyTokenService.scopeAccountProxy,
            ProxyTokenService.scopeAccountProxyWrite,
          },
        ),
      );

    final exportHandler = DataExportHandler(
      sections: [SettingsExportSection(controller: settings)],
      tempDirParent: tempDir,
    );
    final app = createApiRouter();
    SettingsHandler(
      controller: settings,
      service: webUi,
      webUIStorage: storage,
    ).addRoutes(app);
    exportHandler.addRoutes(app);
    DataSyncHandler(
      exportHandler: exportHandler,
      httpClient: MockClient((request) async {
        if (request.method == 'GET') {
          return http.Response.bytes(pullArchive, 200);
        }
        pushedBodies.add(request.bodyBytes);
        return http.Response('{"settings":{"imported":1,"skipped":0}}', 200);
      }),
    ).addRoutes(app);

    server = await shelf_io.serve(
      buildWebServerHandler(
        app.call,
        proxyTokenService: tokens,
        requireExtensionManagementAuthorization: () =>
            settings.currentRequireExtensionManagementAuthorization(),
      ),
      InternetAddress.loopbackIPv4,
      0,
    );
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
    settings.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('POST /api/v1/settings with skin selection', () {
    for (final (key, value) in [
      ('defaultSkinId', _otherSkinId),
      ('webUiPath', '/tmp/skin'),
    ]) {
      test('$key without a bearer is 401 and applies nothing', () async {
        final before = settingsState();
        final reply = await send(
          'POST',
          '/api/v1/settings',
          json: {
            'gatewayMode': 'full',
            'weightFlowMultiplier': 2.5,
            key: value,
          },
        );
        expect(reply.status, 401);
        expect(reply.json, {'error': 'Missing or malformed bearer token'});
        expect(settingsState(), before);
      });

      test('$key with an unscoped token is 403 and applies nothing', () async {
        final before = settingsState();
        final reply = await send(
          'POST',
          '/api/v1/settings',
          authorization: 'Bearer $accountToken',
          json: {'gatewayMode': 'full', key: value},
        );
        expect(reply.status, 403);
        expect(reply.json, {
          'error': 'Token is not scoped for extensions:manage',
        });
        expect(settingsState(), before);
      });

      test('$key with an unknown token is 401 and applies nothing', () async {
        final before = settingsState();
        final reply = await send(
          'POST',
          '/api/v1/settings',
          authorization: 'Bearer ${ProxyTokenService.generateToken()}',
          json: {'gatewayMode': 'full', key: value},
        );
        expect(reply.status, 401);
        expect(reply.json, {'error': 'Invalid token'});
        expect(settingsState(), before);
      });
    }

    test('an extensions:manage token applies every key', () async {
      final reply = await send(
        'POST',
        '/api/v1/settings',
        authorization: 'Bearer $managerToken',
        json: {
          'gatewayMode': 'full',
          'defaultSkinId': _otherSkinId,
          'webUiPath': '/tmp/skin',
        },
      );
      expect(reply.status, 200, reason: '$reply');
      expect(settings.gatewayMode, GatewayMode.full);
      expect(storage.calls, ['setDefaultSkin $_otherSkinId']);
      expect(webUi.calls, ['serveFolderAtPath /tmp/skin']);
    });

    test('an authorized body is still validated by the handler', () async {
      final reply = await send(
        'POST',
        '/api/v1/settings',
        authorization: 'Bearer $managerToken',
        json: {'defaultSkinId': 42},
      );
      expect(reply.status, 400);
      expect(reply.json, {'message': 'defaultSkinId must be a string'});
      expect(storage.calls, isEmpty);
    });

    test('a body without skin keys works without a bearer', () async {
      final reply = await send(
        'POST',
        '/api/v1/settings',
        json: {'gatewayMode': 'full', 'weightFlowMultiplier': 2.5},
      );
      expect(reply.status, 200, reason: '$reply');
      expect(settings.gatewayMode, GatewayMode.full);
      expect(settings.weightFlowMultiplier, 2.5);
      expect(storage.calls, isEmpty);
      expect(webUi.calls, isEmpty);
    });
  });

  group('POST /api/v1/settings with automaticUpdateCheck', () {
    setUp(() => settings.setAutomaticUpdateCheck(false));

    test('turning it on without a bearer is 401 and applies nothing', () async {
      final reply = await send(
        'POST',
        '/api/v1/settings',
        json: {'gatewayMode': 'full', 'automaticUpdateCheck': true},
      );
      expect(reply.status, 401);
      expect(reply.json, {'error': 'Missing or malformed bearer token'});
      expect(settings.automaticUpdateCheck, isFalse);
      expect(settings.gatewayMode, isNot(GatewayMode.full));
    });

    test('turning it on with an unscoped token is 403', () async {
      final reply = await send(
        'POST',
        '/api/v1/settings',
        authorization: 'Bearer $accountToken',
        json: {'automaticUpdateCheck': true},
      );
      expect(reply.status, 403);
      expect(settings.automaticUpdateCheck, isFalse);
    });

    test('an extensions:manage token turns it on', () async {
      final reply = await send(
        'POST',
        '/api/v1/settings',
        authorization: 'Bearer $managerToken',
        json: {'automaticUpdateCheck': true},
      );
      expect(reply.status, 200, reason: '$reply');
      expect(settings.automaticUpdateCheck, isTrue);
    });

    test('turning it off needs no bearer', () async {
      await settings.setAutomaticUpdateCheck(true);
      final reply = await send(
        'POST',
        '/api/v1/settings',
        json: {'automaticUpdateCheck': false},
      );
      expect(reply.status, 200, reason: '$reply');
      expect(settings.automaticUpdateCheck, isFalse);
    });

    test('values that stop being current during the request are not '
        'written back', () async {
      await settings.setAutomaticUpdateCheck(true);
      final gatewayWriteStarted = settingsService.pauseNextGatewayWrite();
      final pending = send(
        'POST',
        '/api/v1/settings',
        json: {
          'gatewayMode': 'full',
          'automaticUpdateCheck': true,
          'defaultSkinId': _currentSkinId,
        },
      );
      await gatewayWriteStarted;
      await settings.setAutomaticUpdateCheck(false);
      await settings.setDefaultSkinId(_otherSkinId);
      settingsService.resumeGatewayWrite();

      final reply = await pending;
      expect(reply.status, 200, reason: '$reply');
      expect(settings.gatewayMode, GatewayMode.full);
      expect(settings.automaticUpdateCheck, isFalse);
      expect(settings.defaultSkinId, _otherSkinId);
      expect(storage.calls, isEmpty);
    });

    test('sending the values already in effect needs no bearer', () async {
      await settings.setAutomaticUpdateCheck(true);
      final reply = await send(
        'POST',
        '/api/v1/settings',
        json: {
          'automaticUpdateCheck': true,
          'defaultSkinId': _currentSkinId,
          'gatewayMode': 'full',
        },
      );
      expect(reply.status, 200, reason: '$reply');
      expect(settings.automaticUpdateCheck, isTrue);
      expect(settings.gatewayMode, GatewayMode.full);
      expect(settings.defaultSkinId, _currentSkinId);
    });
  });

  group('POST /api/v1/data/import with automaticUpdateCheck', () {
    List<int> archive(bool value) => _settingsArchive({
      'gatewayMode': 'full',
      'automaticUpdateCheck': value,
    });

    test('without a bearer leaves automatic updates off and warns', () async {
      await settings.setAutomaticUpdateCheck(false);
      final reply = await send(
        'POST',
        '/api/v1/data/import',
        bytes: archive(true),
      );
      expect(reply.status, 200, reason: '$reply');
      final section = reply.json['settings'] as Map<String, dynamic>;
      expect(section['imported'], 1);
      expect(section['skipped'], 1);
      expect(section['warnings'], [_automaticUpdateWarning]);
      expect(settings.automaticUpdateCheck, isFalse);
      expect(settings.gatewayMode, GatewayMode.full);
    });

    test(
      'with an extensions:manage token turns automatic updates on',
      () async {
        await settings.setAutomaticUpdateCheck(false);
        final reply = await send(
          'POST',
          '/api/v1/data/import',
          authorization: 'Bearer $managerToken',
          bytes: archive(true),
        );
        expect(reply.status, 200, reason: '$reply');
        expect(reply.json['settings'], isNot(contains('warnings')));
        expect(settings.automaticUpdateCheck, isTrue);
      },
    );

    test('without a bearer can still turn automatic updates off', () async {
      await settings.setAutomaticUpdateCheck(true);
      final reply = await send(
        'POST',
        '/api/v1/data/import',
        bytes: archive(false),
      );
      expect(reply.status, 200, reason: '$reply');
      expect(reply.json['settings'], isNot(contains('warnings')));
      expect(settings.automaticUpdateCheck, isFalse);
    });

    test('an archive matching the current value produces no warning', () async {
      await settings.setAutomaticUpdateCheck(true);
      final reply = await send(
        'POST',
        '/api/v1/data/import',
        bytes: archive(true),
      );
      expect(reply.status, 200, reason: '$reply');
      expect(reply.json['settings'], isNot(contains('warnings')));
      expect(settings.automaticUpdateCheck, isTrue);
    });
  });

  group('POST /api/v1/data/import', () {
    List<int> archive(String skinId) => _settingsArchive({
      'gatewayMode': 'full',
      'weightFlowMultiplier': 2.5,
      'defaultSkinId': skinId,
    });

    test('without a bearer imports the rest, keeps the default skin and '
        'warns', () async {
      final reply = await send(
        'POST',
        '/api/v1/data/import',
        bytes: archive(_otherSkinId),
      );
      expect(reply.status, 200, reason: '$reply');
      final section = reply.json['settings'] as Map<String, dynamic>;
      expect(section['imported'], 2);
      expect(section['skipped'], 1);
      expect(section['warnings'], [_skinWarning]);
      expect(settings.gatewayMode, GatewayMode.full);
      expect(settings.weightFlowMultiplier, 2.5);
      expect(settings.defaultSkinId, _currentSkinId);
    });

    test('with an unscoped token behaves as unauthenticated', () async {
      final reply = await send(
        'POST',
        '/api/v1/data/import',
        authorization: 'Bearer $accountToken',
        bytes: archive(_otherSkinId),
      );
      expect(reply.status, 200, reason: '$reply');
      expect(reply.json['settings']['warnings'], [_skinWarning]);
      expect(settings.defaultSkinId, _currentSkinId);
    });

    test('with an extensions:manage token applies the default skin', () async {
      final reply = await send(
        'POST',
        '/api/v1/data/import',
        authorization: 'Bearer $managerToken',
        bytes: archive(_otherSkinId),
      );
      expect(reply.status, 200, reason: '$reply');
      final section = reply.json['settings'] as Map<String, dynamic>;
      expect(section['imported'], 3);
      expect(section, isNot(contains('warnings')));
      expect(settings.defaultSkinId, _otherSkinId);
    });

    test('an unchanged default skin produces no warning', () async {
      final reply = await send(
        'POST',
        '/api/v1/data/import',
        bytes: archive(_currentSkinId),
      );
      expect(reply.status, 200, reason: '$reply');
      final section = reply.json['settings'] as Map<String, dynamic>;
      expect(section['imported'], 2);
      expect(section['skipped'], 0);
      expect(section, isNot(contains('warnings')));
      expect(settings.defaultSkinId, _currentSkinId);
    });
  });

  group('POST /api/v1/data/sync pulling settings', () {
    Map<String, dynamic> syncBody(String mode) => {
      'target': 'http://192.168.1.50:8080',
      'mode': mode,
    };

    setUp(() {
      pullArchive = _settingsArchive({
        'gatewayMode': 'full',
        'defaultSkinId': _otherSkinId,
      });
    });

    for (final mode in ['pull', 'two_way']) {
      test('$mode without a bearer keeps the default skin and warns', () async {
        final reply = await send(
          'POST',
          '/api/v1/data/sync',
          json: syncBody(mode),
        );
        expect(reply.status, 200, reason: '$reply');
        final section = reply.json['pull']['settings'] as Map<String, dynamic>;
        expect(section['warnings'], [_skinWarning]);
        expect(settings.gatewayMode, GatewayMode.full);
        expect(settings.defaultSkinId, _currentSkinId);
      });

      test('$mode with an extensions:manage token applies it', () async {
        final reply = await send(
          'POST',
          '/api/v1/data/sync',
          authorization: 'Bearer $managerToken',
          json: syncBody(mode),
        );
        expect(reply.status, 200, reason: '$reply');
        final section = reply.json['pull']['settings'] as Map<String, dynamic>;
        expect(section, isNot(contains('warnings')));
        expect(settings.defaultSkinId, _otherSkinId);
      });
    }

    test('an unchanged default skin produces no warning', () async {
      pullArchive = _settingsArchive({'defaultSkinId': _currentSkinId});
      final reply = await send(
        'POST',
        '/api/v1/data/sync',
        json: syncBody('pull'),
      );
      expect(reply.status, 200, reason: '$reply');
      expect(reply.json['pull']['settings'], isNot(contains('warnings')));
      expect(settings.defaultSkinId, _currentSkinId);
    });
  });

  const credentials = <(String, String)>[
    ('without a bearer', 'none'),
    ('with an unknown token', 'unknown'),
    ('with a wrong-scope token', 'wrong-scope'),
    ('with an extensions:manage token', 'manager'),
  ];

  Map<String, Object?> refusalBody(String kind) => switch (kind) {
    'unknown' => {'error': 'Invalid token'},
    'wrong-scope' => {'error': 'Token is not scoped for extensions:manage'},
    _ => {'error': 'Missing or malformed bearer token'},
  };

  group('POST /api/v1/settings body-dependent keys in both modes', () {
    for (final protect in [false, true]) {
      group(protect ? 'protected mode' : 'compatibility mode', () {
        setUp(() => usePolicy(protect));

        for (final (label, kind) in credentials) {
          final admitted = !protect || kind == 'manager';
          final refusal = kind == 'wrong-scope' ? 403 : 401;
          final outcome = admitted
              ? 'is applied'
              : 'is $refusal and applies nothing';

          test('webUiPath $label $outcome', () async {
            final before = settingsState();
            final reply = await send(
              'POST',
              '/api/v1/settings',
              authorization: credentialHeader(kind),
              json: {
                'gatewayMode': 'full',
                'weightFlowMultiplier': 2.5,
                'webUiPath': '/tmp/matrix',
              },
            );
            if (!admitted) {
              expect(reply.status, refusal, reason: '$reply');
              expect(reply.json, refusalBody(kind), reason: '$reply');
              expect(settingsState(), before);
              return;
            }
            expect(reply.status, 200, reason: '$reply');
            expect(settings.gatewayMode, GatewayMode.full);
            expect(settings.weightFlowMultiplier, 2.5);
            expect(webUi.calls, ['serveFolderAtPath /tmp/matrix']);
          });

          test('a changed defaultSkinId $label $outcome', () async {
            final before = settingsState();
            final reply = await send(
              'POST',
              '/api/v1/settings',
              authorization: credentialHeader(kind),
              json: {'gatewayMode': 'full', 'defaultSkinId': _otherSkinId},
            );
            if (!admitted) {
              expect(reply.status, refusal, reason: '$reply');
              expect(reply.json, refusalBody(kind), reason: '$reply');
              expect(settingsState(), before);
              return;
            }
            expect(reply.status, 200, reason: '$reply');
            expect(settings.gatewayMode, GatewayMode.full);
            expect(storage.calls, ['setDefaultSkin $_otherSkinId']);
          });

          test('enabling automaticUpdateCheck $label $outcome', () async {
            await settings.setAutomaticUpdateCheck(false);
            final reply = await send(
              'POST',
              '/api/v1/settings',
              authorization: credentialHeader(kind),
              json: {'gatewayMode': 'full', 'automaticUpdateCheck': true},
            );
            if (!admitted) {
              expect(reply.status, refusal, reason: '$reply');
              expect(reply.json, refusalBody(kind), reason: '$reply');
              expect(settings.automaticUpdateCheck, isFalse);
              expect(settings.gatewayMode, isNot(GatewayMode.full));
              return;
            }
            expect(reply.status, 200, reason: '$reply');
            expect(settings.automaticUpdateCheck, isTrue);
            expect(settings.gatewayMode, GatewayMode.full);
          });
        }

        test('a default skin already in effect stays legacy', () async {
          final reply = await send(
            'POST',
            '/api/v1/settings',
            json: {'gatewayMode': 'full', 'defaultSkinId': _currentSkinId},
          );
          expect(reply.status, 200, reason: '$reply');
          expect(settings.gatewayMode, GatewayMode.full);
          expect(settings.defaultSkinId, _currentSkinId);
          expect(
            storage.calls,
            protect ? isEmpty : ['setDefaultSkin $_currentSkinId'],
          );
        });

        test('turning automatic updates off stays legacy', () async {
          await settings.setAutomaticUpdateCheck(true);
          final reply = await send(
            'POST',
            '/api/v1/settings',
            json: {'gatewayMode': 'full', 'automaticUpdateCheck': false},
          );
          expect(reply.status, 200, reason: '$reply');
          expect(settings.automaticUpdateCheck, isFalse);
          expect(settings.gatewayMode, GatewayMode.full);
        });

        test('automatic updates already on stay legacy', () async {
          await settings.setAutomaticUpdateCheck(true);
          final reply = await send(
            'POST',
            '/api/v1/settings',
            json: {'gatewayMode': 'full', 'automaticUpdateCheck': true},
          );
          expect(reply.status, 200, reason: '$reply');
          expect(settings.automaticUpdateCheck, isTrue);
          expect(settings.gatewayMode, GatewayMode.full);
        });

        test('ordinary settings need no bearer', () async {
          final reply = await send(
            'POST',
            '/api/v1/settings',
            json: {
              'gatewayMode': 'full',
              'weightFlowMultiplier': 2.5,
              'nightModeEnabled': true,
            },
          );
          expect(reply.status, 200, reason: '$reply');
          expect(settings.gatewayMode, GatewayMode.full);
          expect(settings.weightFlowMultiplier, 2.5);
          expect(settings.nightModeEnabled, isTrue);
        });

        test(
          'a malformed extension key is validated with a manager token',
          () async {
            final reply = await send(
              'POST',
              '/api/v1/settings',
              authorization: 'Bearer $managerToken',
              json: {'defaultSkinId': 42},
            );
            expect(reply.status, 400, reason: '$reply');
            expect(reply.json, {'message': 'defaultSkinId must be a string'});
            expect(storage.calls, isEmpty);
          },
        );

        test('a malformed extension key without a bearer ends at '
            '${protect ? 401 : 400}', () async {
          final reply = await send(
            'POST',
            '/api/v1/settings',
            json: {'defaultSkinId': 42},
          );
          expect(reply.status, protect ? 401 : 400, reason: '$reply');
          expect(storage.calls, isEmpty);
        });
      });
    }
  });

  group('POST /api/v1/data/import body-dependent keys in both modes', () {
    for (final protect in [false, true]) {
      group(protect ? 'protected mode' : 'compatibility mode', () {
        setUp(() => usePolicy(protect));
        setUp(() => settings.setAutomaticUpdateCheck(false));

        List<int> archive() => _settingsArchive({
          'gatewayMode': 'full',
          'weightFlowMultiplier': 2.5,
          'defaultSkinId': _otherSkinId,
          'automaticUpdateCheck': true,
        });

        test('an unauthenticated import applies both keys in compatibility '
            'mode and skips both in protected mode', () async {
          final reply = await send(
            'POST',
            '/api/v1/data/import',
            bytes: archive(),
          );
          expect(reply.status, 200, reason: '$reply');
          final section = reply.json['settings'] as Map<String, dynamic>;
          expect(settings.gatewayMode, GatewayMode.full);
          expect(settings.weightFlowMultiplier, 2.5);
          if (protect) {
            expect(section['imported'], 2);
            expect(section['skipped'], 2);
            expect(section['warnings'], [
              _skinWarning,
              _automaticUpdateWarning,
            ]);
            expect(settings.defaultSkinId, _currentSkinId);
            expect(settings.automaticUpdateCheck, isFalse);
          } else {
            expect(section['imported'], 4);
            expect(section['skipped'], 0);
            expect(section, isNot(contains('warnings')));
            expect(settings.defaultSkinId, _otherSkinId);
            expect(settings.automaticUpdateCheck, isTrue);
          }
        });

        test('an extensions:manage token applies both keys', () async {
          final reply = await send(
            'POST',
            '/api/v1/data/import',
            authorization: 'Bearer $managerToken',
            bytes: archive(),
          );
          expect(reply.status, 200, reason: '$reply');
          final section = reply.json['settings'] as Map<String, dynamic>;
          expect(section['imported'], 4);
          expect(section, isNot(contains('warnings')));
          expect(settings.defaultSkinId, _otherSkinId);
          expect(settings.automaticUpdateCheck, isTrue);
          expect(settings.gatewayMode, GatewayMode.full);
          expect(settings.weightFlowMultiplier, 2.5);
        });
      });
    }
  });

  group('POST /api/v1/data/sync body-dependent keys in both modes', () {
    for (final protect in [false, true]) {
      group(protect ? 'protected mode' : 'compatibility mode', () {
        setUp(() => usePolicy(protect));
        setUp(() => settings.setAutomaticUpdateCheck(false));
        setUp(() {
          pullArchive = _settingsArchive({
            'gatewayMode': 'full',
            'weightFlowMultiplier': 2.5,
            'defaultSkinId': _otherSkinId,
            'automaticUpdateCheck': true,
          });
        });

        for (final mode in ['pull', 'two_way']) {
          test('$mode applies both keys in compatibility mode and skips both '
              'in protected mode', () async {
            final reply = await send(
              'POST',
              '/api/v1/data/sync',
              json: {'target': 'http://192.168.1.50:8080', 'mode': mode},
            );
            expect(reply.status, 200, reason: '$reply');
            final section =
                reply.json['pull']['settings'] as Map<String, dynamic>;
            expect(settings.gatewayMode, GatewayMode.full);
            expect(settings.weightFlowMultiplier, 2.5);
            if (protect) {
              expect(section['warnings'], [
                _skinWarning,
                _automaticUpdateWarning,
              ]);
              expect(settings.defaultSkinId, _currentSkinId);
              expect(settings.automaticUpdateCheck, isFalse);
            } else {
              expect(section, isNot(contains('warnings')));
              expect(settings.defaultSkinId, _otherSkinId);
              expect(settings.automaticUpdateCheck, isTrue);
            }
          });

          test(
            '$mode with an extensions:manage token applies both keys',
            () async {
              final reply = await send(
                'POST',
                '/api/v1/data/sync',
                authorization: 'Bearer $managerToken',
                json: {'target': 'http://192.168.1.50:8080', 'mode': mode},
              );
              expect(reply.status, 200, reason: '$reply');
              final section =
                  reply.json['pull']['settings'] as Map<String, dynamic>;
              expect(section, isNot(contains('warnings')));
              expect(settings.defaultSkinId, _otherSkinId);
              expect(settings.automaticUpdateCheck, isTrue);
              expect(settings.gatewayMode, GatewayMode.full);
              expect(settings.weightFlowMultiplier, 2.5);
            },
          );
        }
      });
    }
  });

  group('the security setting is native-only in both modes', () {
    for (final protect in [false, true]) {
      group(protect ? 'protected mode' : 'compatibility mode', () {
        setUp(() => usePolicy(protect));

        int policyWrites() =>
            settingsService.requireExtensionManagementAuthorizationWrites;

        Future<void> expectPolicyUnchanged(
          int writesBefore,
          bool expected,
        ) async {
          expect(await storedPolicy(), expected);
          expect(policyWrites(), writesBefore);
        }

        for (final attempted in [true, false]) {
          for (final (label, kind) in [
            ('without a bearer', 'none'),
            ('with an extensions:manage token', 'manager'),
          ]) {
            test(
              'POST /api/v1/settings cannot set it to $attempted $label',
              () async {
                final writesBefore = policyWrites();
                final reply = await send(
                  'POST',
                  '/api/v1/settings',
                  authorization: credentialHeader(kind),
                  json: {
                    'gatewayMode': 'full',
                    'weightFlowMultiplier': 2.5,
                    _securityKey: attempted,
                  },
                );
                expect(reply.status, 200, reason: '$reply');
                expect(settings.gatewayMode, GatewayMode.full);
                expect(settings.weightFlowMultiplier, 2.5);
                await expectPolicyUnchanged(writesBefore, protect);
              },
            );
          }

          for (final (label, kind) in [
            ('without a bearer', 'none'),
            ('with an extensions:manage token', 'manager'),
          ]) {
            test(
              'a crafted settings import cannot set it to $attempted $label',
              () async {
                final writesBefore = policyWrites();
                final reply = await send(
                  'POST',
                  '/api/v1/data/import',
                  authorization: credentialHeader(kind),
                  bytes: _settingsArchive({
                    'gatewayMode': 'full',
                    'weightFlowMultiplier': 2.5,
                    _securityKey: attempted,
                  }),
                );
                expect(reply.status, 200, reason: '$reply');
                expect(settings.gatewayMode, GatewayMode.full);
                expect(settings.weightFlowMultiplier, 2.5);
                await expectPolicyUnchanged(writesBefore, protect);
              },
            );
          }

          for (final mode in ['pull', 'two_way']) {
            test('$mode sync cannot set it to $attempted', () async {
              final writesBefore = policyWrites();
              pullArchive = _settingsArchive({
                'gatewayMode': 'full',
                'weightFlowMultiplier': 2.5,
                _securityKey: attempted,
              });
              final reply = await send(
                'POST',
                '/api/v1/data/sync',
                json: {'target': 'http://192.168.1.50:8080', 'mode': mode},
              );
              expect(reply.status, 200, reason: '$reply');
              expect(settings.gatewayMode, GatewayMode.full);
              expect(settings.weightFlowMultiplier, 2.5);
              await expectPolicyUnchanged(writesBefore, protect);
            });
          }
        }

        for (final attempted in [true, false]) {
          test(
            'pull with an extensions:manage token cannot set it to $attempted',
            () async {
              final writesBefore = policyWrites();
              pullArchive = _settingsArchive({
                'gatewayMode': 'full',
                _securityKey: attempted,
              });
              final reply = await send(
                'POST',
                '/api/v1/data/sync',
                authorization: 'Bearer $managerToken',
                json: {'target': 'http://192.168.1.50:8080', 'mode': 'pull'},
              );
              expect(reply.status, 200, reason: '$reply');
              expect(settings.gatewayMode, GatewayMode.full);
              await expectPolicyUnchanged(writesBefore, protect);
            },
          );
        }

        test('GET /api/v1/settings does not expose it', () async {
          final reply = await send('GET', '/api/v1/settings');
          expect(reply.status, 200, reason: '$reply');
          final body = reply.json as Map<String, dynamic>;
          expect(body.keys, isNot(contains(_securityKey)));
          expect(body, contains('defaultSkinId'));
          expect(body, contains('automaticUpdateCheck'));
        });

        test('the export archive never contains it', () async {
          final (status, bytes) = await sendBytes('GET', '/api/v1/data/export');
          expect(status, 200);
          final exported = _archiveSettings(bytes);
          expect(exported.keys, isNot(contains(_securityKey)));
          expect(jsonEncode(exported), isNot(contains(_securityKey)));
          expect(exported, contains('defaultSkinId'));
          expect(exported, contains('automaticUpdateCheck'));
        });

        test('the push archive never contains it', () async {
          final reply = await send(
            'POST',
            '/api/v1/data/sync',
            json: {'target': 'http://192.168.1.50:8080', 'mode': 'push'},
          );
          expect(reply.status, 200, reason: '$reply');
          final pushed = _archiveSettings(pushedBodies.single);
          expect(pushed.keys, isNot(contains(_securityKey)));
          expect(jsonEncode(pushed), isNot(contains(_securityKey)));
          expect(pushed, contains('defaultSkinId'));
        });
      });
    }
  });

  group('the native toggle decides the next request', () {
    test('flipping it applies immediately without a restart', () async {
      await usePolicy(false);
      final open = await send(
        'POST',
        '/api/v1/settings',
        json: {'webUiPath': '/tmp/open'},
      );
      expect(open.status, 200, reason: '$open');
      expect(webUi.calls, ['serveFolderAtPath /tmp/open']);

      await settings.setRequireExtensionManagementAuthorization(true);

      final refused = await send(
        'POST',
        '/api/v1/settings',
        json: {'webUiPath': '/tmp/refused'},
      );
      expect(refused.status, 401, reason: '$refused');
      expect(webUi.calls, ['serveFolderAtPath /tmp/open']);

      await settings.setRequireExtensionManagementAuthorization(false);

      final reopened = await send(
        'POST',
        '/api/v1/settings',
        json: {'webUiPath': '/tmp/reopened'},
      );
      expect(reopened.status, 200, reason: '$reopened');
      expect(webUi.calls, [
        'serveFolderAtPath /tmp/open',
        'serveFolderAtPath /tmp/reopened',
      ]);
    });

    test(
      'a request keeps the decision it started with across a flip',
      () async {
        await usePolicy(false);
        final gatewayWriteStarted = settingsService.pauseNextGatewayWrite();
        final pending = send(
          'POST',
          '/api/v1/settings',
          json: {'gatewayMode': 'full', 'webUiPath': '/tmp/snapshot'},
        );
        await gatewayWriteStarted;

        await settings.setRequireExtensionManagementAuthorization(true);
        expect(await storedPolicy(), isTrue);
        settingsService.resumeGatewayWrite();

        final admitted = await pending;
        expect(admitted.status, 200, reason: '$admitted');
        expect(webUi.calls, ['serveFolderAtPath /tmp/snapshot']);

        final refused = await send(
          'POST',
          '/api/v1/settings',
          json: {'webUiPath': '/tmp/after'},
        );
        expect(refused.status, 401, reason: '$refused');
        expect(webUi.calls, ['serveFolderAtPath /tmp/snapshot']);
      },
    );
  });
}
