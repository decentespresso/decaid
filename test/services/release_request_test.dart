import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/build_info.dart';
import 'package:reaprime/src/services/release_request.dart';

final versionedUserAgent = 'Decaid/${BuildInfo.version}';

const mirrorReleaseUrl =
    'https://fast.decentespresso.com/decentespresso/decaid/releases/download/'
    'v1.0.0/app.apk';
const githubReleaseUrl =
    'https://github.com/decentespresso/decaid/releases/download/v1.0.0/app.apk';
const assetReleaseUrl =
    'https://release-assets.githubusercontent.com/github-production-release-'
    'asset/app.apk';

const syntheticAccountHeaders = {
  'Authorization': 'Bearer ghp-synthetic-account-token',
  'Cookie': 'session=synthetic-account-session',
  'Proxy-Authorization': 'Basic c3ludGhldGljOmFjY291bnQ=',
};

const credentialHeaderNames = {
  'authorization',
  'cookie',
  'proxy-authorization',
};

void expectVersionedUserAgent(Iterable<http.BaseRequest> requests) {
  expect(requests, isNotEmpty);
  expect(
    requests.map((request) => request.headers['user-agent']),
    everyElement(versionedUserAgent),
  );
}

void expectNoCredentialHeaders(Iterable<http.BaseRequest> requests) {
  expect(requests, isNotEmpty);
  for (final request in requests) {
    expect(
      request.headers.keys.map((key) => key.toLowerCase()),
      everyElement(isNot(isIn(credentialHeaderNames))),
    );
  }
}

class _SeenRequest {
  _SeenRequest(HttpRequest request)
    : method = request.method,
      path = request.uri.path,
      userAgent = request.headers.value(HttpHeaders.userAgentHeader),
      authorization = request.headers.value(HttpHeaders.authorizationHeader),
      cookie = request.headers.value(HttpHeaders.cookieHeader),
      proxyAuthorization = request.headers.value(
        HttpHeaders.proxyAuthorizationHeader,
      );

  final String method;
  final String path;
  final String? userAgent;
  final String? authorization;
  final String? cookie;
  final String? proxyAuthorization;
}

class _TestServer {
  _TestServer._(this._server);

  final HttpServer _server;
  final seen = <_SeenRequest>[];

  String get origin => 'http://${_server.address.address}:${_server.port}';

  static Future<_TestServer> start(
    Future<void> Function(HttpRequest request, String origin) handler,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final instance = _TestServer._(server);
    server.listen((request) {
      instance.seen.add(_SeenRequest(request));
      handler(request, instance.origin);
    });
    return instance;
  }

  Future<void> close() => _server.close(force: true);
}

