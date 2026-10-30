import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/services/github_rate_limit.dart';
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
          isA<RemoteServiceException>()
              .having((e) => e.statusCode, 'statusCode', 429)
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
        () => fetchLatestGitHubRelease('acme/etag-plugin'),
      );
      final second = await withClient(
        client,
        () => fetchLatestGitHubRelease('acme/etag-plugin'),
      );
      expect(requests, 2);
      expect(seenIfNoneMatch, '"v1"');
      expect(second.tag, first.tag);
      expect(second.tag, 'v1.2.3');
      expect(second.assets.single.name, 'plugin.zip');
    });
  });
}
