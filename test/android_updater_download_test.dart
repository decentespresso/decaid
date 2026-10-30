import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/services/android_updater.dart';
import 'package:reaprime/src/util/remote_error.dart';

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

    test('returns null for an empty release list', () async {
      final updater = updaterFor([]);

      expect(await updater.checkForUpdate('0.7.14'), isNull);
    });

    test('returns null when no release is newer', () async {
      final updater = updaterFor([release('0.7.14', prerelease: false)]);

      expect(await updater.checkForUpdate('0.7.14'), isNull);
    });

    test(
      'sends GitHub API headers and keeps successful release parsing',
      () async {
        late http.Request capturedRequest;
        final updater = AndroidUpdater(
          owner: 'tadelv',
          repo: 'reaprime',
          httpClient: MockClient((request) async {
            capturedRequest = request;
            return http.Response(
              jsonEncode([release('0.7.15', prerelease: false)]),
              200,
            );
          }),
        );

        final update = await updater.checkForUpdate('0.7.14');

        expect(
          capturedRequest.headers['accept'],
          'application/vnd.github.v3+json',
        );
        expect(capturedRequest.headers['user-agent'], 'Decaid');
        expect(update?.version, '0.7.15');
        expect(update?.downloadUrl, 'https://example.com/0.7.15.apk');
      },
    );

    test(
      'explains a rate-limited 403 with bounded reset diagnostics',
      () async {
        final updater = AndroidUpdater(
          owner: 'tadelv',
          repo: 'reaprime',
          httpClient: MockClient(
            (_) async => http.Response(
              List.filled(5000, 'x').join(),
              403,
              headers: {
                'x-ratelimit-remaining': '0',
                'x-ratelimit-reset': '2000000000',
              },
            ),
          ),
        );

        await expectLater(
          updater.checkForUpdate('0.7.14'),
          throwsA(
            isA<UpdateCheckException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('rate limit'),
                contains('2033-05-18'),
                predicate<String>((message) => message.length < 500),
              ),
            ),
          ),
        );
      },
    );

    test(
      'explains a rate-limited 429 with bounded reset diagnostics',
      () async {
        final updater = AndroidUpdater(
          owner: 'tadelv',
          repo: 'reaprime',
          httpClient: MockClient(
            (_) async => http.Response(
              'API rate limit exceeded ${List.filled(5000, 'x').join()}',
              429,
              headers: {
                'x-ratelimit-remaining': '0',
                'x-ratelimit-reset': '2000000000',
              },
            ),
          ),
        );

        await expectLater(
          updater.checkForUpdate('0.7.14'),
          throwsA(
            isA<UpdateCheckException>()
                .having(
                  (e) => e.message,
                  'message',
                  allOf(
                    contains('HTTP 429'),
                    contains('rate limit remaining: 0'),
                    contains('2033-05-18'),
                    predicate<String>((message) => message.length < 500),
                  ),
                )
                .having((e) => e.rateLimited, 'rateLimited', isTrue),
          ),
        );
      },
    );

    group('rate-limit cooldown', () {
      final resetAt = DateTime.utc(2030, 1, 1, 12);
      late DateTime clock;
      late int requests;
      late AndroidUpdater updater;

      setUp(() {
        clock = DateTime.utc(2030, 1, 1, 11);
        requests = 0;
        updater = AndroidUpdater(
          owner: 'tadelv',
          repo: 'reaprime',
          now: () => clock,
          httpClient: MockClient((_) async {
            requests++;
            if (requests == 1) {
              return http.Response(
                'API rate limit exceeded',
                403,
                headers: {
                  'x-ratelimit-remaining': '0',
                  'x-ratelimit-reset':
                      '${resetAt.millisecondsSinceEpoch ~/ 1000}',
                },
              );
            }
            return http.Response('[]', 200);
          }),
        );
      });

      test('skips the network until the reset time', () async {
        await expectLater(
          updater.checkForUpdate('0.7.14'),
          throwsA(
            isA<UpdateCheckException>()
                .having((e) => e.statusCode, 'statusCode', 403)
                .having(
                  (e) => e.userMessage,
                  'userMessage',
                  'The service is receiving too many requests. Try again later.',
                ),
          ),
        );
        expect(requests, 1);

        await expectLater(
          updater.checkForUpdate('0.7.14'),
          throwsA(
            isA<UpdateCheckException>()
                .having((e) => e.rateLimited, 'rateLimited', isTrue)
                .having((e) => e.resetAt, 'resetAt', resetAt)
                .having(
                  (e) => e.userMessage,
                  'userMessage',
                  'The service is receiving too many requests. Try again later.',
                ),
          ),
        );
        expect(requests, 1);
      });

      test('resumes requests once the reset time has passed', () async {
        await expectLater(
          updater.checkForUpdate('0.7.14'),
          throwsA(isA<UpdateCheckException>()),
        );

        clock = resetAt;
        expect(await updater.checkForUpdate('0.7.14'), isNull);
        expect(requests, 2);
      });

      test('does not start a cooldown without a reset header', () async {
        var calls = 0;
        final noReset = AndroidUpdater(
          owner: 'tadelv',
          repo: 'reaprime',
          now: () => clock,
          httpClient: MockClient((_) async {
            calls++;
            return calls == 1
                ? http.Response(
                    'rate limited',
                    403,
                    headers: {'x-ratelimit-remaining': '0'},
                  )
                : http.Response('[]', 200);
          }),
        );

        await expectLater(
          noReset.checkForUpdate('0.7.14'),
          throwsA(isA<UpdateCheckException>()),
        );
        expect(await noReset.checkForUpdate('0.7.14'), isNull);
        expect(calls, 2);
      });
    });

    test(
      'keeps 403 response details when quota headers conflict with the body',
      () async {
        final body =
            'Request forbidden by administrative rules: User-Agent required\n'
            '${List.filled(5000, 'x').join()}';
        final updater = AndroidUpdater(
          owner: 'tadelv',
          repo: 'reaprime',
          httpClient: MockClient(
            (_) async => http.Response(
              body,
              403,
              headers: {'x-ratelimit-remaining': '0'},
            ),
          ),
        );

        await expectLater(
          updater.checkForUpdate('0.7.14'),
          throwsA(
            isA<UpdateCheckException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('User-Agent required'),
                contains('remaining: 0'),
                contains('reset time unavailable'),
                isNot(contains('rate limit exceeded')),
                isNot(contains('\n')),
                predicate<String>((message) => message.length < 500),
              ),
            ),
          ),
        );
      },
    );

    test(
      'distinguishes a non-rate-limit 403 with bounded response details',
      () async {
        final body =
            'Request forbidden by administrative rules: User-Agent required '
            '${List.filled(5000, 'x').join()}';
        final updater = AndroidUpdater(
          owner: 'tadelv',
          repo: 'reaprime',
          httpClient: MockClient((_) async => http.Response(body, 403)),
        );

        await expectLater(
          updater.checkForUpdate('0.7.14'),
          throwsA(
            isA<UpdateCheckException>().having(
              (e) => e.message,
              'message',
              allOf(
                contains('403'),
                contains('User-Agent required'),
                predicate<String>((message) => message.length < 500),
              ),
            ),
          ),
        );
      },
    );

    test('keeps other non-200 status errors unchanged', () async {
      final updater = AndroidUpdater(
        owner: 'tadelv',
        repo: 'reaprime',
        httpClient: MockClient(
          (_) async => http.Response('not found body', 404),
        ),
      );

      await expectLater(
        updater.checkForUpdate('0.7.14'),
        throwsA(
          isA<UpdateCheckException>().having(
            (e) => e.message,
            'message',
            'Failed to fetch releases: HTTP 404',
          ),
        ),
      );
    });

    test('propagates a transport failure', () async {
      final updater = AndroidUpdater(
        owner: 'tadelv',
        repo: 'reaprime',
        httpClient: MockClient(
          (_) async => throw const SocketException('network is unreachable'),
        ),
      );

      await expectLater(
        updater.checkForUpdate('0.7.14'),
        throwsA(isA<SocketException>()),
      );
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

        Stream<List<int>> responseChunks() async* {
          yield chunks.first;
          final partial = tmp.listSync().whereType<File>().single;
          expect(await partial.readAsBytes(), chunks.first);
          expect(File('${tmp.path}/update_1.2.3.apk').existsSync(), isFalse);
          yield chunks[1];
          expect(await partial.length(), 80);
          yield chunks[2];
        }

        final client = MockClient.streaming((request, body) async {
          return http.StreamedResponse(
            responseChunks(),
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
        expect(await file.readAsBytes(), chunks.expand((chunk) => chunk));
        expect(tmp.listSync().map((entry) => entry.uri), [file.uri]);
      },
    );

    test('isolates overlapping downloads of the same version', () async {
      final firstWritten = [Completer<void>(), Completer<void>()];
      final resume = [Completer<void>(), Completer<void>()];
      final payloads = [
        [1, 2, 3, 4, 5, 6],
        [7, 8, 9, 10, 11, 12],
      ];
      final finalPath = '${tmp.path}/update_1.2.3.apk';
      var requests = 0;

      Stream<List<int>> responseChunks(int index) async* {
        yield payloads[index].sublist(0, 3);
        await resume[index].future;
        yield payloads[index].sublist(3);
        if (index == 1) {
          expect(await File(finalPath).readAsBytes(), payloads.first);
        }
      }

      final updater = AndroidUpdater(
        owner: 'tadelv',
        repo: 'reaprime',
        httpClient: MockClient.streaming((request, body) async {
          return http.StreamedResponse(
            responseChunks(requests++),
            200,
            contentLength: 6,
          );
        }),
      );
      addTearDown(updater.dispose);
      final downloads = List.generate(2, (index) {
        return updater.downloadUpdate(
          info(),
          cacheDir: tmp,
          onProgress: (progress) {
            if (progress == 0.5) firstWritten[index].complete();
          },
        );
      });
      final allDownloads = Future.wait(downloads);

      try {
        await Future.wait(firstWritten.map((written) => written.future));
        final partials = tmp.listSync().whereType<File>().toList();
        expect(partials, hasLength(2));
        expect(partials.map((file) => file.path).toSet(), hasLength(2));
        expect(partials.every((file) => file.path.endsWith('.part')), isTrue);
        expect(
          partials.map((file) => file.readAsBytesSync()),
          unorderedEquals(payloads.map((payload) => payload.sublist(0, 3))),
        );
        expect(File(finalPath).existsSync(), isFalse);

        resume.first.complete();
        expect(await downloads.first, finalPath);
        expect(await File(finalPath).readAsBytes(), payloads.first);
        expect(
          tmp.listSync().where((entry) => entry.path.endsWith('.part')),
          hasLength(1),
        );

        resume.last.complete();
        expect(await downloads.last, finalPath);
        expect(await File(finalPath).readAsBytes(), payloads.last);
        expect(await allDownloads, [finalPath, finalPath]);
        expect(tmp.listSync().map((entry) => entry.uri), [File(finalPath).uri]);
      } finally {
        for (final release in resume) {
          if (!release.isCompleted) release.complete();
        }
        try {
          await allDownloads;
        } catch (_) {}
      }
    });

    test('streams a real HTTP response to the final APK', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final firstWritten = Completer<void>();
      final client = http.Client();
      addTearDown(() async {
        client.close();
        await server.close(force: true);
      });
      final serving = server.first.then((request) async {
        request.response.contentLength = 6;
        request.response.bufferOutput = false;
        request.response.add([1, 2, 3]);
        await request.response.flush();
        await firstWritten.future;
        request.response.add([4, 5, 6]);
        await request.response.close();
      });
      final updater = AndroidUpdater(
        owner: 'tadelv',
        repo: 'reaprime',
        httpClient: client,
      );
      final update = UpdateInfo(
        version: '1.2.3',
        downloadUrl: 'http://${server.address.address}:${server.port}/app.apk',
        releaseNotes: '',
        isPrerelease: false,
        tagName: 'v1.2.3',
      );
      final progress = <double>[];
      final path = await updater.downloadUpdate(
        update,
        cacheDir: tmp,
        onProgress: (value) {
          progress.add(value);
          if (value >= 0.5 && !firstWritten.isCompleted) {
            expect(tmp.listSync().whereType<File>().single.readAsBytesSync(), [
              1,
              2,
              3,
            ]);
            firstWritten.complete();
          }
        },
      );
      await serving;
      expect(path, '${tmp.path}/update_1.2.3.apk');
      expect(await File(path).readAsBytes(), [1, 2, 3, 4, 5, 6]);
      expect(progress.last, 1.0);
      for (var i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThanOrEqualTo(progress[i - 1]));
      }
      expect(tmp.listSync().map((entry) => entry.uri), [File(path).uri]);
    });

    test('removes partial data after a response stream error', () async {
      final failure = const HttpException('connection cancelled');
      Stream<List<int>> responseChunks() async* {
        yield [1, 2, 3];
        expect(await tmp.listSync().whereType<File>().single.readAsBytes(), [
          1,
          2,
          3,
        ]);
        throw failure;
      }

      final updater = AndroidUpdater(
        owner: 'tadelv',
        repo: 'reaprime',
        httpClient: MockClient.streaming((request, body) async {
          return http.StreamedResponse(responseChunks(), 200, contentLength: 6);
        }),
      );
      await expectLater(
        updater.downloadUpdate(info(), cacheDir: tmp),
        throwsA(same(failure)),
      );
      expect(tmp.listSync(), isEmpty);
    });

    test('cleans up when a progress callback aborts the download', () async {
      final failure = StateError('cancelled');
      final updater = AndroidUpdater(
        owner: 'tadelv',
        repo: 'reaprime',
        httpClient: MockClient.streaming((request, body) async {
          return http.StreamedResponse(
            Stream.fromIterable([
              [1, 2, 3],
              [4, 5, 6],
            ]),
            200,
            contentLength: 6,
          );
        }),
      );
      await expectLater(
        updater.downloadUpdate(
          info(),
          cacheDir: tmp,
          onProgress: (_) => throw failure,
        ),
        throwsA(same(failure)),
      );
      expect(tmp.listSync(), isEmpty);
    });

    for (final total in [2, 6]) {
      test('rejects a response whose length differs from $total', () async {
        final finalFile = File('${tmp.path}/update_1.2.3.apk');
        await finalFile.writeAsBytes([9]);
        final updater = AndroidUpdater(
          owner: 'tadelv',
          repo: 'reaprime',
          httpClient: MockClient.streaming((request, body) async {
            return http.StreamedResponse(
              Stream.fromIterable([
                [1],
                [2, 3],
              ]),
              200,
              contentLength: total,
            );
          }),
        );
        await expectLater(
          updater.downloadUpdate(info(), cacheDir: tmp),
          throwsA(isA<HttpException>()),
        );
        expect(await finalFile.readAsBytes(), [9]);
        expect(tmp.listSync().map((entry) => entry.uri), [finalFile.uri]);
      });
    }

    test('throws on non-200 response', () async {
      final client = MockClient.streaming((request, body) async {
        return http.StreamedResponse(const Stream.empty(), 404);
      });
      final updater = AndroidUpdater(
        owner: 'tadelv',
        repo: 'reaprime',
        httpClient: client,
      );

      await expectLater(
        updater.downloadUpdate(info(), cacheDir: tmp),
        throwsA(
          isA<RemoteServiceException>()
              .having((error) => error.statusCode, 'statusCode', 404)
              .having(
                (error) => error.userMessage,
                'userMessage',
                'The repository, release, or download was not found. Check the address and try again.',
              ),
        ),
      );
      expect(tmp.listSync(), isEmpty);
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
