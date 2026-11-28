import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/build_info.dart';
import 'package:reaprime/src/services/github_credentials.dart';
import 'package:reaprime/src/services/github_token_verifier.dart';

class _TrackingClient extends MockClient {
  _TrackingClient()
    : super((_) async => http.Response('{"login":"user"}', 200));

  bool closed = false;

  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  const secret = 'ghp_private-token';
  final credential = GithubCredentialSnapshot.user(secret);

  test(
    'only makes a read-only fixed-origin request without redirects',
    () async {
      final requests = <http.Request>[];
      final verifier = GithubTokenVerifier(
        client: MockClient((request) async {
          requests.add(request);
          return http.Response('{"login":"decaid-user"}', 200);
        }),
      );

      final result = await verifier.verify(credential);

      expect(requests, hasLength(1));
      expect(requests.single.method, 'GET');
      expect(requests.single.url.toString(), 'https://api.github.com/user');
      expect(requests.single.url.query, isEmpty);
      expect(requests.single.body, isEmpty);
      expect(requests.single.followRedirects, isFalse);
      expect(requests.single.headers['authorization'], 'Bearer $secret');
      expect(
        requests.single.headers['user-agent'],
        'Decaid/${BuildInfo.version}',
      );
      expect(result.authenticated, isTrue);
      expect(result.message, contains('Authenticated as decaid-user'));
      expect(result.message, contains('have not been tested'));
      expect(result.message, isNot(contains(secret)));
    },
  );

  for (final login in ['mona-cat_octo', 'octo_admin']) {
    test('authenticates the managed-user login $login', () async {
      final result = await GithubTokenVerifier(
        client: MockClient(
          (_) async => http.Response('{"login":"$login"}', 200),
        ),
      ).verify(credential);

      expect(result.authenticated, isTrue);
      expect(result.message, contains('Authenticated as $login'));
      expect(result.message, contains('have not been tested'));
      expect(result.message, isNot(contains(secret)));
    });
  }

  for (final headers in <Map<String, String>>[
    {},
    {'x-oauth-scopes': 'repo, gist'},
    {'x-oauth-scopes': 'read:user'},
    {'x-oauth-scopes': 'not-a-scope'},
  ]) {
    test('does not infer write permissions from $headers', () async {
      final verifier = GithubTokenVerifier(
        client: MockClient(
          (_) async =>
              http.Response('{"login":"decaid-user"}', 200, headers: headers),
        ),
      );

      final result = await verifier.verify(credential);

      expect(result.authenticated, isTrue);
      expect(result.message, contains('have not been tested'));
      expect(result.message, isNot(contains('missing')));
    });
  }

  test('fine-grained and unknown tokens only verify authentication', () async {
    final verifier = GithubTokenVerifier(
      client: MockClient((_) async => http.Response('{"login":"user"}', 200)),
    );
    for (final token in ['github_pat_private-token', 'unknown-token']) {
      final result = await verifier.verify(
        GithubCredentialSnapshot.user(token),
      );
      expect(result.authenticated, isTrue);
      expect(result.message, contains('have not been tested'));
    }
  });

  for (final credential in [
    const GithubCredentialSnapshot.anonymous(),
    GithubCredentialSnapshot.bundled(secret),
  ]) {
    test(
      'does not probe ${credential.isBundled ? 'bundled' : 'anonymous'} credentials',
      () async {
        var requests = 0;
        final verifier = GithubTokenVerifier(
          client: MockClient((_) async {
            requests++;
            return http.Response('{"login":"user"}', 200);
          }),
        );

        final result = await verifier.verify(credential);

        expect(requests, 0);
        expect(result.authenticated, isFalse);
        expect(result.message, contains('Paste or save a token'));
      },
    );
  }

