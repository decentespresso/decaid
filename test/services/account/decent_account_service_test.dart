import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:reaprime/src/services/account/decent_account_service.dart';

/// In-memory fake for testing — no flutter_secure_storage dependency.
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

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const _baseUrl = 'https://decentespresso.com';

http_testing.MockClient _mockClient({
  required int statusCode,
  required String body,
}) {
  return http_testing.MockClient((request) async {
    return http.Response(body, statusCode);
  });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('DecentAccountService', () {
    late FakeCredentialStore store;
    late http_testing.MockClient httpClient;
    late DecentAccountService service;

    setUp(() {
      store = FakeCredentialStore();
      httpClient = _mockClient(statusCode: 200, body: 'cryptpw_abc123');
      service = DecentAccountService(
        httpClient: httpClient,
        credentialStore: store,
        baseUrl: _baseUrl,
      );
    });

    group('login', () {
      late http.BaseRequest capturedRequest;

      /// Helper that builds a service whose MockClient captures the request
      /// and returns [statusCode]/[body], then asserts on [capturedRequest]
      /// after the async call completes.
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

      test('returns false when API responds with "0"', () async {
        httpClient = _mockClient(statusCode: 200, body: '0');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        final result = await service.login('test@example.com', 'wrong');
        expect(result, isFalse);
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
        // Stores the encrypted password returned by the API, not the plaintext.
        expect(await store.read(key: 'password'), 'cryptpw_abc123');
      });

      test('does NOT persist credentials on failed login', () async {
        httpClient = _mockClient(statusCode: 200, body: '0');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        await service.login('test@example.com', 'wrong');
        expect(store.hasCredentials, isFalse);
      });

      test('sends correctly-encoded Basic Auth header', () async {
        // base64("test@example.com:hunter2") = "dGVzdEBleGFtcGxlLmNvbTpodW50ZXIy"
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

      test('returns true when credentials are already stored from a '
          'previous session', () async {
        await store.write(key: 'email', value: 'returning@example.com');
        await store.write(key: 'password', value: 'oldpassword');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        expect(await service.isLoggedIn(), isTrue);
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
          // base64("test@example.com:cryptpw_abc123")
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

    group('verifyMachineSerial', () {
      test('returns true when serial is in account serials', () async {
        httpClient = _mockClient(statusCode: 200, body: 'DE1-0001\nDE1-0042');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );
        await store.write(key: 'email', value: 'test@example.com');
        await store.write(key: 'password', value: 'cryptpw_abc123');

        final result = await service.verifyMachineSerial('DE1-0042');
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
