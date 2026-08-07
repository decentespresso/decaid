import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/services/android_updater.dart';

void main() {
  group('AndroidUpdater.checkForUpdate', () {
    Map<String, Object> release(
      String version, {
      required bool prerelease,
      bool includeApk = true,
    }) => {
      'tag_name': version.startsWith('nightly-') ? version : 'v$version',
      'prerelease': prerelease,
      'body': '',
      'assets': [
        if (includeApk)
          {
            'name': 'decent-android-$version.apk',
            'browser_download_url': 'https://example.com/$version.apk',
          },
      ],
    };

    AndroidUpdater updaterFor(List<Map<String, Object>> releases) {
      return AndroidUpdater(
        owner: 'tadelv',
        repo: 'reaprime',
        httpClient: MockClient(
          (_) async => http.Response(jsonEncode(releases), 200),
        ),
      );
    }

    test('stable ignores prereleases', () async {
      final updater = updaterFor([
        release('0.7.15-beta.1', prerelease: true),
        release('0.7.14', prerelease: false),
      ]);

      final update = await updater.checkForUpdate(
        '0.7.13',
        channel: UpdateChannel.stable,
      );

      expect(update?.version, '0.7.14');
    });

    test('beta includes prereleases and final releases', () async {
      final updater = updaterFor([
        release('0.7.15-beta.2', prerelease: true),
        release('0.7.15', prerelease: false),
      ]);

      final update = await updater.checkForUpdate(
        '0.7.15-beta.1',
        channel: UpdateChannel.beta,
      );

      expect(update?.version, '0.7.15');
    });

    test('beta selects the highest semantic version', () async {
      final updater = updaterFor([
        release('0.7.15-beta.2', prerelease: true),
        release('0.7.16-beta.1', prerelease: true),
      ]);

      final update = await updater.checkForUpdate(
        '0.7.16-beta.0',
        channel: UpdateChannel.beta,
      );

      expect(update?.version, '0.7.16-beta.1');
    });

    test('skips a release without an APK', () async {
      final updater = updaterFor([
        release('0.8.0', prerelease: false, includeApk: false),
        release('0.7.15', prerelease: false),
      ]);

      final update = await updater.checkForUpdate('0.7.14');

      expect(update?.version, '0.7.15');
    });

    test('skips a release with a non-semver tag', () async {
      final updater = updaterFor([
        release('nightly-2026-07-30', prerelease: true),
        release('0.7.15-beta.1', prerelease: true),
      ]);

      final update = await updater.checkForUpdate(
        '0.7.14',
        channel: UpdateChannel.beta,
      );

      expect(update?.version, '0.7.15-beta.1');
    });

    test('all invalid releases do not affect a later valid check', () async {
      var callCount = 0;
      final updater = AndroidUpdater(
        owner: 'tadelv',
        repo: 'reaprime',
        httpClient: MockClient((_) async {
          final releases = callCount++ == 0
              ? [
                  release('0.8.0', prerelease: false, includeApk: false),
                  release('nightly-2026-07-30', prerelease: true),
                ]
              : [release('0.7.15', prerelease: false)];
          return http.Response(jsonEncode(releases), 200);
        }),
      );

      expect(await updater.checkForUpdate('0.7.14'), isNull);
      expect((await updater.checkForUpdate('0.7.14'))?.version, '0.7.15');
    });
  });

  group('AndroidUpdater.downloadUpdate streamed progress', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('updater_test');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    UpdateInfo info() => UpdateInfo(
      version: '1.2.3',
      downloadUrl: 'https://example.com/app.apk',
      releaseNotes: '',
      isPrerelease: false,
      tagName: 'v1.2.3',
    );

    test(
      'reports monotonic progress ending at 1.0 and writes the file',
      () async {
        final chunks = <List<int>>[
          List.filled(40, 0),
          List.filled(40, 1),
          List.filled(20, 2),
        ];
        const total = 100;

        final client = MockClient.streaming((request, body) async {
          return http.StreamedResponse(
            Stream.fromIterable(chunks),
            200,
            contentLength: total,
          );
        });

        final updater = AndroidUpdater(
          owner: 'tadelv',
          repo: 'reaprime',
          httpClient: client,
        );

        final progress = <double>[];
        final path = await updater.downloadUpdate(
          info(),
          cacheDir: tmp,
          onProgress: progress.add,
        );

        expect(progress, isNotEmpty);
        expect(progress.last, closeTo(1.0, 1e-9));
        for (var i = 1; i < progress.length; i++) {
          expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
        }

        final file = File(path);
        expect(file.existsSync(), isTrue);
        expect(file.lengthSync(), total);
      },
    );

    test('throws on non-200 response', () async {
      final client = MockClient.streaming((request, body) async {
        return http.StreamedResponse(const Stream.empty(), 404);
      });
      final updater = AndroidUpdater(
        owner: 'tadelv',
        repo: 'reaprime',
        httpClient: client,
      );

      expect(
        () => updater.downloadUpdate(info(), cacheDir: tmp),
        throwsA(isA<Exception>()),
      );
    });

    test('omits progress when Content-Length is unknown', () async {
      final client = MockClient.streaming((request, body) async {
        return http.StreamedResponse(
          Stream.fromIterable([List.filled(10, 0)]),
          200,
        );
      });
      final updater = AndroidUpdater(
        owner: 'tadelv',
        repo: 'reaprime',
        httpClient: client,
      );

      final progress = <double>[];
      await updater.downloadUpdate(
        info(),
        cacheDir: tmp,
        onProgress: progress.add,
      );

      expect(progress, isEmpty);
    });
  });
}
