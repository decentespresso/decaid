import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/update_check_service.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';
import 'package:shelf_plus/shelf_plus.dart';

import 'helpers/mock_settings_service.dart';

class _NoopUpdater extends AndroidUpdater {
  _NoopUpdater() : super(owner: 'tadelv', repo: 'reaprime');
  bool allowed = false;
  int downloads = 0;
  int installs = 0;
  final permissionRequests = <bool>[];

  @override
  Future<bool> canInstallPackages() async => allowed;

  @override
  Future<String> downloadUpdate(
    UpdateInfo info, {
    Function(double)? onProgress,
    Directory? cacheDir,
  }) async {
    downloads++;
    return '/update.apk';
  }

  @override
  Future<ApkInstallOutcome> installUpdate(
    String path, {
    bool requestPermission = true,
  }) async {
    installs++;
    permissionRequests.add(requestPermission);
    return ApkInstallOutcome.installerLaunched;
  }

  @override
  Future<UpdateInfo?> checkForUpdate(
    String v, {
    UpdateChannel channel = UpdateChannel.stable,
  }) async => null;
  @override
  void dispose() {}
}

class _RecordingUpdateService extends UpdateCheckService {
  _RecordingUpdateService({
    required bool isMacOS,
    super.externallyManaged = false,
  }) : super(
         settingsService: MockSettingsService(),
         webUIStorage: WebUIStorage(SettingsController(MockSettingsService())),
         updater: _NoopUpdater(),
         platformIsAndroid: true,
         platformIsMacOS: isMacOS,
       );

  int requestChecks = 0;

  @override
  Future<void> requestCheck() async {
    requestChecks++;
  }
}

