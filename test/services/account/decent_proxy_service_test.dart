import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:logging/logging.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/account/decent_proxy_service.dart';

class FakeCredentialStore implements CredentialStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read({required String key}) async => _values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    _values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    _values.remove(key);
  }
}

Future<bool> _allowConsent(String _) async => true;

void main() {
  late FakeCredentialStore store;

  setUp(() {
    store = FakeCredentialStore();
  });

  Future<void> linkAccount() async {
    await store.write(key: 'email', value: 'user@example.com');
    await store.write(key: 'password', value: 'cryptpw_abc123');
  }

  DecentProxyService buildService(
    http_testing.MockClientHandler handler, {
    String baseUrl = 'https://decentespresso.com',
    Future<bool> Function(String callerId) requireConsent = _allowConsent,
    void Function()? onAuthFailure,
    Future<bool> Function()? isAuthKnownInvalid,
  }) {
    return DecentProxyService(
      httpClient: http_testing.MockClient(handler),
      credentialStore: store,
      requireConsent: requireConsent,
      baseUrl: baseUrl,
      onAuthFailure: onAuthFailure,
      isAuthKnownInvalid: isAuthKnownInvalid,
    );
  }

  test('throws when no account is linked', () async {
    final service = buildService((request) async {
      fail('must not call upstream when not linked: ${request.url}');
    });

    expect(
      () => service.proxyGet(callerId: 'skin', path: 'support/api/sn'),
      throwsA(isA<DecentAccountNotLinkedException>()),
    );
  });

  test('denied consent never reaches the upstream service', () async {
    await linkAccount();
    String? consentCaller;
    final service = buildService(
      (request) async {
        fail('must not call upstream when consent is denied: ${request.url}');
      },
      requireConsent: (callerId) async {
        consentCaller = callerId;
        return false;
      },
    );

    await expectLater(
      service.proxyGet(callerId: 'plugin:dye2', path: 'support/api/sn'),
      throwsA(isA<DecentProxyConsentDeniedException>()),
    );
    expect(consentCaller, 'plugin:dye2');
  });

  test('attaches Basic auth and relays the upstream body + status', () async {
    await linkAccount();
    late http.Request captured;
    final service = buildService((request) async {
      captured = request;
      return http.Response('SN001\nSN002', 200);
    });

    final result = await service.proxyGet(
      callerId: 'skin',
      path: 'support/api/sn',
    );

    expect(result.statusCode, 200);
    expect(result.body, 'SN001\nSN002');

    final expected =
        'Basic ${base64Encode(utf8.encode('user@example.com:cryptpw_abc123'))}';
    expect(captured.headers['authorization'], expected);
    expect(
      captured.url.toString(),
      'https://decentespresso.com/support/api/sn',
    );
  });

  test('never leaks credentials into the returned response', () async {
    await linkAccount();
    final service = buildService((request) async {
      return http.Response('ok', 200);
    });

    final result = await service.proxyGet(
      callerId: 'skin',
      path: 'support/api/sn',
    );

    final serialized = '${result.body} ${jsonEncode(result.headers)}';
    expect(serialized.contains('cryptpw_abc123'), isFalse);
    expect(serialized.toLowerCase().contains('authorization'), isFalse);
  });

  test('relays upstream error status verbatim', () async {
    await linkAccount();
    final service = buildService((request) async {
      return http.Response('upstream boom', 503);
    });

    final result = await service.proxyGet(
      callerId: 'api:tok',
      path: 'support/api/sn',
    );

    expect(result.statusCode, 503);
    expect(result.body, 'upstream boom');
  });

  test('relays upstream response body bytes without decoding', () async {
    await linkAccount();
    final service = buildService((request) async {
      return http.Response.bytes(
        [0, 159, 146, 150, 255],
        206,
        headers: {'content-type': 'application/octet-stream'},
      );
    });

    final result = await service.proxyGet(
      callerId: 'api:tok',
      path: 'support/api/blob',
    );

    expect(result.statusCode, 206);
    expect(result.bodyBytes, [0, 159, 146, 150, 255]);
    expect(result.headers['content-type'], 'application/octet-stream');
  });

  test('strips sensitive response headers but keeps content-type', () async {
    await linkAccount();
    final service = buildService((request) async {
      return http.Response(
        '{}',
        200,
        headers: {
          'content-type': 'application/json',
          'set-cookie': 'session=secret',
          'www-authenticate': 'Basic realm="x"',
          'content-encoding': 'gzip',
        },
      );
    });

    final result = await service.proxyGet(
      callerId: 'skin',
      path: 'support/api/sn',
    );

    expect(result.headers['content-type'], 'application/json');
    expect(result.headers.containsKey('set-cookie'), isFalse);
    expect(result.headers.containsKey('www-authenticate'), isFalse);
    expect(result.headers.containsKey('content-encoding'), isFalse);
    expect(result.headers.containsKey('content-length'), isFalse);
  });

  test('rejects a path outside the allowed prefix', () async {
    await linkAccount();
    final service = buildService((request) async {
      fail('must not call upstream for a forbidden path: ${request.url}');
    });

    expect(
      () => service.proxyGet(callerId: 'skin', path: 'admin/delete-all'),
      throwsA(isA<DecentProxyForbiddenPathException>()),
    );
  });

  test('rejects dot segments before building the upstream URI', () async {
    await linkAccount();
    final service = buildService((request) async {
      fail('must not call upstream for a dot-segment path: ${request.url}');
    });

    expect(
      () => service.proxyPost(
        callerId: 'api:writer',
        path: 'support/api/../admin',
        body: '{}',
        contentType: 'application/json',
      ),
      throwsA(isA<DecentProxyForbiddenPathException>()),
    );

    expect(
      () => service.proxyPut(
        callerId: 'api:writer',
        path: 'support/api/../../admin',
        body: '{}',
        contentType: 'application/json',
      ),
      throwsA(isA<DecentProxyForbiddenPathException>()),
    );
  });

  test('rejects encoded dot segments before forwarding', () async {
    await linkAccount();
    final service = buildService((request) async {
      fail('must not call upstream for encoded dot segments: ${request.url}');
    });

    expect(
      () =>
          service.proxyGet(callerId: 'skin', path: 'support/api/%2e%2e/admin'),
      throwsA(isA<DecentProxyForbiddenPathException>()),
    );

    expect(
      () => service.proxyGet(
        callerId: 'skin',
        path: 'support/api/%252e%252e/admin',
      ),
      throwsA(isA<DecentProxyForbiddenPathException>()),
    );
  });

  test('rejects malformed path encoding before forwarding', () async {
    await linkAccount();
    final service = buildService((request) async {
      fail(
        'must not call upstream for malformed path encoding: ${request.url}',
      );
    });

    expect(
      () => service.proxyGet(callerId: 'skin', path: 'support/api/%zz/admin'),
      throwsA(isA<DecentProxyForbiddenPathException>()),
    );
  });

  test('normalizes a leading slash in the path', () async {
    await linkAccount();
    late http.Request captured;
    final service = buildService((request) async {
      captured = request;
      return http.Response('ok', 200);
    });

    await service.proxyGet(callerId: 'skin', path: '/support/api/sn');

    expect(
      captured.url.toString(),
      'https://decentespresso.com/support/api/sn',
    );
  });

  test('forwards query parameters', () async {
    await linkAccount();
    late http.Request captured;
    final service = buildService((request) async {
      captured = request;
      return http.Response('ok', 200);
    });

    await service.proxyGet(
      callerId: 'skin',
      path: 'support/api/email',
      query: {'subject': 'hi there', 'body': 'b'},
    );

    expect(captured.url.queryParameters['subject'], 'hi there');
    expect(captured.url.queryParameters['body'], 'b');
  });

  test(
    'forwards repeated raw query parameters without collapsing them',
    () async {
      await linkAccount();
      late http.Request captured;
      final service = buildService((request) async {
        captured = request;
        return http.Response('ok', 200);
      });

      await service.proxyGet(
        callerId: 'skin',
        path: 'support/api/search',
        rawQuery: 'id=1&id=2&tag=light&tag=dark',
      );

      expect(captured.url.query, 'id=1&id=2&tag=light&tag=dark');
      expect(captured.url.queryParametersAll['id'], ['1', '2']);
      expect(captured.url.queryParametersAll['tag'], ['light', 'dark']);
    },
  );

  test('forwards POST body and content-type', () async {
    await linkAccount();
    late http.Request captured;
    final service = buildService((request) async {
      captured = request;
      return http.Response('posted', 201);
    });

    final result = await service.proxyPost(
      callerId: 'api:writer',
      path: 'support/api/email',
      body: '{"subject":"hi"}',
      contentType: 'application/json',
    );

    expect(result.statusCode, 201);
    expect(result.body, 'posted');
    expect(captured.method, 'POST');
    expect(captured.body, '{"subject":"hi"}');
    expect(captured.headers['content-type'], 'application/json');

    final expected =
        'Basic ${base64Encode(utf8.encode('user@example.com:cryptpw_abc123'))}';
    expect(captured.headers['authorization'], expected);
    expect(
      captured.url.toString(),
      'https://decentespresso.com/support/api/email',
    );
  });

  test('forwards write body bytes without synthesizing content-type', () async {
    await linkAccount();
    late http.Request captured;
    final service = buildService((request) async {
      captured = request;
      return http.Response('posted', 201);
    });

    await service.proxyPost(
      callerId: 'api:writer',
      path: 'support/api/upload',
      bodyBytes: [0, 1, 2, 255],
    );

    expect(captured.method, 'POST');
    expect(captured.bodyBytes, [0, 1, 2, 255]);
    expect(captured.headers.containsKey('content-type'), isFalse);
  });

  test('preserves caller content-type exactly for write body bytes', () async {
    await linkAccount();
    late http.Request captured;
    final service = buildService((request) async {
      captured = request;
      return http.Response('posted', 201);
    });

    await service.proxyPost(
      callerId: 'api:writer',
      path: 'support/api/upload',
      bodyBytes: utf8.encode('<payload />'),
      contentType: 'text/xml',
    );

    expect(captured.body, '<payload />');
    expect(captured.headers['content-type'], 'text/xml');
  });

  test('forwards PUT body and content-type', () async {
    await linkAccount();
    late http.Request captured;
    final service = buildService((request) async {
      captured = request;
      return http.Response('updated', 200);
    });

    final result = await service.proxyPut(
      callerId: 'api:writer',
      path: 'support/api/profile',
      body: 'name=rea',
      contentType: 'application/x-www-form-urlencoded',
    );

    expect(result.statusCode, 200);
    expect(result.body, 'updated');
    expect(captured.method, 'PUT');
    expect(captured.body, 'name=rea');
    expect(
      captured.headers['content-type'],
      'application/x-www-form-urlencoded',
    );
  });

  test('strips sensitive response headers from write responses', () async {
    await linkAccount();
    final service = buildService((request) async {
      return http.Response(
        '{}',
        200,
        headers: {
          'content-type': 'application/json',
          'authorization': 'Basic upstream',
          'set-cookie': 'session=secret',
          'content-length': '2',
        },
      );
    });

    final result = await service.proxyPost(
      callerId: 'api:writer',
      path: 'support/api/email',
      body: '{}',
      contentType: 'application/json',
    );

    expect(result.headers['content-type'], 'application/json');
    expect(result.headers.containsKey('authorization'), isFalse);
    expect(result.headers.containsKey('set-cookie'), isFalse);
    expect(result.headers.containsKey('content-length'), isFalse);
  });

  test('rejects a write path outside the allowed prefix', () async {
    await linkAccount();
    final service = buildService((request) async {
      fail('must not call upstream for a forbidden path: ${request.url}');
    });

    expect(
      () => service.proxyPost(
        callerId: 'api:writer',
        path: 'admin/delete-all',
        body: '{}',
        contentType: 'application/json',
      ),
      throwsA(isA<DecentProxyForbiddenPathException>()),
    );
  });

  test('emits an audit log line carrying the caller identity', () async {
    await linkAccount();
    final records = <LogRecord>[];
    final sub = Logger('DecentProxy').onRecord.listen(records.add);
    addTearDown(sub.cancel);

    final service = buildService((request) async {
      return http.Response('ok', 200);
    });

    await service.proxyGet(callerId: 'plugin:dye2', path: 'support/api/sn');

    expect(
      records.any(
        (r) =>
            r.message.contains('plugin:dye2') &&
            r.message.contains('support/api/sn'),
      ),
      isTrue,
    );
  });

  test('reports an upstream 401 to the auth-failure hook', () async {
    await linkAccount();
    var failures = 0;
    final service = buildService(
      (request) async => http.Response('unauthorized', 401),
      onAuthFailure: () => failures++,
    );

    final response = await service.proxyGet(
      callerId: 'skin',
      path: 'support/api/sn',
    );

    expect(response.statusCode, 401);
    expect(failures, 1);
  });

  test('does not call the auth-failure hook on non-401 responses', () async {
    await linkAccount();
    var failures = 0;
    final service = buildService(
      (request) async => http.Response('ok', 200),
      onAuthFailure: () => failures++,
    );

    await service.proxyGet(callerId: 'skin', path: 'support/api/sn');

    expect(failures, 0);
  });

  test('forwards when auth is not known-invalid', () async {
    await linkAccount();
    final service = buildService(
      (request) async => http.Response('ok', 200),
      isAuthKnownInvalid: () async => false,
    );

    final response = await service.proxyGet(
      callerId: 'skin',
      path: 'support/api/sn',
    );

    expect(response.statusCode, 200);
  });

  test(
    'blocks known-invalid credentials locally without upstream traffic',
    () async {
      await linkAccount();
      final service = buildService((request) async {
        fail(
          'must not call upstream when credentials are known-invalid: '
          '${request.url}',
        );
      }, isAuthKnownInvalid: () async => true);

      await expectLater(
        service.proxyGet(callerId: 'skin', path: 'support/api/sn'),
        throwsA(isA<DecentAccountAuthInvalidException>()),
      );
    },
  );

  test('successful login restores proxy access after a block', () async {
    await linkAccount();
    var authInvalid = true;

    final service = buildService(
      (request) async => http.Response('ok', 200),
      isAuthKnownInvalid: () async => authInvalid,
    );

    await expectLater(
      service.proxyGet(callerId: 'skin', path: 'support/api/sn'),
      throwsA(isA<DecentAccountAuthInvalidException>()),
    );

    authInvalid = false;

    final response = await service.proxyGet(
      callerId: 'skin',
      path: 'support/api/sn',
    );
    expect(response.statusCode, 200);
  });

  test(
    'upstream 401 invalidates auth and the next proxy call is blocked',
    () async {
      await linkAccount();
      var authInvalid = false;
      var upstreamCalls = 0;

      final service = buildService(
        (request) async {
          upstreamCalls++;
          if (upstreamCalls == 1) {
            return http.Response('unauthorized', 401);
          } else {
            fail('must not call upstream after auth is known-invalid');
          }
        },
        onAuthFailure: () => authInvalid = true,
        isAuthKnownInvalid: () async => authInvalid,
      );

      final response = await service.proxyGet(
        callerId: 'skin',
        path: 'support/api/sn',
      );
      expect(response.statusCode, 401);
      expect(upstreamCalls, 1);

      await expectLater(
        service.proxyGet(callerId: 'skin', path: 'support/api/sn'),
        throwsA(isA<DecentAccountAuthInvalidException>()),
      );
      expect(upstreamCalls, 1);
    },
  );

  test('indeterminate auth state does not block proxy traffic', () async {
    await linkAccount();
    final service = buildService(
      (request) async => http.Response('ok', 200),
      isAuthKnownInvalid: () async => false,
    );

    final response = await service.proxyGet(
      callerId: 'skin',
      path: 'support/api/sn',
    );

    expect(response.statusCode, 200);
  });
}
