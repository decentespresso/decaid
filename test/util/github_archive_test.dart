import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/util/github_archive.dart';
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
}
