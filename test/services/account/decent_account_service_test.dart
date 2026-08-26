import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:reaprime/src/services/account/decent_account_service.dart';

class FakeCredentialStore implements CredentialStore {
  final Map<String, String> _store = {};

  @override
  Future<String?> read({required String key}) async => _store[key];

  @override
  Future<void> write({required String key, required String value}) async {
    _store[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    _store.remove(key);
  }

  bool get hasCredentials =>
      _store.containsKey('email') && _store.containsKey('password');
}

const _baseUrl = 'https://decentespresso.com';

http_testing.MockClient _mockClient({
  required int statusCode,
  required String body,
}) {
  return http_testing.MockClient((request) async {
    return http.Response(body, statusCode);
  });
}

void main() {
  group('DecentAccountService', () {
    late FakeCredentialStore store;
    late http_testing.MockClient httpClient;
    late DecentAccountService service;

    setUp(() {
      store = FakeCredentialStore();
      httpClient = _mockClient(statusCode: 200, body: 'cryptpw_abc123\n');
      service = DecentAccountService(
        httpClient: httpClient,
        credentialStore: store,
        baseUrl: _baseUrl,
      );
    });

    group('login', () {
      late http.BaseRequest capturedRequest;

      DecentAccountService serviceWithCapture({
        required int statusCode,
        required String body,
      }) {
        final client = http_testing.MockClient((request) async {
          capturedRequest = request;
          return http.Response(body, statusCode);
        });
        return DecentAccountService(
          httpClient: client,
          credentialStore: store,
          baseUrl: _baseUrl,
        );
      }

      setUp(() {
        capturedRequest = http.Request('GET', Uri.parse('about:blank'));
      });
      test('returns true when API responds with encrypted password', () async {
        final result = await service.login('test@example.com', 'hunter2');
        expect(result, isTrue);
      });

      test('returns false when API responds with "0" (real backend sends '
          '"0\\n")', () async {
        httpClient = _mockClient(statusCode: 200, body: '0\n');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        final result = await service.login('test@example.com', 'wrong');
        expect(result, isFalse);
        expect(store.hasCredentials, isFalse);
      });

      test('returns false when API returns non-200 status', () async {
        httpClient = _mockClient(statusCode: 500, body: '');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        final result = await service.login('test@example.com', 'hunter2');
        expect(result, isFalse);
      });

      test('returns false when network error occurs', () async {
        httpClient = http_testing.MockClient(
          (_) async => throw Exception('SocketException'),
        );
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        expect(
          () async => await service.login('test@example.com', 'hunter2'),
          throwsA(isA<Exception>()),
        );
      });

      test('persists encrypted password on successful login', () async {
        await service.login('test@example.com', 'hunter2');
        expect(await store.read(key: 'email'), 'test@example.com');
        expect(await store.read(key: 'password'), 'cryptpw_abc123');
      });

      test('does NOT persist credentials on failed login', () async {
        httpClient = _mockClient(statusCode: 200, body: '0\n');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        await service.login('test@example.com', 'wrong');
        expect(store.hasCredentials, isFalse);
      });

      test('failed replacement login preserves previously valid stored '
          'credentials', () async {
        await store.write(key: 'email', value: 'good@example.com');
        await store.write(key: 'password', value: 'cryptpw_abc123');
        final badAuth = base64Encode(utf8.encode('bad@example.com:wrongpw'));
        httpClient = http_testing.MockClient((request) async {
          if (request.headers['authorization'] == 'Basic $badAuth') {
            return http.Response('0\n', 200);
          }
          return http.Response('cryptpw_abc123\n', 200);
        });
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        final ok = await service.login('bad@example.com', 'wrongpw');
        expect(ok, isFalse);
        expect(await store.read(key: 'email'), 'good@example.com');
        expect(await store.read(key: 'password'), 'cryptpw_abc123');
        expect(await service.isLoggedIn(), isTrue);
      });

      test('sends correctly-encoded Basic Auth header', () async {
        const expectedAuth = 'Basic dGVzdEBleGFtcGxlLmNvbTpodW50ZXIy';
        final s = serviceWithCapture(statusCode: 200, body: 'cryptpw_abc123');

        await s.login('test@example.com', 'hunter2');

        expect(capturedRequest.headers['authorization'], expectedAuth);
      });

      test('sends Basic Auth header to /support/api/login_test', () async {
        final s = serviceWithCapture(statusCode: 200, body: 'cryptpw_abc123');

        await s.login('test@example.com', 'hunter2');

        expect(
          capturedRequest.url.toString(),
          '$_baseUrl/support/api/login_test',
        );
        expect(capturedRequest.headers['authorization'], isNotNull);
        expect(capturedRequest.headers['authorization']!, startsWith('Basic '));
        expect(capturedRequest.method, 'GET');
      });
    });

    group('logout', () {
      test('clears persisted credentials', () async {
        await service.login('test@example.com', 'hunter2');
        expect(store.hasCredentials, isTrue);

        await service.logout();
        expect(store.hasCredentials, isFalse);
      });

      test('isLoggedIn returns false after logout', () async {
        await service.login('test@example.com', 'hunter2');
        await service.logout();
        expect(await service.isLoggedIn(), isFalse);
      });
    });

    group('isLoggedIn', () {
      test('returns false when no credentials stored', () async {
        expect(await service.isLoggedIn(), isFalse);
      });

      test('returns true after successful login', () async {
        await service.login('test@example.com', 'hunter2');
        expect(await service.isLoggedIn(), isTrue);
      });

      test(
        'returns true when stored credentials validate against the backend',
        () async {
          await store.write(key: 'email', value: 'returning@example.com');
          await store.write(key: 'password', value: 'cryptpw_abc123');
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: store,
            baseUrl: _baseUrl,
          );

          expect(await service.isLoggedIn(), isTrue);
        },
      );

      test('returns false when stored credentials are stale', () async {
        await store.write(key: 'email', value: 'returning@example.com');
        await store.write(key: 'password', value: 'stale_cryptpw');
        httpClient = _mockClient(statusCode: 401, body: '');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        expect(await service.isLoggedIn(), isFalse);
      });

      test('validates only once per session', () async {
        var calls = 0;
        httpClient = http_testing.MockClient((request) async {
          calls++;
          return http.Response('cryptpw_abc123', 200);
        });
        await store.write(key: 'email', value: 'returning@example.com');
        await store.write(key: 'password', value: 'cryptpw_abc123');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        expect(await service.isLoggedIn(), isTrue);
        expect(await service.isLoggedIn(), isTrue);
        expect(calls, 1);
      });

      test(
        'retries validation after an indeterminate network failure',
        () async {
          var calls = 0;
          httpClient = http_testing.MockClient((request) async {
            calls++;
            if (calls == 1) throw Exception('SocketException');
            return http.Response('cryptpw_abc123\n', 200);
          });
          await store.write(key: 'email', value: 'returning@example.com');
          await store.write(key: 'password', value: 'cryptpw_abc123');
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: store,
            baseUrl: _baseUrl,
            retryInterval: Duration.zero,
          );

          expect(await service.isLoggedIn(), isFalse);
          expect(await service.isLoggedIn(), isTrue);
          expect(calls, 2);
        },
      );

      test('throttles retries after an indeterminate failure', () async {
        var calls = 0;
        httpClient = http_testing.MockClient((request) async {
          calls++;
          throw Exception('SocketException');
        });
        await store.write(key: 'email', value: 'returning@example.com');
        await store.write(key: 'password', value: 'cryptpw_abc123');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        expect(await service.isLoggedIn(), isFalse);
        expect(await service.isLoggedIn(), isFalse);
        expect(calls, 1);
      });

      test('does not retry after a definitive rejection', () async {
        var calls = 0;
        httpClient = http_testing.MockClient((request) async {
          calls++;
          return http.Response('0\n', 200);
        });
        await store.write(key: 'email', value: 'returning@example.com');
        await store.write(key: 'password', value: 'stale_cryptpw');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        expect(await service.isLoggedIn(), isFalse);
        expect(await service.isLoggedIn(), isFalse);
        expect(calls, 1);
      });

      test(
        'returns false after reportAuthenticationFailure but keeps the link',
        () async {
          await service.login('test@example.com', 'hunter2');
          expect(await service.isLoggedIn(), isTrue);

          service.reportAuthenticationFailure();

          expect(await service.isLoggedIn(), isFalse);
          expect(await service.hasLinkedAccount(), isTrue);
          expect(await store.read(key: 'email'), 'test@example.com');
        },
      );
    });

    group('hasLinkedAccount', () {
      test('returns false when no credentials stored', () async {
        expect(await service.hasLinkedAccount(), isFalse);
      });

      test('returns false when only an email is stored', () async {
        await store.write(key: 'email', value: 'user@example.com');
        expect(await service.hasLinkedAccount(), isFalse);
      });

      test('returns true when email and password are stored', () async {
        await store.write(key: 'email', value: 'user@example.com');
        await store.write(key: 'password', value: 'cryptpw_abc123');
        expect(await service.hasLinkedAccount(), isTrue);
      });

      test('returns false after logout', () async {
        await store.write(key: 'email', value: 'user@example.com');
        await store.write(key: 'password', value: 'cryptpw_abc123');
        await service.logout();
        expect(await service.hasLinkedAccount(), isFalse);
      });
    });

    group('verifyStoredCredentials', () {
      test('returns true when backend accepts stored credentials', () async {
        await store.write(key: 'email', value: 'user@example.com');
        await store.write(key: 'password', value: 'cryptpw_abc123');

        expect(await service.verifyStoredCredentials(), isTrue);
        expect(await service.isLoggedIn(), isTrue);
      });

      test(
        'returns false on a 401 and marks the account not authenticated',
        () async {
          httpClient = _mockClient(statusCode: 401, body: '');
          await store.write(key: 'email', value: 'user@example.com');
          await store.write(key: 'password', value: 'stale_cryptpw');
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: store,
            baseUrl: _baseUrl,
          );

          expect(await service.verifyStoredCredentials(), isFalse);
          expect(await service.isLoggedIn(), isFalse);
          expect(await service.hasLinkedAccount(), isTrue);
        },
      );

      test('returns false when login_test responds with "0"', () async {
        httpClient = _mockClient(statusCode: 200, body: '0\n');
        await store.write(key: 'email', value: 'user@example.com');
        await store.write(key: 'password', value: 'stale_cryptpw');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        expect(await service.verifyStoredCredentials(), isFalse);
      });

      test('does not clear auth state on a transient server error', () async {
        await service.login('test@example.com', 'hunter2');
        expect(await service.isLoggedIn(), isTrue);
        httpClient = _mockClient(statusCode: 500, body: '');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        expect(await service.verifyStoredCredentials(), isFalse);
        expect(store.hasCredentials, isTrue);
      });

      test('does not clear auth state on a network error', () async {
        await store.write(key: 'email', value: 'user@example.com');
        await store.write(key: 'password', value: 'cryptpw_abc123');
        httpClient = http_testing.MockClient(
          (_) async => throw Exception('SocketException'),
        );
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        expect(await service.verifyStoredCredentials(), isFalse);
        expect(store.hasCredentials, isTrue);
      });
    });