void main() {
  late UpdateCheckService service;
  late UpdateHandler updateHandler;
  late Handler handler;

  UpdateCheckService buildService({required bool isAndroid}) {
    final settingsController = SettingsController(MockSettingsService());
    return UpdateCheckService(
      settingsService: MockSettingsService(),
      webUIStorage: WebUIStorage(settingsController),
      updater: _NoopUpdater(),
      platformIsAndroid: isAndroid,
      platformIsMacOS: false,
    );
  }

  setUp(() {
    service = buildService(isAndroid: true);
    updateHandler = UpdateHandler(service: service);
    final app = Router().plus;
    updateHandler.addRoutes(app);
    handler = app.call;
  });

  tearDown(() => service.dispose());

  Future<Response> sendGet(String path) async =>
      await handler(Request('GET', Uri.parse('http://localhost$path')));

  group('GET /api/v1/update', () {
    test('returns the current state snapshot', () async {
      final response = await sendGet('/api/v1/update');
      expect(response.statusCode, 200);
      expect(response.headers['content-type'], contains('application/json'));

      final body = jsonDecode(await response.readAsString());
      expect(body['phase'], 'idle');
      expect(body['currentVersion'], isA<String>());
      expect(body['releaseUrl'], contains('releases'));
      expect(body['installable'], false);
    });
  });

  group('handleCommand', () {
    test('a disconnected rejection callback is attempted only once', () async {
      final before = service.currentState;
      var replies = 0;

      updateHandler.handleCommand({'command': 'install'}, (_) {
        replies++;
        throw StateError('requesting socket closed');
      });
      await Future<void>.delayed(Duration.zero);

      expect(replies, 1);
      expect(service.currentState, same(before));
    });

    test('managed Android install reports unsupported, not local approval', () {
      final managed = _RecordingUpdateService(
        isMacOS: false,
        externallyManaged: true,
      );
      addTearDown(managed.dispose);
      final replies = <Map<String, dynamic>>[];

      UpdateHandler(service: managed)
          .handleCommand({'command': 'install'}, replies.add);

      expect(managed.canInstall, isFalse);
      expect(replies.single['error'], contains('not supported'));
      expect(replies.single.containsKey('reason'), isFalse);
    });

    test(
      'approved remote installation uses the noninteractive install path',
      () async {
        final updater = _NoopUpdater()..allowed = true;
        final settings = MockSettingsService();
        final local = UpdateCheckService(
          settingsService: settings,
          webUIStorage: WebUIStorage(SettingsController(settings)),
          updater: updater,
          platformIsAndroid: true,
          platformIsMacOS: false,
        );
        addTearDown(local.dispose);
        local.debugForceUpdate();
        final replies = <Map<String, dynamic>>[];

        UpdateHandler(service: local)
            .handleCommand({'command': 'install'}, replies.add);
        await Future<void>.delayed(Duration.zero);

        expect(replies, isEmpty);
        expect(updater.downloads, 1);
        expect(updater.installs, 1);
        expect(updater.permissionRequests, [false]);
      },
    );

    test(
      'missing local approval rejects only the requesting command',
      () async {
        final updater = _NoopUpdater();
        final settings = MockSettingsService();
        final local = UpdateCheckService(
          settingsService: settings,
          webUIStorage: WebUIStorage(SettingsController(settings)),
          updater: updater,
          platformIsAndroid: true,
          platformIsMacOS: false,
        );
        addTearDown(local.dispose);
        local.debugForceUpdate();
        final before = local.currentState.toJson();
        final broadcasts = <Map<String, dynamic>>[];
        final subscription = local.updateState.listen(
          (s) => broadcasts.add(s.toJson()),
        );
        addTearDown(subscription.cancel);
        await Future<void>.delayed(Duration.zero);
        final broadcastCount = broadcasts.length;
        final replies = <Map<String, dynamic>>[];

        UpdateHandler(service: local)
            .handleCommand({'command': 'install'}, replies.add);
        await Future<void>.delayed(Duration.zero);

        expect(replies.single['reason'], 'local_approval_required');
        expect(local.currentState.toJson(), before);
        expect(broadcasts.length, broadcastCount);
        expect(updater.downloads, 0);
        expect(updater.installs, 0);
      },
    );

    test('unknown command yields an error reply', () {
      final replies = <Map<String, dynamic>>[];
      updateHandler.handleCommand({'command': 'bogus'}, replies.add);
      expect(replies.single['error'], contains('Unknown command'));
    });

    test('missing command field yields an error reply', () {
      final replies = <Map<String, dynamic>>[];
      updateHandler.handleCommand({}, replies.add);
      expect(replies.single['error'], contains('Missing'));
    });

    test('install on non-Android replies with not-supported + url', () {
      final nonAndroid = buildService(isAndroid: false);
      final h = UpdateHandler(service: nonAndroid);
      final replies = <Map<String, dynamic>>[];

      h.handleCommand({'command': 'install'}, replies.add);

      expect(replies.single['error'], contains('not supported'));
      expect(replies.single['url'], contains('releases'));
      nonAndroid.dispose();
    });

    test('check without an updater replies not-supported + url', () {
      final unsupported = _RecordingUpdateService(isMacOS: true);
      final h = UpdateHandler(service: unsupported);
      final replies = <Map<String, dynamic>>[];

      h.handleCommand({'command': 'check'}, replies.add);

      expect(replies.single['error'], contains('not supported'));
      expect(replies.single['url'], contains('releases'));
      expect(unsupported.requestChecks, 0);
      unsupported.dispose();
    });

    test(
      'check on an externally managed build replies not-supported + url',
      () {
        final managed = _RecordingUpdateService(
          isMacOS: false,
          externallyManaged: true,
        );
        final h = UpdateHandler(service: managed);
        final replies = <Map<String, dynamic>>[];

        h.handleCommand({'command': 'check'}, replies.add);

        expect(replies.single['error'], contains('not supported'));
        expect(replies.single['url'], contains('releases'));
        expect(managed.requestChecks, 0);
        managed.dispose();
      },
    );

    test('check on a supported platform runs the check with no reply', () {
      final supported = _RecordingUpdateService(isMacOS: false);
      final h = UpdateHandler(service: supported);
      final replies = <Map<String, dynamic>>[];

      h.handleCommand({'command': 'check'}, replies.add);

      expect(replies, isEmpty);
      expect(supported.requestChecks, 1);
      supported.dispose();
    });
  });
}