void main() {
  group('releaseUserAgent', () {
    test('derives the value from the build version', () {
      expect(releaseUserAgent(), versionedUserAgent);
      expect(releaseUserAgent(), isNot('Decaid'));
      expect(releaseUserAgent(), startsWith('Decaid/'));
    });

    for (final (version, expected) in <(String, String)>[
      ('0.9.4', 'Decaid/0.9.4'),
      ('0.9.4-beta.1', 'Decaid/0.9.4-beta.1'),
      (' 1.2.3 ', 'Decaid/1.2.3'),
      ('', 'Decaid/unknown'),
    ]) {
      test('formats "$version" as $expected', () {
        expect(releaseUserAgent(version: version), expected);
      });
    }

    test(
      'headers always keep the versioned user agent and drop credentials',
      () {
        expect(releaseRequestHeaders()['User-Agent'], versionedUserAgent);
        expect(
          releaseRequestHeaders(headers: {'User-Agent': 'other'})['User-Agent'],
          versionedUserAgent,
        );
        expect(
          releaseRequestHeaders(headers: {'user-agent': 'other'})['User-Agent'],
          versionedUserAgent,
        );
        final withCredentials = releaseRequestHeaders(
          headers: {
            'Authorization': 'Bearer secret',
            'cookie': 'session=secret',
            'If-None-Match': '"v1"',
          },
        );
        expect(withCredentials['User-Agent'], versionedUserAgent);
        expect(withCredentials['If-None-Match'], '"v1"');
        expect(
          withCredentials.keys.map((key) => key.toLowerCase()),
          everyElement(isNot(anyOf('authorization', 'cookie'))),
        );
      },
    );
  });

  group('request shaping', () {
    test(
      'buffered GET sends the versioned user agent without auto redirects',
      () async {
        final requests = <http.Request>[];
        final response = await releaseGet(
          'https://fast.decentespresso.com/channels.json',
          client: MockClient((request) async {
            requests.add(request);
            return http.Response('{"stable":"v1"}', 200);
          }),
        );

        expect(response.body, '{"stable":"v1"}');
        expect(requests.single.headers['user-agent'], versionedUserAgent);
        expect(requests.single.followRedirects, isFalse);
        expect(requests.single.headers.containsKey('authorization'), isFalse);
      },
    );

    test('HEAD channel pointer checks send the versioned user agent', () async {
      final requests = <http.Request>[];
      final response = await releaseHead(
        'https://fast.decentespresso.com/channel/stable',
        client: MockClient((request) async {
          requests.add(request);
          return http.Response('', 200, headers: {'etag': '"channel-1"'});
        }),
      );

      expect(response.statusCode, 200);
      expect(response.headers['etag'], '"channel-1"');
      expect(requests.single.method, 'HEAD');
      expect(requests.single.headers['user-agent'], versionedUserAgent);
      expect(requests.single.followRedirects, isFalse);
    });

    test('streamed requests send the versioned user agent', () async {
      final requests = <http.BaseRequest>[];
      final client = MockClient.streaming((request, body) async {
        requests.add(request);
        return http.StreamedResponse(
          Stream.fromIterable([
            [1, 2, 3],
          ]),
          200,
          contentLength: 3,
        );
      });

      final response = await releaseStreamRequest(
        client,
        Uri.parse('https://fast.decentespresso.com/app.apk'),
      );

      expect(await response.stream.toBytes(), [1, 2, 3]);
      expect(requests.single.headers['user-agent'], versionedUserAgent);
      expect(requests.single.followRedirects, isFalse);
    });

    test(
      'redirect hops rebuild headers and resolve relative locations',
      () async {
        final requests = <http.Request>[];
        final response = await releaseGet(
          'https://fast.decentespresso.com/mirror/skin.zip',
          client: MockClient((request) async {
            requests.add(request);
            if (request.url.path == '/mirror/skin.zip') {
              return http.Response(
                '',
                302,
                headers: {'location': '/artifacts/skin.zip'},
              );
            }
            return http.Response.bytes([4, 5, 6], 200);
          }),
        );

        expect(response.bodyBytes, [4, 5, 6]);
        expect(requests.map((request) => request.url.toString()), [
          'https://fast.decentespresso.com/mirror/skin.zip',
          'https://fast.decentespresso.com/artifacts/skin.zip',
        ]);
        expect(
          requests.map((request) => request.headers['user-agent']),
          everyElement(versionedUserAgent),
        );
        expect(
          requests.map((request) => request.followRedirects),
          everyElement(isFalse),
        );
      },
    );

    test(
      'redirect chains stop at the limit and return the last response',
      () async {
        var requests = 0;
        final response = await releaseGet(
          'https://fast.decentespresso.com/loop',
          client: MockClient((_) async {
            requests++;
            return http.Response('', 302, headers: {'location': '/loop'});
          }),
        );

        expect(response.statusCode, 302);
        expect(requests, releaseRedirectLimit + 1);
      },
    );

    test('a zero limit returns the channel pointer itself', () async {
      var requests = 0;
      final response = await releaseGet(
        'https://fast.decentespresso.com/channel/stable',
        client: MockClient((_) async {
          requests++;
          return http.Response(
            '',
            307,
            headers: {'location': '/artifacts/app.apk'},
          );
        }),
        maxRedirects: 0,
      );

      expect(response.statusCode, 307);
      expect(response.headers['location'], '/artifacts/app.apk');
      expect(requests, 1);
    });

    test('non-http redirect targets are not followed', () async {
      var requests = 0;
      final response = await releaseGet(
        'https://fast.decentespresso.com/mirror.apk',
        client: MockClient((_) async {
          requests++;
          return http.Response(
            '',
            302,
            headers: {'location': 'file:///etc/passwd'},
          );
        }),
      );

      expect(response.statusCode, 302);
      expect(requests, 1);
    });
  });

  group('named host chains', () {
    for (final status in [302, 307]) {
      test(
        'a $status mirror to github to assets chain carries no credentials',
        () async {
          final requests = <http.Request>[];
          final response = await releaseGet(
            mirrorReleaseUrl,
            headers: syntheticAccountHeaders,
            client: MockClient((request) async {
              requests.add(request);
              return switch (request.url.toString()) {
                mirrorReleaseUrl => http.Response(
                  '',
                  status,
                  headers: {'location': githubReleaseUrl},
                ),
                githubReleaseUrl => http.Response(
                  '',
                  status,
                  headers: {'location': assetReleaseUrl},
                ),
                assetReleaseUrl => http.Response.bytes([10, 11, 12], 200),
                _ => http.Response('', 404),
              };
            }),
          );

          expect(response.statusCode, 200);
          expect(response.bodyBytes, [10, 11, 12]);
          expect(requests.map((request) => request.url.toString()), [
            mirrorReleaseUrl,
            githubReleaseUrl,
            assetReleaseUrl,
          ]);
          expect(requests.map((request) => request.url.host), [
            'fast.decentespresso.com',
            'github.com',
            'release-assets.githubusercontent.com',
          ]);
          expect(
            requests.map((request) => request.method),
            everyElement('GET'),
          );
          expect(
            requests.map((request) => request.followRedirects),
            everyElement(isFalse),
          );
          expectVersionedUserAgent(requests);
          expectNoCredentialHeaders(requests);
        },
      );
    }

    test('a github to assets hop keeps the versioned user agent', () async {
      final requests = <http.Request>[];
      final response = await releaseHead(
        githubReleaseUrl,
        headers: syntheticAccountHeaders,
        client: MockClient((request) async {
          requests.add(request);
          if (request.url.host == 'github.com') {
            return http.Response(
              '',
              302,
              headers: {'location': assetReleaseUrl},
            );
          }
          return http.Response('', 200, headers: {'etag': '"asset-1"'});
        }),
      );

      expect(response.statusCode, 200);
      expect(response.headers['etag'], '"asset-1"');
      expect(requests.map((request) => request.url.toString()), [
        githubReleaseUrl,
        assetReleaseUrl,
      ]);
      expect(requests.map((request) => request.method), everyElement('HEAD'));
      expectVersionedUserAgent(requests);
      expectNoCredentialHeaders(requests);
    });

    test(
      'a caller fallback from an unavailable mirror requests github.com',
      () async {
        final requests = <http.Request>[];
        final client = MockClient((request) async {
          requests.add(request);
          if (request.url.host == 'fast.decentespresso.com') {
            return http.Response('', 503);
          }
          return http.Response.bytes([13, 14, 15], 200);
        });

        Future<http.Response> mirrorThenGithub(
          String mirror,
          String direct,
        ) async {
          final mirrored = await releaseGet(
            mirror,
            client: client,
            headers: syntheticAccountHeaders,
          );
          if (mirrored.statusCode == 200) return mirrored;
          return releaseGet(
            direct,
            client: client,
            headers: syntheticAccountHeaders,
          );
        }

        final response = await mirrorThenGithub(
          mirrorReleaseUrl,
          githubReleaseUrl,
        );

        expect(response.statusCode, 200);
        expect(response.bodyBytes, [13, 14, 15]);
        expect(requests.map((request) => request.url.toString()), [
          mirrorReleaseUrl,
          githubReleaseUrl,
        ]);
        expect(requests.map((request) => request.url.host), [
          'fast.decentespresso.com',
          'github.com',
        ]);
        expectVersionedUserAgent(requests);
        expectNoCredentialHeaders(requests);
      },
    );
  });

  group('redirect downgrade', () {
    test('rejects an https to http redirect before the next request', () async {
      final requests = <http.BaseRequest>[];
      var drained = 0;
      final client = MockClient.streaming((request, body) async {
        requests.add(request);
        if (request.url.path == '/channels.json') {
          return http.StreamedResponse(
            Stream.fromIterable([
              [1],
            ]),
            200,
            contentLength: 1,
          );
        }
        return http.StreamedResponse(
          Stream.fromIterable([
            [1, 2, 3],
            [4, 5],
          ]).map((chunk) {
            drained += chunk.length;
            return chunk;
          }),
          302,
          headers: {
            'location': 'http://fast.decentespresso.com/artifacts/app.apk',
          },
        );
      });

      await expectLater(
        releaseStreamRequest(client, Uri.parse(mirrorReleaseUrl)),
        throwsA(isA<http.ClientException>()),
      );

      expect(requests, hasLength(1));
      expect(requests.single.url.toString(), mirrorReleaseUrl);
      expect(requests.single.headers['user-agent'], versionedUserAgent);
      expect(
        requests.map((request) => request.url.scheme),
        everyElement('https'),
      );
      expect(drained, 5);

      final later = await releaseGet(
        'https://fast.decentespresso.com/channels.json',
        client: client,
      );

      expect(later.statusCode, 200);
      expect(later.bodyBytes, [1]);
      expect(requests, hasLength(2));
    });

    test('rejects a downgrade after following a secure hop', () async {
      final requests = <http.BaseRequest>[];
      final client = MockClient.streaming((request, body) async {
        requests.add(request);
        return http.StreamedResponse(
          const Stream.empty(),
          request.url.host == 'fast.decentespresso.com' ? 307 : 308,
          headers: {
            'location': request.url.host == 'fast.decentespresso.com'
                ? githubReleaseUrl
                : 'http://github.com/decentespresso/decaid/app.apk',
          },
        );
      });

      await expectLater(
        releaseStreamRequest(client, Uri.parse(mirrorReleaseUrl)),
        throwsA(isA<http.ClientException>()),
      );

      expect(requests.map((request) => request.url.scheme), ['https', 'https']);
      expectVersionedUserAgent(requests);
      expectNoCredentialHeaders(requests);
    });

    test('follows an http loopback redirect', () async {
      final server = await _TestServer.start((request, origin) async {
        if (request.uri.path == '/mirror/app.apk') {
          request.response.statusCode = HttpStatus.found;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '$origin/artifacts/app.apk',
          );
        } else {
          request.response.add([3, 2, 1]);
        }
        await request.response.close();
      });
      addTearDown(server.close);

      final response = await releaseGet('${server.origin}/mirror/app.apk');

      expect(response.statusCode, 200);
      expect(response.bodyBytes, [3, 2, 1]);
      expect(server.seen.map((request) => request.path), [
        '/mirror/app.apk',
        '/artifacts/app.apk',
      ]);
      expect(
        server.seen.map((request) => request.userAgent),
        everyElement(versionedUserAgent),
      );
    });
  });

  group('cross-origin redirects', () {
    for (final status in [302, 307]) {
      test('a $status redirect to another origin drops credentials', () async {
        final destination = await _TestServer.start((request, origin) async {
          request.response.add([7, 8, 9]);
          await request.response.close();
        });
        addTearDown(destination.close);
        final mirror = await _TestServer.start((request, origin) async {
          request.response.statusCode = status;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '${destination.origin}/artifacts/app.apk',
          );
          await request.response.close();
        });
        addTearDown(mirror.close);

        final response = await releaseGet(
          '${mirror.origin}/mirror/app.apk',
          headers: {
            'Authorization': 'Bearer ghp-synthetic-pat',
            'Cookie': 'session=synthetic-account',
            'Proxy-Authorization': 'Basic c3ludGhldGljOmFjY291bnQ=',
          },
        );

        expect(response.statusCode, 200);
        expect(response.bodyBytes, [7, 8, 9]);
        expect(mirror.origin, isNot(destination.origin));
        expect(mirror.seen.single.path, '/mirror/app.apk');
        expect(destination.seen.single.path, '/artifacts/app.apk');
        for (final seen in [...mirror.seen, ...destination.seen]) {
          expect(seen.userAgent, versionedUserAgent);
          expect(seen.authorization, isNull);
          expect(seen.cookie, isNull);
          expect(seen.proxyAuthorization, isNull);
        }
      });
    }
  });

  group('real transport', () {
    test(
      'a mirror channel pointer HEAD carries the versioned user agent',
      () async {
        final server = await _TestServer.start((request, origin) async {
          request.response.headers.set('etag', '"stable-1"');
          await request.response.close();
        });
        addTearDown(server.close);

        final response = await releaseHead('${server.origin}/channel/stable');

        expect(response.statusCode, 200);
        expect(response.headers['etag'], '"stable-1"');
        expect(server.seen.single.method, 'HEAD');
        expect(server.seen.single.userAgent, versionedUserAgent);
        expect(server.seen.single.authorization, isNull);
      },
    );

    test('a channels.json GET carries the versioned user agent', () async {
      final server = await _TestServer.start((request, origin) async {
        request.response.write(jsonEncode({'stable': 'v1.0.0'}));
        await request.response.close();
      });
      addTearDown(server.close);

      final response = await releaseGet('${server.origin}/channels.json');

      expect(response.statusCode, 200);
      expect(jsonDecode(response.body), {'stable': 'v1.0.0'});
      expect(server.seen.single.userAgent, versionedUserAgent);
    });

    for (final status in [302, 307]) {
      test(
        'a $status mirror redirect keeps the user agent and drops credentials',
        () async {
          final server = await _TestServer.start((request, origin) async {
            if (request.uri.path == '/mirror/skin.zip') {
              request.response.statusCode = status;
              request.response.headers.set(
                HttpHeaders.locationHeader,
                '$origin/artifacts/skin.zip',
              );
            } else {
              request.response.add([7, 8, 9]);
            }
            await request.response.close();
          });
          addTearDown(server.close);

          final response = await releaseGet(
            '${server.origin}/mirror/skin.zip',
            headers: {
              'Authorization': 'Bearer ghp-configured-secret',
              'Cookie': 'session=decent-account-secret',
            },
          );

          expect(response.statusCode, 200);
          expect(response.bodyBytes, [7, 8, 9]);
          expect(server.seen.map((request) => request.path), [
            '/mirror/skin.zip',
            '/artifacts/skin.zip',
          ]);
          expect(
            server.seen.map((request) => request.userAgent),
            everyElement(versionedUserAgent),
          );
          expect(
            server.seen.map((request) => request.authorization),
            everyElement(isNull),
          );
          expect(
            server.seen.map((request) => request.cookie),
            everyElement(isNull),
          );
        },
      );
    }

    test('redirect chains stay bounded over a real transport', () async {
      final server = await _TestServer.start((request, origin) async {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          '$origin/loop',
        );
        await request.response.close();
      });
      addTearDown(server.close);

      final response = await releaseGet(
        '${server.origin}/loop',
        maxRedirects: 3,
      );

      expect(response.statusCode, 302);
      expect(server.seen, hasLength(4));
      expect(
        server.seen.map((request) => request.userAgent),
        everyElement(versionedUserAgent),
      );
    });

    test(
      'a caller fallback after an unavailable mirror keeps the user agent',
      () async {
        final server = await _TestServer.start((request, origin) async {
          if (request.uri.path == '/mirror/app.apk') {
            request.response.statusCode = HttpStatus.serviceUnavailable;
          } else {
            request.response.add([1, 1, 1]);
          }
          await request.response.close();
        });
        addTearDown(server.close);

        Future<http.Response> mirrorThenDirect(
          String mirror,
          String direct,
        ) async {
          try {
            final response = await releaseGet(mirror);
            if (response.statusCode == 200) return response;
          } catch (_) {
            // Mirror unavailability falls through to the direct source.
          }
          return releaseGet(direct);
        }

        final response = await mirrorThenDirect(
          '${server.origin}/mirror/app.apk',
          '${server.origin}/github/app.apk',
        );

        expect(response.statusCode, 200);
        expect(response.bodyBytes, [1, 1, 1]);
        expect(server.seen.map((request) => request.path), [
          '/mirror/app.apk',
          '/github/app.apk',
        ]);
        expect(
          server.seen.map((request) => request.userAgent),
          everyElement(versionedUserAgent),
        );
      },
    );

    test(
      'a refused mirror connection still falls back with the user agent',
      () async {
        final server = await _TestServer.start((request, origin) async {
          request.response.add([2, 2, 2]);
          await request.response.close();
        });
        addTearDown(server.close);
        final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final closedOrigin = 'http://${closed.address.address}:${closed.port}';
        await closed.close(force: true);

        Object? mirrorError;
        Future<http.Response?> attempt(String url) async {
          try {
            return await releaseGet(url);
          } catch (error) {
            mirrorError = error;
            return null;
          }
        }

        final response =
            await attempt('$closedOrigin/mirror/app.apk') ??
            await releaseGet('${server.origin}/github/app.apk');

        expect(mirrorError, isNotNull);
        expect(response.statusCode, 200);
        expect(response.bodyBytes, [2, 2, 2]);
        expect(server.seen.single.userAgent, versionedUserAgent);
      },
    );
  });
}
