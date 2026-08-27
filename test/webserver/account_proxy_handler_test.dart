import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/account/decent_proxy_service.dart';
import 'package:reaprime/src/services/account/proxy_token_service.dart';
import 'package:reaprime/src/services/webserver/proxy_auth_middleware.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

class FakeCredentialStore implements CredentialStore {
  final Map<String, String> _values = {};
  @override
  Future<String?> read({required String key}) async => _values[key];
  @override
  Future<void> write({required String key, required String value}) async =>
      _values[key] = value;
  @override
  Future<void> delete({required String key}) async => _values.remove(key);
}

void main() {
  late FakeCredentialStore store;
  late ProxyTokenService tokens;
  late Handler handler;
  late http.Request? upstream;

  setUp(() {
    store = FakeCredentialStore();
    tokens = ProxyTokenService(skinToken: 'skin-token');
    upstream = null;

    final proxy = DecentProxyService(
      requireConsent: (_) async => true,
      httpClient: http_testing.MockClient((request) async {
        upstream = request;
        return http.Response('SN001\nSN002', 200);
      }),
      credentialStore: store,
    );

    final app = Router().plus;
    AccountProxyHandler(proxy: proxy).addRoutes(app);
    handler = const Pipeline()
        .addMiddleware(proxyAuthMiddleware(tokens))
        .addHandler(app.call);
  });

  Future<void> linkAccount() async {
    await store.write(key: 'email', value: 'user@example.com');
    await store.write(key: 'password', value: 'cryptpw_abc123');
  }

  Future<Response> get(String path, {String? token}) async {
    return handler(
      Request(
        'GET',
        Uri.parse('http://localhost$path'),
        headers: token == null ? {} : {'authorization': 'Bearer $token'},
      ),
    );
  }

  Future<Response> send(
    String method,
    String path, {
    String? token,
    String? body,
    List<int>? bodyBytes,
    String? contentType,
  }) async {
    final headers = <String, String>{};
    if (token != null) {
      headers['authorization'] = 'Bearer $token';
    }
    if (contentType != null) {
      headers['content-type'] = contentType;
    }
    return handler(
      Request(
        method,
        Uri.parse('http://localhost$path'),
        headers: headers,
        body: bodyBytes ?? body,
      ),
    );
  }

  void registerWriteToken() {
    tokens.registerToken(
      'write-token',
      const ProxyCaller(
        id: 'api:writer',
        scopes: {ProxyTokenService.scopeAccountProxyWrite},
      ),
    );
  }

  test('unauthenticated proxy request is rejected (401)', () async {
    final response = await get('/api/v1/account/proxy/support/api/sn');
    expect(response.statusCode, 401);
    expect(upstream, isNull);
  });

  test('authenticated but unlinked returns 401', () async {
    final response = await get(
      '/api/v1/account/proxy/support/api/sn',
      token: 'skin-token',
    );
    expect(response.statusCode, 401);
    final body = jsonDecode(await response.readAsString());
    expect(body['error'], contains('not linked'));
    expect(upstream, isNull);
  });

  test('known-invalid credentials through GET proxy return 401', () async {
    await linkAccount();
    final app = Router().plus;
    final proxy = DecentProxyService(
      requireConsent: (_) async => true,
      httpClient: http_testing.MockClient((request) async {
        upstream = request;
        return http.Response('SN001\nSN002', 200);
      }),
      credentialStore: store,
      isAuthKnownInvalid: () async => true,
    );
    AccountProxyHandler(proxy: proxy).addRoutes(app);
    handler = const Pipeline()
        .addMiddleware(proxyAuthMiddleware(tokens))
        .addHandler(app.call);

    final response = await get(
      '/api/v1/account/proxy/support/api/sn',
      token: 'skin-token',
    );

    expect(response.statusCode, 401);
    final body = jsonDecode(await response.readAsString());
    expect(body['error'], contains('credentials are invalid'));
    expect(upstream, isNull);
  });

  test('known-invalid credentials through write proxy return 401', () async {
    await linkAccount();
    registerWriteToken();
    final app = Router().plus;
    final proxy = DecentProxyService(
      requireConsent: (_) async => true,
      httpClient: http_testing.MockClient((request) async {
        upstream = request;
        return http.Response('SN001\nSN002', 200);
      }),
      credentialStore: store,
      isAuthKnownInvalid: () async => true,
    );
    AccountProxyHandler(proxy: proxy, enableWrites: true).addRoutes(app);
    handler = const Pipeline()
        .addMiddleware(proxyAuthMiddleware(tokens))
        .addHandler(app.call);

    for (final method in ['POST', 'PUT']) {
      final response = await send(
        method,
        '/api/v1/account/proxy/support/api/email',
        token: 'write-token',
        body: '{"subject":"hi"}',
        contentType: 'application/json',
      );

      expect(response.statusCode, 401);
      final body = jsonDecode(await response.readAsString());
      expect(body['error'], contains('credentials are invalid'));
      expect(upstream, isNull);
    }
  });

  test(
    'authenticated + linked forwards with Basic auth and relays body',
    () async {
      await linkAccount();
      final response = await get(
        '/api/v1/account/proxy/support/api/sn',
        token: 'skin-token',
      );

      expect(response.statusCode, 200);
      expect(await response.readAsString(), 'SN001\nSN002');

      final expected =
          'Basic ${base64Encode(utf8.encode('user@example.com:cryptpw_abc123'))}';
      expect(upstream!.headers['authorization'], expected);
      expect(
        upstream!.url.toString(),
        'https://decentespresso.com/support/api/sn',
      );
    },
  );

  test('authenticated caller denied consent receives 403', () async {
    await linkAccount();
    final app = Router().plus;
    final proxy = DecentProxyService(
      requireConsent: (_) async => false,
      httpClient: http_testing.MockClient((request) async {
        fail('must not call upstream when consent is denied: ${request.url}');
      }),
      credentialStore: store,
    );
    AccountProxyHandler(proxy: proxy).addRoutes(app);
    handler = const Pipeline()
        .addMiddleware(proxyAuthMiddleware(tokens))
        .addHandler(app.call);

    final response = await get(
      '/api/v1/account/proxy/support/api/sn',
      token: 'skin-token',
    );

    expect(response.statusCode, 403);
    expect(
      jsonDecode(await response.readAsString())['error'],
      'Account access was not granted',
    );
    expect(upstream, isNull);
  });

  test('authenticated + linked relays upstream response bytes', () async {
    await linkAccount();
    final app = Router().plus;
    final proxy = DecentProxyService(
      requireConsent: (_) async => true,
      httpClient: http_testing.MockClient((request) async {
        upstream = request;
        return http.Response.bytes(
          [0, 159, 146, 150, 255],
          206,
          headers: {'content-type': 'application/octet-stream'},
        );
      }),
      credentialStore: store,
    );
    AccountProxyHandler(proxy: proxy).addRoutes(app);
    handler = const Pipeline()
        .addMiddleware(proxyAuthMiddleware(tokens))
        .addHandler(app.call);

    final response = await get(
      '/api/v1/account/proxy/support/api/blob',
      token: 'skin-token',
    );

    final bytes = await response.read().fold<List<int>>(
      <int>[],
      (buffer, chunk) => buffer..addAll(chunk),
    );
    expect(response.statusCode, 206);
    expect(bytes, [0, 159, 146, 150, 255]);
    expect(response.headers['content-type'], 'application/octet-stream');
  });

  test('a path outside the allowed prefix returns 403', () async {
    await linkAccount();
    final response = await get(
      '/api/v1/account/proxy/admin/wipe',
      token: 'skin-token',
    );
    expect(response.statusCode, 403);
    expect(upstream, isNull);
  });

  test('forwards query parameters to upstream', () async {
    await linkAccount();
    await get(
      '/api/v1/account/proxy/support/api/email?subject=hi&body=b',
      token: 'skin-token',
    );
    expect(upstream!.url.queryParameters['subject'], 'hi');
    expect(upstream!.url.queryParameters['body'], 'b');
  });

  test('preserves repeated query parameters when forwarding', () async {
    await linkAccount();
    await get(
      '/api/v1/account/proxy/support/api/search?id=1&id=2&tag=light&tag=dark',
      token: 'skin-token',
    );

    expect(upstream!.url.query, 'id=1&id=2&tag=light&tag=dark');
    expect(upstream!.url.queryParametersAll['id'], ['1', '2']);
    expect(upstream!.url.queryParametersAll['tag'], ['light', 'dark']);
  });

  test('read-only token is rejected for POST (403)', () async {
    await linkAccount();

    final response = await send(
      'POST',
      '/api/v1/account/proxy/support/api/email',
      token: 'skin-token',
      body: '{}',
      contentType: 'application/json',
    );

    expect(response.statusCode, 403);
    expect(upstream, isNull);
  });

  test('write routes are disabled unless explicitly enabled', () async {
    await linkAccount();
    registerWriteToken();

    final response = await send(
      'POST',
      '/api/v1/account/proxy/support/api/email',
      token: 'write-token',
      body: '{"subject":"hi"}',
      contentType: 'application/json',
    );

    expect(response.statusCode, 404);
    expect(upstream, isNull);
  });

  test('write-scoped token forwards POST body and content-type', () async {
    await linkAccount();
    registerWriteToken();
    final app = Router().plus;
    final proxy = DecentProxyService(
      requireConsent: (_) async => true,
      httpClient: http_testing.MockClient((request) async {
        upstream = request;
        return http.Response('SN001\nSN002', 200);
      }),
      credentialStore: store,
    );
    AccountProxyHandler(proxy: proxy, enableWrites: true).addRoutes(app);
    handler = const Pipeline()
        .addMiddleware(proxyAuthMiddleware(tokens))
        .addHandler(app.call);

    final response = await send(
      'POST',
      '/api/v1/account/proxy/support/api/email',
      token: 'write-token',
      body: '{"subject":"hi"}',
      contentType: 'application/json',
    );

    expect(response.statusCode, 200);
    expect(upstream, isNotNull);
    expect(upstream!.method, 'POST');
    expect(upstream!.body, '{"subject":"hi"}');
    expect(upstream!.headers['content-type'], 'application/json');

    final expected =
        'Basic ${base64Encode(utf8.encode('user@example.com:cryptpw_abc123'))}';
    expect(upstream!.headers['authorization'], expected);
  });

  test('write-scoped token forwards body bytes without content-type', () async {
    await linkAccount();
    registerWriteToken();
    final app = Router().plus;
    final proxy = DecentProxyService(
      requireConsent: (_) async => true,
      httpClient: http_testing.MockClient((request) async {
        upstream = request;
        return http.Response('SN001\nSN002', 200);
      }),
      credentialStore: store,
    );
    AccountProxyHandler(proxy: proxy, enableWrites: true).addRoutes(app);
    handler = const Pipeline()
        .addMiddleware(proxyAuthMiddleware(tokens))
        .addHandler(app.call);

    final response = await send(
      'POST',
      '/api/v1/account/proxy/support/api/upload',
      token: 'write-token',
      bodyBytes: [0, 1, 2, 255],
    );

    expect(response.statusCode, 200);
    expect(upstream, isNotNull);
    expect(upstream!.bodyBytes, [0, 1, 2, 255]);
    expect(upstream!.headers.containsKey('content-type'), isFalse);
  });

  test('write-scoped token forwards PUT body and content-type', () async {
    await linkAccount();
    registerWriteToken();
    final app = Router().plus;
    final proxy = DecentProxyService(
      requireConsent: (_) async => true,
      httpClient: http_testing.MockClient((request) async {
        upstream = request;
        return http.Response('SN001\nSN002', 200);
      }),
      credentialStore: store,
    );
    AccountProxyHandler(proxy: proxy, enableWrites: true).addRoutes(app);
    handler = const Pipeline()
        .addMiddleware(proxyAuthMiddleware(tokens))
        .addHandler(app.call);

    final response = await send(
      'PUT',
      '/api/v1/account/proxy/support/api/profile',
      token: 'write-token',
      body: 'name=rea',
      contentType: 'application/x-www-form-urlencoded',
    );

    expect(response.statusCode, 200);
    expect(upstream, isNotNull);
    expect(upstream!.method, 'PUT');
    expect(upstream!.body, 'name=rea');
    expect(
      upstream!.headers['content-type'],
      'application/x-www-form-urlencoded',
    );
  });
}