    group('concurrent auth updates', () {
      test(
        'stale validation does not clobber a newer successful login',
        () async {
          final completer = Completer<http.Response>();
          final oldAuth = base64Encode(
            utf8.encode('old@example.com:stale_cryptpw'),
          );
          httpClient = http_testing.MockClient((request) {
            if (request.headers['authorization'] == 'Basic $oldAuth') {
              return completer.future;
            }
            return Future.value(http.Response('newcryptpw\n', 200));
          });
          await store.write(key: 'email', value: 'old@example.com');
          await store.write(key: 'password', value: 'stale_cryptpw');
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: store,
            baseUrl: _baseUrl,
          );

          final staleValidation = service.verifyStoredCredentials();

          expect(await service.login('new@example.com', 'goodpw'), isTrue);
          expect(await service.isLoggedIn(), isTrue);

          completer.complete(http.Response('0\n', 200));
          expect(await staleValidation, isTrue);
          expect(await service.isLoggedIn(), isTrue);
          expect(await store.read(key: 'email'), 'new@example.com');
        },
      );

      test('in-flight validation does not resurrect auth after an upstream '
          'failure', () async {
        final completer = Completer<http.Response>();
        httpClient = http_testing.MockClient((_) => completer.future);
        await store.write(key: 'email', value: 'user@example.com');
        await store.write(key: 'password', value: 'cryptpw_abc123');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        final validation = service.verifyStoredCredentials();
        service.reportAuthenticationFailure();

        completer.complete(http.Response('cryptpw_abc123\n', 200));
        expect(await validation, isFalse);
        expect(await service.isLoggedIn(), isFalse);
      });
    });

    group('fetchSerialNumbers', () {
      late http.BaseRequest capturedRequest;

      DecentAccountService serviceWithCapture({
        required int statusCode,
        required String body,
      }) {
        final client = http_testing.MockClient((request) async {
          capturedRequest = request;
          return http.Response(body, statusCode);
        });
        return DecentAccountService(
          httpClient: client,
          credentialStore: store,
          baseUrl: _baseUrl,
        );
      }

      setUp(() {
        capturedRequest = http.Request('GET', Uri.parse('about:blank'));
      });

      test(
        'calls /support/api/sn?onlyespressomachines=1 with Basic Auth from stored credentials',
        () async {
          const expectedAuth =
              'Basic dGVzdEBleGFtcGxlLmNvbTpjcnlwdHB3X2FiYzEyMw==';
          final s = serviceWithCapture(statusCode: 200, body: 'DE1-0001');
          await store.write(key: 'email', value: 'test@example.com');
          await store.write(key: 'password', value: 'cryptpw_abc123');

          await s.fetchSerialNumbers();

          expect(
            capturedRequest.url.toString(),
            '$_baseUrl/support/api/sn?onlyespressomachines=1',
          );
          expect(capturedRequest.headers['authorization'], expectedAuth);
          expect(capturedRequest.method, 'GET');
        },
      );

      test('returns parsed list of serials', () async {
        httpClient = _mockClient(statusCode: 200, body: 'DE1-0001\nDE1-0042');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );
        await store.write(key: 'email', value: 'test@example.com');
        await store.write(key: 'password', value: 'cryptpw_abc123');

        final serials = await service.fetchSerialNumbers();
        expect(serials, ['DE1-0001', 'DE1-0042']);
      });

      test('parses SKU-annotated response from the real backend', () async {
        httpClient = _mockClient(
          statusCode: 200,
          body:
              '1337 DE-BE1BENGLE220V_15A_3000W_B0-01101\n'
              '1338 DE-DE1PRO220V7-00533',
        );
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );
        await store.write(key: 'email', value: 'test@example.com');
        await store.write(key: 'password', value: 'cryptpw_abc123');

        final serials = await service.fetchSerialNumbers();
        expect(serials, ['1337', '1338']);
      });

      test('returns empty list when API responds with empty body', () async {
        httpClient = _mockClient(statusCode: 200, body: '');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );
        await store.write(key: 'email', value: 'test@example.com');
        await store.write(key: 'password', value: 'cryptpw_abc123');

        final serials = await service.fetchSerialNumbers();
        expect(serials, isEmpty);
      });

      test('throws on network error', () async {
        httpClient = http_testing.MockClient(
          (_) async => throw Exception('timeout'),
        );
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );
        await store.write(key: 'email', value: 'test@example.com');
        await store.write(key: 'password', value: 'cryptpw_abc123');

        expect(() => service.fetchSerialNumbers(), throwsA(isA<Exception>()));
      });

      test('throws when not logged in', () async {
        expect(() => service.fetchSerialNumbers(), throwsA(isA<StateError>()));
      });
    });

    group('parseSerialNumbers', () {
      test('parses bare serial numbers', () {
        expect(parseSerialNumbers('1337\n1338'), ['1337', '1338']);
      });

      test('parses serials with SKU metadata', () {
        expect(
          parseSerialNumbers(
            '1337 DE-BE1BENGLE220V_15A_3000W_B0-01101\n'
            '1338 DE-DE1PRO220V7-00533',
          ),
          ['1337', '1338'],
        );
      });

      test('handles CRLF responses', () {
        expect(parseSerialNumbers('1337\r\n1338\r\n'), ['1337', '1338']);
      });

      test('handles CR-only responses', () {
        expect(parseSerialNumbers('1337\r1338\r'), ['1337', '1338']);
      });

      test('ignores blank lines and surrounding whitespace', () {
        expect(
          parseSerialNumbers(
            '  1337   DE-BE1BENGLE220V_15A_3000W_B0-01101  \n\n'
            '   1338   DE-DE1PRO220V7-00533   ',
          ),
          ['1337', '1338'],
        );
      });

      test('deduplicates serial numbers', () {
        expect(parseSerialNumbers('1337\n1337 DE-SOMETHING'), ['1337']);
      });
    });

    group('verifyMachineSerial', () {
      test('returns true when serial is in account serials', () async {
        httpClient = _mockClient(
          statusCode: 200,
          body:
              '1337 DE-BE1BENGLE220V_15A_3000W_B0-01101\n'
              '1338 DE-DE1PRO220V7-00533',
        );
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );
        await store.write(key: 'email', value: 'test@example.com');
        await store.write(key: 'password', value: 'cryptpw_abc123');

        final result = await service.verifyMachineSerial('1338');
        expect(result, isTrue);
      });

      test('returns false when serial is not in account serials', () async {
        httpClient = _mockClient(statusCode: 200, body: 'DE1-0001');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );
        await store.write(key: 'email', value: 'test@example.com');
        await store.write(key: 'password', value: 'cryptpw_abc123');

        final result = await service.verifyMachineSerial('DE1-9999');
        expect(result, isFalse);
      });

      test('throws when not logged in', () async {
        expect(
          () => service.verifyMachineSerial('DE1-0001'),
          throwsA(isA<StateError>()),
        );
      });
    });
  });
}