  for (final body in [
    'not json',
    'null',
    '[]',
    '{}',
    '{"login":42}',
    '{"login":""}',
    '{"login":"invalid user"}',
    '{"login":"${'a' * 40}"}',
    '{"login":"user","unexpected":"$secret"}',
    '{"login":"ghp_private-token"}',
  ]) {
    test('rejects malformed or reflected identity response $body', () async {
      final result = await GithubTokenVerifier(
        client: MockClient((_) async => http.Response(body, 200)),
      ).verify(credential);

      expect(result.authenticated, isFalse);
      expect(result.message, isNot(contains(secret)));
      expect(result.message, isNot(contains(body)));
    });
  }

  test('rejects a JSON-escaped reflected identity', () async {
    final result = await GithubTokenVerifier(
      client: MockClient(
        (_) async => http.Response('{"login":"\\u0073ecret"}', 200),
      ),
    ).verify(GithubCredentialSnapshot.user('secret'));

    expect(result.authenticated, isFalse);
    expect(result.message, isNot(contains('secret')));
  });

  for (final status in [401, 403, 429, 500, 302]) {
    test('returns a safe message for HTTP $status', () async {
      final requests = <http.Request>[];
      final result = await GithubTokenVerifier(
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
            '$secret private response',
            status,
            headers: {'location': 'https://evil.example/$secret'},
          );
        }),
      ).verify(credential);

      expect(result.authenticated, isFalse);
      expect(requests, hasLength(1));
      expect(result.message, isNot(contains(secret)));
      expect(result.message, isNot(contains('private response')));
      expect(result.message, isNot(contains('evil.example')));
    });
  }

  test('reports only validated rate limit reset information', () async {
    final result = await GithubTokenVerifier(
      client: MockClient(
        (_) async => http.Response(
          secret,
          403,
          headers: {
            'x-ratelimit-remaining': '0',
            'x-ratelimit-reset': '1893456000',
          },
        ),
      ),
    ).verify(credential);

    expect(result.authenticated, isFalse);
    expect(result.message, contains('2030-01-01'));
    expect(result.message, isNot(contains(secret)));
  });

  test('does not reflect malformed rate-limit headers', () async {
    final result = await GithubTokenVerifier(
      client: MockClient(
        (_) async => http.Response(
          secret,
          429,
          headers: {'x-ratelimit-remaining': '0', 'x-ratelimit-reset': secret},
        ),
      ),
    ).verify(credential);

    expect(result.authenticated, isFalse);
    expect(result.message, isNot(contains(secret)));
  });

  test('sanitizes transport errors', () async {
    final result = await GithubTokenVerifier(
      client: MockClient((_) async => throw http.ClientException(secret)),
    ).verify(credential);

    expect(result.authenticated, isFalse);
    expect(result.message, contains('connection'));
    expect(result.message, isNot(contains(secret)));
  });

  test('bounds a request stalled before response headers', () async {
    final result = await GithubTokenVerifier(
      timeout: const Duration(milliseconds: 1),
      client: MockClient((_) => Completer<http.Response>().future),
    ).verify(credential);

    expect(result.authenticated, isFalse);
    expect(result.message, contains('timed out'));
  });

  test('bounds body delivery and aborts the timed-out request', () async {
    var aborted = false;
    final result = await GithubTokenVerifier(
      timeout: const Duration(milliseconds: 1),
      client: MockClient.streaming((request, _) async {
        final body = StreamController<List<int>>();
        unawaited(
          (request as http.Abortable).abortTrigger!.then((_) async {
            aborted = true;
            await body.close();
          }),
        );
        return http.StreamedResponse(body.stream, 200);
      }),
    ).verify(credential);
    await Future<void>.delayed(Duration.zero);

    expect(result.authenticated, isFalse);
    expect(result.message, contains('timed out'));
    expect(aborted, isTrue);
  });

  test('closes an owned client but leaves an injected client open', () async {
    final owned = _TrackingClient();
    await http.runWithClient(
      () => const GithubTokenVerifier().verify(credential),
      () => owned,
    );
    expect(owned.closed, isTrue);

    final injected = _TrackingClient();
    await GithubTokenVerifier(client: injected).verify(credential);
    expect(injected.closed, isFalse);
    injected.close();
  });
}
