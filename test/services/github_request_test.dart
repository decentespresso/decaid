import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/services/github_rate_limit.dart';
import 'package:reaprime/src/services/github_request.dart';
import 'package:reaprime/src/util/github_archive.dart';

void main() {
  final resetAt = DateTime.utc(2030, 1, 1, 12);
  late DateTime clock;
  late GithubRateLimit limit;

  setUp(() {
    clock = DateTime.utc(2030, 1, 1, 11);
    limit = GithubRateLimit(now: () => clock);
  });

  for (final status in [403, 429]) {
    test(
      '$status exhaustion blocks release and branch checks until expiry',
      () async {
        var requests = 0;
        await http.runWithClient(
          () async {
            final limited = isA<GithubRequestException>()
                .having((e) => e.rateLimited, 'rateLimited', isTrue)
                .having((e) => e.resetAt, 'resetAt', resetAt);
            await expectLater(
              fetchLatestGitHubRelease('acme/plugin', rateLimit: limit),
              throwsA(
                limited.having((e) => e.statusCode, 'statusCode', status),
              ),
            );
            expect(requests, 1);
            await expectLater(
              fetchGitHubBranchCommit('acme/branch', 'main', rateLimit: limit),
              throwsA(limited.having((e) => e.statusCode, 'statusCode', 429)),
            );
            await expectLater(
              fetchGitHubReleaseByTag('acme/other', 'v1', rateLimit: limit),
              throwsA(limited),
            );
            expect(requests, 1);
            clock = resetAt;
            expect(
              await fetchGitHubBranchCommit(
                'acme/branch',
                'main',
                rateLimit: limit,
              ),
              'abc',
            );
            expect(requests, 2);
            expect(limit.isLimited, isFalse);
          },
          () => MockClient((request) async {
            requests++;
            expect(request.headers['accept'], 'application/vnd.github.v3+json');
            expect(request.headers['user-agent'], 'Decaid');
            if (requests > 1) return http.Response('{"sha":"abc"}', 200);
            return http.Response(
              'quota exceeded',
              status,
              headers: {
                'x-ratelimit-remaining': '0',
                'x-ratelimit-reset':
                    '${resetAt.millisecondsSinceEpoch ~/ 1000}',
              },
            );
          }),
        );
      },
    );

    for (final reset in <String?>[null, 'bad', '-1', '8640000000001']) {
      test(
        '$status exhaustion with reset $reset stays typed with unknown reset',
        () async {
          await expectLater(
            githubGet(
              'https://api.github.com/repos/acme/plugin/releases',
              rateLimit: limit,
              client: MockClient(
                (_) async => http.Response(
                  'quota exceeded',
                  status,
                  headers: {
                    'x-ratelimit-remaining': '0',
                    'x-ratelimit-reset': ?reset,
                  },
                ),
              ),
            ),
            throwsA(
              isA<GithubRequestException>()
                  .having((e) => e.rateLimited, 'rateLimited', isTrue)
                  .having((e) => e.resetAt, 'resetAt', isNull)
                  .having((e) => e.statusCode, 'statusCode', status)
                  .having(
                    (e) => e.userMessage,
                    'userMessage',
                    contains('temporarily unavailable'),
                  ),
            ),
          );
          expect(limit.isLimited, isFalse);
        },
      );
    }
  }

  test(
    'ordinary 403 is not quota exhaustion and does not block requests',
    () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response(
          'forbidden',
          403,
          headers: {
            'x-ratelimit-remaining': '12',
            'x-ratelimit-reset': '${resetAt.millisecondsSinceEpoch ~/ 1000}',
          },
        );
      });
      for (var i = 0; i < 2; i++) {
        await expectLater(
          githubGet(
            'https://api.github.com/repos/acme/plugin/releases',
            rateLimit: limit,
            client: client,
          ),
          throwsA(
            isA<GithubRequestException>()
                .having((e) => e.rateLimited, 'rateLimited', isFalse)
                .having((e) => e.resetAt, 'resetAt', isNull)
                .having((e) => e.statusCode, 'statusCode', 403)
                .having(
                  (e) => e.userMessage,
                  'userMessage',
                  contains('refused access'),
                ),
          ),
        );
      }
      expect(limit.isLimited, isFalse);
      expect(requests, 2);
    },
  );

  test('branch exhaustion also blocks release requests', () async {
    var requests = 0;
    await http.runWithClient(
      () async {
        await expectLater(
          fetchGitHubBranchCommit('acme/plugin', 'main', rateLimit: limit),
          throwsA(
            isA<GithubRequestException>().having(
              (e) => e.rateLimited,
              'rateLimited',
              isTrue,
            ),
          ),
        );
        await expectLater(
          fetchLatestGitHubRelease('acme/plugin', rateLimit: limit),
          throwsA(
            isA<GithubRequestException>().having(
              (e) => e.resetAt,
              'resetAt',
              resetAt,
            ),
          ),
        );
        expect(requests, 1);
      },
      () => MockClient((_) async {
        requests++;
        return http.Response(
          '',
          429,
          headers: {
            'x-ratelimit-remaining': '0',
            'x-ratelimit-reset': '${resetAt.millisecondsSinceEpoch ~/ 1000}',
          },
        );
      }),
    );
  });
}
