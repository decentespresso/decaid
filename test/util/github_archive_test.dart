import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/services/github_rate_limit.dart';
import 'package:reaprime/src/services/github_request.dart';
import 'package:reaprime/src/util/github_archive.dart';
import 'package:reaprime/src/util/remote_error.dart';
import 'package:reaprime/src/util/user_facing_exception.dart';

void main() {
  Future<T> withResponse<T>(Object? payload, Future<T> Function() action) =>
      http.runWithClient(
        action,
        () => MockClient((_) async => http.Response(jsonEncode(payload), 200)),
      );

  final release = {
    'tag_name': 'v1.2.3',
    'assets': [
      {
        'name': 'plugin.zip',
        'browser_download_url': 'https://example.test/plugin.zip',
      },
    ],
  };

  test('valid release responses preserve tags and assets', () async {
    final latest = await withResponse(
      release,
      () => fetchLatestGitHubRelease('acme/plugin'),
    );
    final tagged = await withResponse(
      release,
      () => fetchGitHubReleaseByTag('acme/plugin', 'v1.2.3'),
    );
    final prerelease = await withResponse([
      release,
    ], () => fetchLatestGitHubRelease('acme/plugin', includePrerelease: true));
    for (final parsed in [latest, tagged, prerelease]) {
      expect(parsed.tag, 'v1.2.3');
      expect(parsed.assets.single.name, 'plugin.zip');
      expect(
        parsed.assets.single.downloadUrl,
        'https://example.test/plugin.zip',
      );
    }
  });

  for (final (name, payload) in <(String, Object?)>[
    ('null', null),
    ('list', []),
    ('missing tag', {'assets': []}),
    ('wrong tag type', {'tag_name': 123, 'assets': []}),
    ('empty tag', {'tag_name': '', 'assets': []}),
    ('missing assets', {'tag_name': 'v1.2.3'}),
    ('wrong assets type', {'tag_name': 'v1.2.3', 'assets': {}}),
    (
      'non-object asset',
      {
        'tag_name': 'v1.2.3',
        'assets': [null],
      },
    ),
    (
      'missing asset URL',
      {
        'tag_name': 'v1.2.3',
        'assets': [
          {'name': 'plugin.zip'},
        ],
      },
    ),
    (
      'wrong asset name type',
      {
        'tag_name': 'v1.2.3',
        'assets': [
          {'name': 123, 'browser_download_url': 'https://example.test'},
        ],
      },
    ),
    (
      'empty asset URL',
      {
        'tag_name': 'v1.2.3',
        'assets': [
          {'name': 'plugin.zip', 'browser_download_url': ''},
        ],
      },
    ),
  ]) {
    test('release validation rejects $name', () async {
      await expectLater(
        withResponse(payload, () => fetchLatestGitHubRelease('acme/plugin')),
        throwsA(isA<UserFacingFormatException>()),
      );
    });
  }

  test('tagged release validates the response shape', () async {
    await expectLater(
      withResponse([], () => fetchGitHubReleaseByTag('acme/plugin', 'v1.2.3')),
      throwsA(isA<UserFacingFormatException>()),
    );
  });

  for (final payload in [
    null,
    {},
    [null],
    [],
  ]) {
    test('prerelease validation rejects ${jsonEncode(payload)}', () async {
      await expectLater(
        withResponse(
          payload,
          () =>
              fetchLatestGitHubRelease('acme/plugin', includePrerelease: true),
        ),
        throwsA(isA<UserFacingFormatException>()),
      );
    });
  }

  for (final payload in [
    null,
    [],
    {},
    {'sha': 123},
    {'sha': ''},
  ]) {
    test('commit validation rejects ${jsonEncode(payload)}', () async {
      await expectLater(
        withResponse(
          payload,
          () => fetchGitHubBranchCommit('acme/plugin', 'main'),
        ),
        throwsA(isA<UserFacingFormatException>()),
      );
    });
  }

  test('valid commit preserves the resolved SHA', () async {
    expect(
      await withResponse({
        'sha': 'abc123',
      }, () => fetchGitHubBranchCommit('acme/plugin', 'main')),
      'abc123',
    );
  });

  group('release cache regressions', () {
    late GitHubReleaseCache cache;
    setUp(() => cache = GitHubReleaseCache());
    test('changed release replaces ETag and metadata', () async {
      var requests = 0;
      await http.runWithClient(
        () async {
          final first = await fetchLatestGitHubRelease(
            'acme/changed',
            cache: cache,
          );
          final changed = await fetchLatestGitHubRelease(
            'acme/changed',
            cache: cache,
          );
          final unchanged = await fetchLatestGitHubRelease(
            'acme/changed',
            cache: cache,
          );
          expect(first.tag, 'v1.2.3');
          expect(changed.tag, 'v2.0.0');
          expect(changed.assets.single.name, 'new.zip');
          expect(
            changed.assets.single.downloadUrl,
            'https://example.test/new.zip',
          );
          expect(unchanged, same(changed));
        },
        () => MockClient((request) async {
          requests++;
          expect(
            request.headers['if-none-match'],
            [null, '"v1"', '"v2"'][requests - 1],
          );
          if (requests == 3) return http.Response('', 304);
          return http.Response(
            jsonEncode(
              requests == 1
                  ? release
                  : {
                      'tag_name': 'v2.0.0',
                      'assets': [
                        {
                          'name': 'new.zip',
                          'browser_download_url':
                              'https://example.test/new.zip',
                        },
                      ],
                    },
            ),
            200,
            headers: {'etag': requests == 1 ? '"v1"' : '"v2"'},
          );
        }),
      );
      expect(requests, 3);
    });

    test('cache keys separate repositories and release endpoints', () async {
      final urls = [
        'https://api.github.com/repos/acme/one/releases/latest',
        'https://api.github.com/repos/acme/two/releases/latest',
        'https://api.github.com/repos/acme/one/releases',
        'https://api.github.com/repos/acme/one/releases/tags/v1',
      ];
      final calls = <String, int>{};
      await http.runWithClient(
        () async {
          for (var pass = 0; pass < 2; pass++) {
            final releases = [
              await fetchLatestGitHubRelease('acme/one', cache: cache),
              await fetchLatestGitHubRelease('acme/two', cache: cache),
              await fetchLatestGitHubRelease(
                'acme/one',
                includePrerelease: true,
                cache: cache,
              ),
              await fetchGitHubReleaseByTag('acme/one', 'v1', cache: cache),
            ];
            expect(releases.map((r) => r.tag), ['v0', 'v1', 'v2', 'v3']);
          }
        },
        () => MockClient((request) async {
          final url = request.url.toString();
          final index = urls.indexOf(url);
          final count = calls.update(url, (n) => n + 1, ifAbsent: () => 1);
          if (count == 2) {
            expect(request.headers['if-none-match'], '"$index"');
            return http.Response('', 304);
          }
          expect(request.headers['if-none-match'], isNull);
          final payload = {...release, 'tag_name': 'v$index'};
          return http.Response(
            jsonEncode(index == 2 ? [payload] : payload),
            200,
            headers: {'etag': '"$index"'},
          );
        }),
      );
      expect(calls.values, everyElement(2));
    });

    test('cache is bounded and evicts the oldest insertion', () async {
      final seen = <String?>[];
      await http.runWithClient(
        () async {
          for (var i = 0; i <= GitHubReleaseCache.capacity; i++) {
            await fetchLatestGitHubRelease('acme/p$i', cache: cache);
          }
          await fetchLatestGitHubRelease('acme/p1', cache: cache);
          await fetchLatestGitHubRelease('acme/p0', cache: cache);
        },
        () => MockClient((request) async {
          seen.add(request.headers['if-none-match']);
          return http.Response(
            jsonEncode(release),
            200,
            headers: {'etag': '"v1"'},
          );
        }),
      );
      expect(seen.take(GitHubReleaseCache.capacity + 1), everyElement(isNull));
      expect(seen[GitHubReleaseCache.capacity + 1], '"v1"');
      expect(seen.last, isNull);
    });

    test('cache instances do not share validators or metadata', () async {
      var requests = 0;
      await http.runWithClient(
        () async {
          await fetchLatestGitHubRelease('acme/isolated', cache: cache);
          final second = await fetchLatestGitHubRelease(
            'acme/isolated',
            cache: GitHubReleaseCache(),
          );
          expect(second.tag, 'v2');
        },
        () => MockClient((request) async {
          requests++;
          expect(request.headers['if-none-match'], isNull);
          return http.Response(
            jsonEncode({...release, 'tag_name': 'v$requests'}),
            200,
            headers: {'etag': '"$requests"'},
          );
        }),
      );
      expect(requests, 2);
    });

    test('200 without ETag invalidates the previous validator', () async {
      var requests = 0;
      await http.runWithClient(
        () async {
          await fetchLatestGitHubRelease('acme/no-etag', cache: cache);
          await fetchLatestGitHubRelease('acme/no-etag', cache: cache);
          final latest = await fetchLatestGitHubRelease(
            'acme/no-etag',
            cache: cache,
          );
          expect(latest.tag, 'v2.0.0');
        },
        () => MockClient((request) async {
          requests++;
          if (requests == 1) {
            return http.Response(
              jsonEncode(release),
              200,
              headers: {'etag': '"old"'},
            );
          }
          if (requests == 2) {
            expect(request.headers['if-none-match'], '"old"');
          } else {
            expect(request.headers['if-none-match'], isNull);
          }
          return http.Response(
            jsonEncode({...release, 'tag_name': 'v2.0.0'}),
            200,
          );
        }),
      );
      expect(requests, 3);
    });

    test('unexpected 304 retries once without conditional headers', () async {
      var requests = 0;
      final result = await http.runWithClient(
        () => fetchLatestGitHubRelease('acme/unexpected-304', cache: cache),
        () => MockClient((request) async {
          requests++;
          expect(request.headers['if-none-match'], isNull);
          return requests == 1
              ? http.Response('', 304)
              : http.Response(jsonEncode(release), 200);
        }),
      );
      expect(result.tag, 'v1.2.3');
      expect(requests, 2);
    });

    test('repeated unexpected 304 raises a controlled remote error', () async {
      var requests = 0;
      await expectLater(
        http.runWithClient(
          () =>
              fetchGitHubReleaseByTag('acme/repeated-304', 'v1', cache: cache),
          () => MockClient((request) async {
            requests++;
            expect(request.headers['if-none-match'], isNull);
            return http.Response('', 304);
          }),
        ),
        throwsA(
          isA<RemoteServiceException>().having(
            (e) => e.statusCode,
            'statusCode',
            304,
          ),
        ),
      );
      expect(requests, 2);
    });
  });

  group('shared rate-limit cooldown', () {
    final resetAt = DateTime.utc(2030, 1, 1, 12);
    final beforeReset = DateTime.utc(2030, 1, 1, 11);
    String resetValue() => '${resetAt.millisecondsSinceEpoch ~/ 1000}';

    Future<T> withClient<T>(MockClient client, Future<T> Function() action) =>
        http.runWithClient(action, () => client);

    test('a rate-limited fetch enters the shared cooldown', () async {
      var requests = 0;
      final limit = GithubRateLimit(now: () => beforeReset);
      final client = MockClient((_) async {
        requests++;
        return http.Response(
          'API rate limit exceeded',
          403,
          headers: {
            'x-ratelimit-remaining': '0',
            'x-ratelimit-reset': resetValue(),
          },
        );
      });

      await expectLater(
        withClient(
          client,
          () => fetchLatestGitHubRelease(
            'acme/rate-limited-plugin',
            rateLimit: limit,
          ),
        ),
        throwsA(
          isA<GithubRequestException>()
              .having((e) => e.rateLimited, 'rateLimited', isTrue)
              .having((e) => e.resetAt, 'resetAt', resetAt)
              .having((e) => e.statusCode, 'statusCode', 403)
              .having(
                (e) => e.userMessage,
                'userMessage',
                allOf(contains('temporarily unavailable'), contains('12:00')),
              ),
        ),
      );
      expect(requests, 1);
      expect(limit.isLimited, isTrue);
      expect(limit.resetAt, resetAt);
    });

    test('a limited holder short-circuits without an HTTP request', () async {
      final limit = GithubRateLimit(now: () => beforeReset);
      limit.recordIfLimited(
        http.Response(
          '',
          429,
          headers: {
            'x-ratelimit-remaining': '0',
            'x-ratelimit-reset': resetValue(),
          },
        ),
      );
      expect(limit.isLimited, isTrue);

      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response(jsonEncode(release), 200);
      });

      await expectLater(
        withClient(
          client,
          () => fetchLatestGitHubRelease(
            'acme/short-circuited-plugin',
            rateLimit: limit,
          ),
        ),
        throwsA(
          isA<RemoteServiceException>().having(
            (e) => e.userMessage,
            'userMessage',
            contains('temporarily unavailable'),
          ),
        ),
      );
      expect(requests, 0);
    });

    test('a non-rate-limit error keeps the existing behaviour', () async {
      final limit = GithubRateLimit(now: () => beforeReset);
      final client = MockClient(
        (_) async => http.Response('no such repo', 404),
      );

      await expectLater(
        withClient(
          client,
          () =>
              fetchLatestGitHubRelease('acme/missing-plugin', rateLimit: limit),
        ),
        throwsA(
          isA<RemoteServiceException>()
              .having((e) => e.statusCode, 'statusCode', 404)
              .having(
                (e) => e.userMessage,
                'userMessage',
                'The repository, release, or download was not found. '
                    'Check the address and try again.',
              ),
        ),
      );
      expect(limit.isLimited, isFalse);
    });

    test('a 304 answers from cache instead of failing', () async {
      final cache = GitHubReleaseCache();
      var requests = 0;
      String? seenIfNoneMatch;
      final client = MockClient((request) async {
        requests++;
        if (requests == 1) {
          return http.Response(
            jsonEncode(release),
            200,
            headers: {'etag': '"v1"'},
          );
        }
        seenIfNoneMatch = request.headers['if-none-match'];
        return http.Response('', 304);
      });

      final first = await withClient(
        client,
        () => fetchLatestGitHubRelease('acme/etag-plugin', cache: cache),
      );
      final second = await withClient(
        client,
        () => fetchLatestGitHubRelease('acme/etag-plugin', cache: cache),
      );
      expect(requests, 2);
      expect(seenIfNoneMatch, '"v1"');
      expect(second.tag, first.tag);
      expect(second.tag, 'v1.2.3');
      expect(second.assets.single.name, 'plugin.zip');
    });
  });
}
