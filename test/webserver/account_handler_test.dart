import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
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
  late Handler handler;

  setUp(() {
    store = FakeCredentialStore();
    final service = DecentAccountService(
      httpClient: http_testing.MockClient((request) async {
        fail('AccountHandler must not make network requests: ${request.url}');
      }),
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

  test('status reports a linked account without leaking the email', () async {
    await store.write(key: 'email', value: 'user@example.com');
    await store.write(key: 'password', value: 'cryptpw_abc123');

    final response = await sendGet('/api/v1/account/decent');
    expect(response.statusCode, 200);
    final body = jsonDecode(await response.readAsString()) as Map;
    expect(body['loggedIn'], true);
    // Email is PII and the endpoint is unauthenticated — never include it.
    expect(body.containsKey('email'), isFalse);
  });

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
