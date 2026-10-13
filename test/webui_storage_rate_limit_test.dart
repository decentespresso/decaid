import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/services/github_rate_limit.dart';
import 'package:reaprime/src/settings/settings_controller.dart';
import 'package:reaprime/src/webui_support/webui_storage.dart';

import 'helpers/mock_settings_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final resetAt = DateTime.utc(2030, 1, 1, 12);
  late Directory tmpRoot;
  late DateTime clock;
  late GithubRateLimit limit;
  late WebUIStorage storage;
  late int requests;
  late MockClient client;

  setUp(() async {
    tmpRoot = Directory.systemTemp.createTempSync('webui_rate_limit_test');
    clock = DateTime.utc(2030, 1, 1, 11);
    requests = 0;
    client = MockClient((_) async {
      requests++;
      return http.Response(
        'API rate limit exceeded',
        403,
        headers: {
          'x-ratelimit-remaining': '0',
          'x-ratelimit-reset': '${resetAt.millisecondsSinceEpoch ~/ 1000}',
        },
      );
    });
    final settingsController = SettingsController(MockSettingsService());
    await settingsController.loadSettings();
    limit = GithubRateLimit(now: () => clock);
    storage = WebUIStorage(settingsController, rateLimit: limit);
    storage.debugInitWithWebUIDir(Directory('${tmpRoot.path}/web-ui'));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => tmpRoot.path,
        );
  });

  tearDown(() => tmpRoot.deleteSync(recursive: true));

  Future<void> install() => http.runWithClient(
    () => storage.installFromGitHubRelease('a/b'),
    () => client,
  );

  test('skin release fetches skip the network until the reset time', () async {
    await expectLater(install(), throwsException);
    expect(requests, 1);

    await expectLater(
      install(),
      throwsA(predicate((e) => e.toString().contains('rate limit active'))),
    );
    expect(requests, 1);

    clock = resetAt;
    await expectLater(install(), throwsException);
    expect(requests, 2);
  });

  test('a non-rate-limit 403 does not start a cooldown', () async {
    client = MockClient((_) async {
      requests++;
      return http.Response('forbidden', 403);
    });

    await expectLater(install(), throwsException);
    await expectLater(install(), throwsException);
    expect(requests, 2);
  });

  test('an app update check rate limit also pauses skin fetches', () async {
    final updater = AndroidUpdater(
      owner: 'o',
      repo: 'r',
      httpClient: client,
      rateLimit: limit,
    );
    await expectLater(updater.checkForUpdate('0.1.0'), throwsException);
    expect(requests, 1);

    await expectLater(install(), throwsException);
    expect(requests, 1);
  });

  test('one limit holder is shared across consumers', () {
    final limit = GithubRateLimit(now: () => clock);
    limit.recordIfLimited(
      http.Response(
        '',
        429,
        headers: {
          'x-ratelimit-remaining': '0',
          'x-ratelimit-reset': '${resetAt.millisecondsSinceEpoch ~/ 1000}',
        },
      ),
    );
    expect(limit.isLimited, isTrue);
    expect(limit.resetAt, resetAt);
    clock = resetAt;
    expect(limit.isLimited, isFalse);
  });
}
