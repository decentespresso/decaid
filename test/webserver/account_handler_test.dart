import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/webserver_service.dart';
import 'package:shelf_plus/shelf_plus.dart';

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

void main() {
  late FakeCredentialStore store;
  late DecentAccountService service;
  late http_testing.MockClientHandler httpHandler;
  late Handler handler;

  setUp(() {
    store = FakeCredentialStore();
    httpHandler = (request) async {
      fail('AccountHandler must not make network requests: ${request.url}');
    };
    service = DecentAccountService(
      httpClient: http_testing.MockClient((request) => httpHandler(request)),
      credentialStore: store,
    );
    final app = Router().plus;
    AccountHandler(accountService: service).addRoutes(app);
    handler = app.call;
  });

  Future<Response> sendGet(String path) async {
    return handler(Request('GET', Uri.parse('http://localhost$path')));
  }

  Future<Response> sendPost(String path, Map<String, dynamic> body) async {
    return handler(
      Request(
        'POST',
        Uri.parse('http://localhost$path'),
        body: jsonEncode(body),
        headers: {'content-type': 'application/json'},
      ),
    );
  }

  Future<Response> sendDelete(String path) async {
    return handler(Request('DELETE', Uri.parse('http://localhost$path')));
  }

  test('status reports an unlinked Decent account by default', () async {
    final response = await sendGet('/api/v1/account/decent');
    expect(response.statusCode, 200);
    final body = jsonDecode(await response.readAsString());
    expect(body['loggedIn'], false);
  });

  test('status reports authenticated for stored valid credentials', () async {
    await store.write(key: 'email', value: 'user@example.com');
    await store.write(key: 'password', value: 'cryptpw_abc123');
    httpHandler = (request) async => http.Response('cryptpw_abc123', 200);

    final response = await sendGet('/api/v1/account/decent');
    expect(response.statusCode, 200);
    final body = jsonDecode(await response.readAsString()) as Map;
    expect(body['loggedIn'], true);
    expect(body.containsKey('email'), isFalse);
  });

  test(
    'status reports not authenticated for stale stored credentials',
    () async {
      await store.write(key: 'email', value: 'user@example.com');
      await store.write(key: 'password', value: 'stale_cryptpw');
      httpHandler = (request) async => http.Response('', 401);

      final response = await sendGet('/api/v1/account/decent');
      expect(response.statusCode, 200);
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['loggedIn'], false);
    },
  );

  test(
    'status reports not authenticated after an upstream auth failure',
    () async {
      await store.write(key: 'email', value: 'user@example.com');
      await store.write(key: 'password', value: 'cryptpw_abc123');
      httpHandler = (request) async => http.Response('cryptpw_abc123', 200);
      final first = jsonDecode(
        await (await sendGet('/api/v1/account/decent')).readAsString(),
      );
      expect(first, containsPair('loggedIn', true));

      service.reportAuthenticationFailure();

      final response = await sendGet('/api/v1/account/decent');
      final body = jsonDecode(await response.readAsString()) as Map;
      expect(body['loggedIn'], false);
    },
  );

  test('login is not exposed over HTTP', () async {
    final response = await sendPost('/api/v1/account/decent/login', {
      'email': 'user@example.com',
      'password': 'secret',
    });
    expect(response.statusCode, 404);
    expect(await store.read(key: 'email'), isNull);
  });

  test('logout is not exposed over HTTP', () async {
    await store.write(key: 'email', value: 'user@example.com');

    final response = await sendDelete('/api/v1/account/decent');
    expect(response.statusCode, 404);
    expect(await store.read(key: 'email'), 'user@example.com');
  });
}
