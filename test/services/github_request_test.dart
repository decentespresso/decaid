import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/services/github_credentials.dart';
import 'package:reaprime/src/services/github_rate_limit.dart';
import 'package:reaprime/src/services/github_request.dart';
import 'package:reaprime/src/util/github_archive.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';

class _TestStore implements CredentialStore {
  _TestStore(this.value);
  String? value;

  @override
  Future<String?> read({required String key}) async => value;

  @override
  Future<void> write({required String key, required String value}) async {
    this.value = value;
  }

  @override
  Future<void> delete({required String key}) async {
    value = null;
  }
}

Future<Object> captureError(Future<Object?> future) async {
  try {
    await future;
  } catch (error) {
    return error;
  }
  throw StateError('expected an error');
}

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

  test('user credentials are sent only to the exact API origin', () async {
    final credentials = GithubCredentialProvider(store: _TestStore('secret'));
    final seen = <http.BaseRequest>[];
    final client = MockClient((request) async {
      seen.add(request);
      return http.Response('{}', 200);
    });
    for (final url in [
      'https://api.github.com/repos/acme/project',
      'http://api.github.com/repos/acme/project',
      'https://github.com/acme/project',
      'https://api.github.com:444/repos/acme/project',
      'https://api.github.com:0/repos/acme/project',
      'https://user:password@api.github.com/repos/acme/project',
      'https://cdn.github.com/acme/project',
    ]) {
      await githubGet(
        url,
        rateLimit: GithubRateLimit(),
        client: client,
        credentials: credentials,
      );
    }
    expect(seen.first.headers['authorization'], 'Bearer secret');
    for (final request in seen.skip(1)) {
      expect(request.headers.containsKey('authorization'), isFalse);
    }
  });

  test('credential-bearing requests do not follow redirects', () async {
    final credentials = GithubCredentialProvider(store: _TestStore('secret'));
    final seen = <http.BaseRequest>[];
    await expectLater(
      githubGet(
        'https://api.github.com/repos/acme/project',
        rateLimit: GithubRateLimit(),
        client: MockClient((request) async {
          seen.add(request);
          return http.Response(
            '',
            302,
            headers: {'location': 'https://evil.test'},
          );
        }),
        credentials: credentials,
      ),
      throwsA(isA<GithubRequestException>()),
    );
    expect(seen, hasLength(1));
    expect(seen.single.followRedirects, isFalse);
  });

  test(
    'user credential failures are actionable and never include response body',
    () async {
      final credentials = GithubCredentialProvider(store: _TestStore('secret'));
      for (final status in [401, 403, 404]) {
        final error = await captureError(
          githubGet(
            'https://api.github.com/repos/acme/project',
            rateLimit: GithubRateLimit(),
            client: MockClient(
              (_) async => http.Response('secret response payload', status),
            ),
            credentials: credentials,
          ),
        );
        expect(error, isA<GithubRequestException>());
        expect(error.toString(), contains('Advanced Settings'));
        expect(error.toString(), contains('replace or remove'));
        expect(error.toString(), isNot(contains('secret')));
      }
    },
  );

  test(
    'cooldowns stay scoped across anonymous, replacement, and removal',
    () async {
      var now = DateTime.utc(2030, 1, 1);
      final anonymousReset = now.add(const Duration(hours: 1));
      final patReset = now.add(const Duration(hours: 2));
      final limit = GithubRateLimit(now: () => now);
      final store = _TestStore(null);
      final credentials = GithubCredentialProvider(store: store);
      var requests = 0;
      final anonymousLimited = MockClient((request) async {
        requests++;
        expect(request.headers.containsKey('authorization'), isFalse);
        return http.Response(
          '',
          403,
          headers: {
            'x-ratelimit-remaining': '0',
            'x-ratelimit-reset':
                '${anonymousReset.millisecondsSinceEpoch ~/ 1000}',
          },
        );
      });
      await expectLater(
        githubGet(
          'https://api.github.com/repos/acme/project',
          rateLimit: limit,
          client: anonymousLimited,
          credentials: credentials,
        ),
        throwsA(isA<GithubRequestException>()),
      );

      await credentials.save('pat1');
      await githubGet(
        'https://api.github.com/repos/acme/project',
        rateLimit: limit,
        credentials: credentials,
        client: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer pat1');
          return http.Response('{}', 200);
        }),
      );

      final patLimited = MockClient((request) async {
        requests++;
        expect(request.headers['authorization'], 'Bearer pat1');
        return http.Response(
          '',
          429,
          headers: {
            'x-ratelimit-remaining': '0',
            'x-ratelimit-reset': '${patReset.millisecondsSinceEpoch ~/ 1000}',
          },
        );
      });
      await expectLater(
        githubGet(
          'https://api.github.com/repos/acme/project',
          rateLimit: limit,
          client: patLimited,
          credentials: credentials,
        ),
        throwsA(isA<GithubRequestException>()),
      );
      await expectLater(
        githubGet(
          'https://api.github.com/repos/acme/project',
          rateLimit: limit,
          client: patLimited,
          credentials: credentials,
        ),
        throwsA(isA<GithubRequestException>()),
      );

      await credentials.save('pat2');
      await githubGet(
        'https://api.github.com/repos/acme/project',
        rateLimit: limit,
        credentials: credentials,
        client: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer pat2');
          return http.Response('{}', 200);
        }),
      );

      await credentials.remove();
      final anonymousCallsBeforeCooldown = requests;
      await expectLater(
        githubGet(
          'https://api.github.com/repos/acme/project',
          rateLimit: limit,
          client: anonymousLimited,
          credentials: credentials,
        ),
        throwsA(isA<GithubRequestException>()),
      );
      expect(requests, anonymousCallsBeforeCooldown);

      await credentials.save('pat1');
      final patCallsBeforeCooldown = requests;
      await expectLater(
        githubGet(
          'https://api.github.com/repos/acme/project',
          rateLimit: limit,
          client: patLimited,
          credentials: credentials,
        ),
        throwsA(isA<GithubRequestException>()),
      );
      expect(requests, patCallsBeforeCooldown);

      now = patReset;
      await githubGet(
        'https://api.github.com/repos/acme/project',
        rateLimit: limit,
        credentials: credentials,
        client: MockClient((request) async {
          expect(request.headers['authorization'], 'Bearer pat1');
          return http.Response('{}', 200);
        }),
      );
      await credentials.remove();
      now = anonymousReset;
      await githubGet(
        'https://api.github.com/repos/acme/project',
        rateLimit: limit,
        credentials: credentials,
        client: MockClient((request) async {
          expect(request.headers.containsKey('authorization'), isFalse);
          return http.Response('{}', 200);
        }),
      );
    },
  );

  test('transport failures do not expose the credential', () async {
    final credentials = GithubCredentialProvider(store: _TestStore('secret'));
    final error = await captureError(
      githubGet(
        'https://api.github.com/repos/acme/project',
        rateLimit: GithubRateLimit(),
        credentials: credentials,
        client: MockClient((_) async {
          throw http.ClientException('transport echoed secret');
        }),
      ),
    );

    expect(error, isA<GithubRequestException>());
    expect(error.toString(), isNot(contains('secret')));
    expect(error.toString(), contains('connection'));
  });

  test(
    'reflected credentials are rejected before callers receive the body',
    () async {
      const pat = 'ghp-reflected-secret';
      final credentials = GithubCredentialProvider(store: _TestStore(pat));
      final error = await captureError(
        githubGet(
          'https://api.github.com/repos/acme/project',
          rateLimit: GithubRateLimit(),
          credentials: credentials,
          client: MockClient(
            (_) async => http.Response('{"tag_name":"$pat"}', 200),
          ),
        ),
      );

      expect(error, isA<GithubRequestException>());
      expect(error.toString(), isNot(contains(pat)));
      expect(
        (error as GithubRequestException).userMessage,
        isNot(contains(pat)),
      );
      expect(
        error.toString(),
        'GitHub response rejected for security reasons.',
      );
    },
  );

  test('anonymous successful responses remain unchanged', () async {
    const pat = 'ghp-reflected-secret';
    final response = await githubGet(
      'https://api.github.com/repos/acme/project',
      rateLimit: GithubRateLimit(),
      client: MockClient(
        (_) async => http.Response('{"tag_name":"$pat"}', 200),
      ),
    );
    expect(response.body, contains(pat));
  });

  test('304 remains available for conditional requests', () async {
    final response = await githubGet(
      'https://api.github.com/repos/acme/project',
      rateLimit: GithubRateLimit(),
      allowNotModified: true,
      client: MockClient((_) async => http.Response('', 304)),
    );
    expect(response.statusCode, 304);
  });

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
