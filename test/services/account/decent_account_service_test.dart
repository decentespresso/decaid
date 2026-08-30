import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart' as http_testing;
import 'package:reaprime/src/services/account/decent_account_service.dart';

class FakeCredentialStore implements CredentialStore {
  final Map<String, String> _store = {};
  String? failingReadKey;
  int? remainingReadFailures;
  String? failingWriteKey;
  int? remainingWriteFailures;
  String? failingDeleteKey;

  @override
  Future<String?> read({required String key}) async {
    if (key == failingReadKey &&
        (remainingReadFailures == null || remainingReadFailures! > 0)) {
      if (remainingReadFailures != null) {
        remainingReadFailures = remainingReadFailures! - 1;
      }
      throw StateError('read failed: $key');
    }
    return _store[key];
  }

  @override
  Future<void> write({required String key, required String value}) async {
    if (key == failingWriteKey &&
        (remainingWriteFailures == null || remainingWriteFailures! > 0)) {
      if (remainingWriteFailures != null) {
        remainingWriteFailures = remainingWriteFailures! - 1;
      }
      throw StateError('write failed: $key');
    }
    _store[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    if (key == failingDeleteKey) throw StateError('delete failed: $key');
    _store.remove(key);
  }

  bool get hasCredentials =>
      _store.containsKey('email') && _store.containsKey('password');
}

class _GateFirstEmailReadStore implements CredentialStore {
  final CredentialStore _inner;
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  bool _gated = false;

  _GateFirstEmailReadStore(this._inner);

  @override
  Future<String?> read({required String key}) async {
    final value = await _inner.read(key: key);
    if (!_gated && key == 'email') {
      _gated = true;
      started.complete();
      await release.future;
    }
    return value;
  }

  @override
  Future<void> write({required String key, required String value}) =>
      _inner.write(key: key, value: value);

  @override
  Future<void> delete({required String key}) => _inner.delete(key: key);
}

class _GateFirstMachinesWriteStore implements CredentialStore {
  final CredentialStore _inner;
  final Completer<void> gate = Completer<void>();
  bool _gated = false;

  _GateFirstMachinesWriteStore(this._inner);

  @override
  Future<String?> read({required String key}) => _inner.read(key: key);

  @override
  Future<void> write({required String key, required String value}) async {
    if (!_gated && key == 'registered_machines') {
      _gated = true;
      await gate.future;
    }
    await _inner.write(key: key, value: value);
  }

  @override
  Future<void> delete({required String key}) => _inner.delete(key: key);
}

class _GateEmailDeleteStore implements CredentialStore {
  final CredentialStore _inner;
  final Completer<void> gate = Completer<void>();
  bool _gated = false;

  _GateEmailDeleteStore(this._inner);

  @override
  Future<String?> read({required String key}) => _inner.read(key: key);

  @override
  Future<void> write({required String key, required String value}) =>
      _inner.write(key: key, value: value);

  @override
  Future<void> delete({required String key}) async {
    if (!_gated && key == 'email') {
      _gated = true;
      await gate.future;
    }
    await _inner.delete(key: key);
  }
}

class _GateFirstMachinesDeleteStore implements CredentialStore {
  final CredentialStore _inner;
  final Completer<void> started = Completer<void>();
  final Completer<void> gate = Completer<void>();
  bool _gated = false;

  _GateFirstMachinesDeleteStore(this._inner);

  @override
  Future<String?> read({required String key}) => _inner.read(key: key);

  @override
  Future<void> write({required String key, required String value}) =>
      _inner.write(key: key, value: value);

  @override
  Future<void> delete({required String key}) async {
    if (!_gated && key == 'registered_machines') {
      _gated = true;
      started.complete();
      await gate.future;
    }
    await _inner.delete(key: key);
  }
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
          if (capturedRequest.url.toString() == 'about:blank') {
            capturedRequest = request;
          }
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

      test('returns false when API returns an empty token', () async {
        httpClient = _mockClient(statusCode: 200, body: '');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        expect(await service.login('test@example.com', 'hunter2'), isFalse);
        expect(store.hasCredentials, isFalse);
      });

      test(
        'returns false when the machine refresh rejects the token',
        () async {
          httpClient = http_testing.MockClient((request) async {
            if (request.url.path == '/support/api/login_test') {
              return http.Response('cryptpw_abc123\n', 200);
            }
            return http.Response('unauthorized', 401);
          });
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: store,
            baseUrl: _baseUrl,
          );

          expect(await service.login('test@example.com', 'hunter2'), isFalse);
          expect(await service.isAuthKnownInvalid(), isTrue);
        },
      );

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
        var loginCalls = 0;
        httpClient = http_testing.MockClient((request) async {
          if (request.url.path == '/support/api/login_test') loginCalls++;
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
        expect(loginCalls, 1);
      });

      test(
        'retries validation after an indeterminate network failure',
        () async {
          var loginCalls = 0;
          httpClient = http_testing.MockClient((request) async {
            if (request.url.path != '/support/api/login_test') {
              return http.Response('cryptpw_abc123\n', 200);
            }
            loginCalls++;
            if (loginCalls == 1) throw Exception('SocketException');
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
          expect(loginCalls, 2);
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

      test(
        'validation cleanup does not leak a credential read error',
        () async {
          final uncaughtErrors = <Object>[];
          await store.write(key: 'email', value: 'returning@example.com');
          await store.write(key: 'password', value: 'cryptpw_abc123');
          store.failingReadKey = 'email';
          store.remainingReadFailures = 0;

          await runZonedGuarded(() async {
            final validation = service.isLoggedIn();
            store.remainingReadFailures = 1;
            await expectLater(validation, throwsStateError);
            await pumpEventQueue();
          }, (error, _) => uncaughtErrors.add(error));

          expect(uncaughtErrors, isEmpty);
        },
      );

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
      test('reports authenticated when backend accepts credentials', () async {
        await store.write(key: 'email', value: 'user@example.com');
        await store.write(key: 'password', value: 'cryptpw_abc123');

        expect(
          await service.verifyStoredCredentialsStatus(),
          DecentAccountStatus.authenticated,
        );
        expect(await service.isLoggedIn(), isTrue);
      });

      test(
        'reports unauthenticated on a 401 and marks the account invalid',
        () async {
          httpClient = _mockClient(statusCode: 401, body: '');
          await store.write(key: 'email', value: 'user@example.com');
          await store.write(key: 'password', value: 'stale_cryptpw');
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: store,
            baseUrl: _baseUrl,
          );

          expect(
            await service.verifyStoredCredentialsStatus(),
            DecentAccountStatus.unauthenticated,
          );
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

      test('returns false when login_test returns an empty token', () async {
        httpClient = _mockClient(statusCode: 200, body: '');
        await store.write(key: 'email', value: 'user@example.com');
        await store.write(key: 'password', value: 'cryptpw_abc123');
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

      test('reports an indeterminate status on a network error', () async {
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

        expect(
          await service.verifyStoredCredentialsStatus(),
          DecentAccountStatus.indeterminate,
        );
      });

      test('preserves known invalid status on a network error', () async {
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
        service.reportAuthenticationFailure();

        expect(
          await service.verifyStoredCredentialsStatus(),
          DecentAccountStatus.unauthenticated,
        );
      });
    });

    group('concurrent auth updates', () {
      test('logout invalidates a login still awaiting validation', () async {
        final loginStarted = Completer<void>();
        final loginRelease = Completer<void>();
        httpClient = http_testing.MockClient((request) async {
          if (request.url.path == '/support/api/login_test') {
            loginStarted.complete();
            await loginRelease.future;
            return http.Response('cryptpw_abc123\n', 200);
          }
          return http.Response('1338 DE-DE1PRO220V7-00533\n', 200);
        });
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        final login = service.login('user@example.com', 'hunter2');
        await loginStarted.future;
        await service.logout();
        loginRelease.complete();

        expect(await login, isFalse);
        expect(store.hasCredentials, isFalse);
        expect(service.usableRegisteredMachines, isEmpty);
      });

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

      test(
        'stale missing-credential validation does not hide a newer login',
        () async {
          final gatedStore = _GateFirstEmailReadStore(store);
          httpClient = http_testing.MockClient((request) async {
            if (request.url.path == '/support/api/sn') {
              return http.Response('1338 DE-DE1PRO220V7-00533\n', 200);
            }
            return http.Response('cryptpw_abc123\n', 200);
          });
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: gatedStore,
            baseUrl: _baseUrl,
          );

          final staleValidation = service.verifyStoredCredentialsStatus();
          await gatedStore.started.future;

          expect(await service.login('new@example.com', 'goodpw'), isTrue);
          expect(service.usableRegisteredMachines.map((m) => m.serial), [
            '1338',
          ]);

          gatedStore.release.complete();

          expect(await staleValidation, DecentAccountStatus.authenticated);
          expect(service.hasUsableAccountCache, isTrue);
          expect(service.usableRegisteredMachines.map((m) => m.serial), [
            '1338',
          ]);
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

    group('uploadAppLogs', () {
      test('stale rejection does not invalidate a newer login', () async {
        final uploadStarted = Completer<void>();
        final releaseUpload = Completer<void>();
        httpClient = http_testing.MockClient((request) async {
          if (request.method == 'POST') {
            uploadStarted.complete();
            await releaseUpload.future;
            return http.Response('', 401);
          }
          return http.Response('new_cryptpw', 200);
        });
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );
        await store.write(key: 'email', value: 'old@example.com');
        await store.write(key: 'password', value: 'old_cryptpw');

        final upload = service.uploadAppLogs(
          '{}',
          isAllowed: () => true,
          timeout: const Duration(seconds: 30),
        );
        await uploadStarted.future;
        expect(await service.login('new@example.com', 'new-password'), isTrue);
        releaseUpload.complete();

        expect((await upload).statusCode, 401);
        expect(await service.isAuthKnownInvalid(), isFalse);
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

      test('calls /support/api/sn?onlyespressomachines=1&withskus=1 with Basic '
          'Auth from stored credentials', () async {
        const expectedAuth =
            'Basic dGVzdEBleGFtcGxlLmNvbTpjcnlwdHB3X2FiYzEyMw==';
        final s = serviceWithCapture(statusCode: 200, body: 'DE1-0001');
        await store.write(key: 'email', value: 'test@example.com');
        await store.write(key: 'password', value: 'cryptpw_abc123');

        await s.fetchSerialNumbers();

        expect(
          capturedRequest.url.toString(),
          '$_baseUrl/support/api/sn?onlyespressomachines=1&withskus=1',
        );
        expect(capturedRequest.headers['authorization'], expectedAuth);
        expect(capturedRequest.method, 'GET');
      });

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

      test('a stale 401 does not invalidate a replacement login', () async {
        final staleRequestStarted = Completer<void>();
        final releaseStaleRequest = Completer<void>();
        var snCalls = 0;
        httpClient = http_testing.MockClient((request) async {
          if (request.url.path == '/support/api/login_test') {
            return http.Response('new_cryptpw\n', 200);
          }
          snCalls++;
          if (snCalls == 1) {
            staleRequestStarted.complete();
            await releaseStaleRequest.future;
            return http.Response('unauthorized', 401);
          }
          return http.Response('2222 DE-DE1PRO220V7-00533\n', 200);
        });
        await store.write(key: 'email', value: 'old@example.com');
        await store.write(key: 'password', value: 'old_cryptpw');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        final staleFetch = service.fetchSerialNumbers();
        await staleRequestStarted.future;
        expect(await service.login('new@example.com', 'new-password'), isTrue);
        releaseStaleRequest.complete();

        await expectLater(staleFetch, throwsException);
        expect(await service.isAuthKnownInvalid(), isFalse);
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

    group('sendSupportMessage', () {
      test(
        'sends an authenticated request and returns the contact id',
        () async {
          late http.Request capturedRequest;
          final client = http_testing.MockClient((request) async {
            capturedRequest = request;
            return http.Response('  GhwAHSEAAAAAAAAGBgAdAxAcCUgGCgQ=\n', 200);
          });
          final supportService = DecentAccountService(
            httpClient: client,
            credentialStore: store,
            baseUrl: _baseUrl,
          );
          await store.write(key: 'email', value: 'test@example.com');
          await store.write(key: 'password', value: 'cryptpw_abc123');

          final contactId = await supportService.sendSupportMessage(
            subject: 'Decaid feedback #728 & details',
            body: 'https://github.com/decentespresso/decaid/issues/728?a=1&b=2',
          );

          expect(contactId, 'GhwAHSEAAAAAAAAGBgAdAxAcCUgGCgQ=');
          expect(capturedRequest.method, 'GET');
          expect(capturedRequest.url.path, '/support/api/email');
          expect(capturedRequest.url.queryParameters, {
            'subject': 'Decaid feedback #728 & details',
            'body':
                'https://github.com/decentespresso/decaid/issues/728?a=1&b=2',
          });
          expect(
            capturedRequest.headers['authorization'],
            'Basic dGVzdEBleGFtcGxlLmNvbTpjcnlwdHB3X2FiYzEyMw==',
          );
        },
      );

      test('rejects failed and unsafe responses', () async {
        final responses = [
          (statusCode: 500, body: 'failed'),
          (statusCode: 200, body: ''),
          (statusCode: 200, body: '0'),
          (statusCode: 200, body: 'bad\ncontact'),
          (statusCode: 200, body: 'bad`contact'),
          (statusCode: 200, body: List.filled(257, 'x').join()),
        ];
        await store.write(key: 'email', value: 'test@example.com');
        await store.write(key: 'password', value: 'cryptpw_abc123');

        for (final response in responses) {
          final supportService = DecentAccountService(
            httpClient: _mockClient(
              statusCode: response.statusCode,
              body: response.body,
            ),
            credentialStore: store,
            baseUrl: _baseUrl,
          );

          await expectLater(
            supportService.sendSupportMessage(subject: 'subject', body: 'body'),
            throwsA(isA<Exception>()),
          );
        }
      });

      test('invalidates cached authentication after a 401', () async {
        var requestCount = 0;
        final supportService = DecentAccountService(
          httpClient: http_testing.MockClient((request) async {
            requestCount++;
            return switch (request.url.path) {
              '/support/api/login_test' => http.Response('cryptpw_abc123', 200),
              '/support/api/sn' => http.Response('', 200),
              '/support/api/email' => http.Response('unauthorized', 401),
              _ => http.Response('not found', 404),
            };
          }),
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        expect(
          await supportService.login('test@example.com', 'password'),
          isTrue,
        );
        await expectLater(
          supportService.sendSupportMessage(subject: 'subject', body: 'body'),
          throwsA(isA<Exception>()),
        );

        expect(await supportService.isLoggedIn(), isFalse);
        await expectLater(
          supportService.sendSupportMessage(subject: 'subject', body: 'body'),
          throwsA(isA<StateError>()),
        );
        expect(requestCount, 3);
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

    group('registered machines and identity mappings', () {
      http_testing.MockClient clientWithSn({required String snBody}) {
        return http_testing.MockClient((request) async {
          if (request.url.path == '/support/api/sn') {
            return http.Response(snBody, 200);
          }
          return http.Response('cryptpw_abc123\n', 200);
        });
      }

      Future<void> seedAccount(String email, String password) async {
        await store.write(key: 'email', value: email);
        await store.write(key: 'password', value: password);
      }

      Future<void> seedMachinesCache(
        List<Map<String, dynamic>> machines, {
        String account = 'user@example.com',
      }) async {
        await store.write(
          key: 'registered_machines',
          value: jsonEncode({'account': account, 'machines': machines}),
        );
      }

      test(
        'registered-machine fetch uses onlyespressomachines=1&withskus=1',
        () async {
          http.BaseRequest? captured;
          final client = http_testing.MockClient((request) async {
            if (request.url.path == '/support/api/sn') {
              captured = request;
              return http.Response('1338 DE-DE1PRO220V7-00533\n', 200);
            }
            return http.Response('cryptpw_abc123\n', 200);
          });
          await seedAccount('user@example.com', 'cryptpw_abc123');
          service = DecentAccountService(
            httpClient: client,
            credentialStore: store,
            baseUrl: _baseUrl,
          );

          await service.initialize();
          await pumpEventQueue();

          expect(
            captured?.url.toString(),
            '$_baseUrl/support/api/sn?onlyespressomachines=1&withskus=1',
          );
        },
      );

      test('successful login fetches and persists the machine list', () async {
        var snCalls = 0;
        httpClient = clientWithSn(snBody: '1338 DE-DE1PRO220V7-00533\n');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        final ok = await service.login('test@example.com', 'hunter2');

        expect(ok, isTrue);
        expect(snCalls, 0);
        expect(service.usableRegisteredMachines.map((m) => m.serial), ['1338']);
        expect(await store.read(key: 'registered_machines'), isNotNull);
      });

      test(
        'a machine-list fetch failure does not fail a valid login',
        () async {
          httpClient = http_testing.MockClient((request) async {
            if (request.url.path == '/support/api/sn') {
              throw Exception('timeout');
            }
            return http.Response('cryptpw_abc123\n', 200);
          });
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: store,
            baseUrl: _baseUrl,
          );

          final ok = await service.login('test@example.com', 'hunter2');

          expect(ok, isTrue);
          expect(await service.isLoggedIn(), isTrue);
        },
      );

      test('startup loads the cached machine list before refreshing', () async {
        var snCalls = 0;
        httpClient = http_testing.MockClient((request) async {
          if (request.url.path == '/support/api/sn') {
            snCalls++;
            return http.Response('1338 DE-DE1PRO220V7-00533\n', 200);
          }
          return http.Response('cryptpw_abc123\n', 200);
        });
        await seedAccount('user@example.com', 'cryptpw_abc123');
        await seedMachinesCache([
          {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
        ]);
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        await service.initialize();

        expect(service.usableRegisteredMachines.map((m) => m.serial), ['1337']);
        expect(snCalls, 0);

        await pumpEventQueue();

        expect(snCalls, 1);
        expect(service.usableRegisteredMachines.map((m) => m.serial), ['1338']);
      });

      test(
        'startup continues when linked credentials cannot be read',
        () async {
          store.failingReadKey = 'email';

          await expectLater(service.initialize(), completes);
          await pumpEventQueue();

          expect(service.hasUsableAccountCache, isFalse);
          expect(service.usableRegisteredMachines, isEmpty);
        },
      );

      test(
        'startup recovers after a transient credential read failure',
        () async {
          var snCalls = 0;
          httpClient = http_testing.MockClient((request) async {
            if (request.url.path == '/support/api/sn') {
              snCalls++;
              return http.Response('1338 DE-DE1PRO220V7-00533\n', 200);
            }
            return http.Response('cryptpw_abc123\n', 200);
          });
          await seedAccount('user@example.com', 'cryptpw_abc123');
          store.failingReadKey = 'email';
          store.remainingReadFailures = 1;
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: store,
            baseUrl: _baseUrl,
          );

          await service.initialize();
          await pumpEventQueue();

          expect(snCalls, 1);
          expect(service.usableRegisteredMachines.map((m) => m.serial), [
            '1338',
          ]);
        },
      );

      test(
        'accountReady retries an indeterminate linked-account read',
        () async {
          var snCalls = 0;
          httpClient = http_testing.MockClient((request) async {
            if (request.url.path == '/support/api/sn') {
              snCalls++;
              return http.Response('1338 DE-DE1PRO220V7-00533\n', 200);
            }
            return http.Response('cryptpw_abc123\n', 200);
          });
          await seedAccount('user@example.com', 'cryptpw_abc123');
          await seedMachinesCache([
            {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
          ]);
          store.failingReadKey = 'email';
          store.remainingReadFailures = 4;
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: store,
            baseUrl: _baseUrl,
          );

          await service.initialize();
          await pumpEventQueue();

          expect(snCalls, 0);
          expect(service.usableRegisteredMachines, isEmpty);

          await service.accountReady;
          await pumpEventQueue();

          expect(snCalls, 1);
          expect(service.usableRegisteredMachines.map((m) => m.serial), [
            '1338',
          ]);
        },
      );

      test(
        'accountReady retries a failed startup machine-cache read',
        () async {
          httpClient = http_testing.MockClient((request) async {
            if (request.url.path == '/support/api/login_test') {
              throw Exception('offline');
            }
            return http.Response('0\n', 200);
          });
          await seedAccount('user@example.com', 'cryptpw_abc123');
          await seedMachinesCache([
            {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
          ]);
          store.failingReadKey = 'registered_machines';
          store.remainingReadFailures = 2;
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: store,
            baseUrl: _baseUrl,
          );

          await service.initialize();
          await service.accountReady;

          expect(service.usableRegisteredMachines, isEmpty);

          await service.accountReady;

          expect(service.usableRegisteredMachines.map((m) => m.serial), [
            '1337',
          ]);
        },
      );

      test(
        'accountReady retries a failed startup mapping-cache read',
        () async {
          httpClient = http_testing.MockClient((request) async {
            if (request.url.path == '/support/api/sn') {
              return http.Response(
                '1337 DE-DE1220V-00001\n'
                '1338 DE-DE1PRO220V7-00533\n',
                200,
              );
            }
            return http.Response('cryptpw_abc123\n', 200);
          });
          await seedAccount('user@example.com', 'cryptpw_abc123');
          await seedMachinesCache([
            {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
            {
              'serial': '1338',
              'sku': 'DE-DE1PRO220V7-00533',
              'model': 'DE1Pro',
            },
          ]);
          await store.write(
            key: 'identity_mappings',
            value: jsonEncode({
              'account': 'user@example.com',
              'mappings': [
                {
                  'transportType': 'ble',
                  'deviceId': 'AA:BB:CC',
                  'serial': '1338',
                },
              ],
            }),
          );
          store.failingReadKey = 'identity_mappings';
          store.remainingReadFailures = 2;
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: store,
            baseUrl: _baseUrl,
          );

          await service.initialize();
          await service.accountReady;

          expect(
            await service.lookupMapping(
              transportType: 'ble',
              deviceId: 'AA:BB:CC',
            ),
            isNull,
          );

          await service.accountReady;

          expect(
            (await service.lookupMapping(
              transportType: 'ble',
              deviceId: 'AA:BB:CC',
            ))?.serial,
            '1338',
          );
        },
      );

      test(
        'confirmed credentials keep the offline cache usable after a transient '
        'validation failure',
        () async {
          var validationCalls = 0;
          httpClient = http_testing.MockClient((request) async {
            if (request.url.path == '/support/api/login_test') {
              validationCalls++;
              throw Exception('offline');
            }
            return http.Response('1338 DE-DE1PRO220V7-00533\n', 200);
          });
          await seedAccount('user@example.com', 'cryptpw_abc123');
          await seedMachinesCache([
            {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
          ]);
          store.failingReadKey = 'email';
          store.remainingReadFailures = 1;
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: store,
            baseUrl: _baseUrl,
          );

          await service.initialize();
          await pumpEventQueue();

          expect(validationCalls, 1);
          expect(service.usableRegisteredMachines.map((m) => m.serial), [
            '1337',
          ]);
        },
      );

      test(
        'an sn 401 revokes cache authority but keeps recovery data',
        () async {
          httpClient = http_testing.MockClient((request) async {
            if (request.url.path == '/support/api/sn') {
              return http.Response('unauthorized', 401);
            }
            return http.Response('cryptpw_abc123\n', 200);
          });
          await seedAccount('user@example.com', 'cryptpw_abc123');
          await seedMachinesCache([
            {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
          ]);
          await store.write(
            key: 'identity_mappings',
            value: jsonEncode({
              'account': 'user@example.com',
              'mappings': [
                {
                  'transportType': 'ble',
                  'deviceId': 'AA:BB:CC',
                  'serial': '1337',
                },
              ],
            }),
          );
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: store,
            baseUrl: _baseUrl,
          );

          await service.initialize();
          await pumpEventQueue();

          expect(await service.isAuthKnownInvalid(), isTrue);
          expect(service.usableRegisteredMachines, isEmpty);
          expect(
            await service.lookupMapping(
              transportType: 'ble',
              deviceId: 'AA:BB:CC',
            ),
            isNull,
          );
          expect(await store.read(key: 'registered_machines'), isNotNull);
        },
      );

      test('startup refresh only happens after credentials validate', () async {
        var snCalls = 0;
        httpClient = http_testing.MockClient((request) async {
          if (request.url.path == '/support/api/sn') {
            snCalls++;
            return http.Response('1338 DE-DE1PRO220V7-00533\n', 200);
          }
          return http.Response('0\n', 200); // login_test rejects
        });
        await seedAccount('user@example.com', 'stale_cryptpw');
        await seedMachinesCache([
          {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
        ]);
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        await service.initialize();
        await pumpEventQueue();

        expect(snCalls, 0);
        expect(await service.isLoggedIn(), isFalse);
        expect(service.usableRegisteredMachines, isEmpty);
      });

      test('transient fetch failure preserves the last good cache', () async {
        httpClient = http_testing.MockClient((request) async {
          if (request.url.path == '/support/api/sn') {
            throw Exception('timeout');
          }
          return http.Response('cryptpw_abc123\n', 200);
        });
        await seedAccount('user@example.com', 'cryptpw_abc123');
        await seedMachinesCache([
          {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
        ]);
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        await service.initialize();
        await pumpEventQueue();

        expect(service.usableRegisteredMachines.map((m) => m.serial), ['1337']);
        expect(await service.isLoggedIn(), isTrue);
      });

      test(
        'definitive rejection retains persisted data but makes it unusable',
        () async {
          httpClient = http_testing.MockClient((request) async {
            if (request.url.path == '/support/api/sn') {
              return http.Response('1338 DE-DE1PRO220V7-00533\n', 200);
            }
            return http.Response('0\n', 200); // login_test rejects
          });
          await seedAccount('user@example.com', 'stale_cryptpw');
          await seedMachinesCache([
            {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
          ]);
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: store,
            baseUrl: _baseUrl,
          );

          await service.initialize();
          await pumpEventQueue();

          expect(await service.isLoggedIn(), isFalse);
          expect(service.hasUsableAccountCache, isFalse);
          expect(service.usableRegisteredMachines, isEmpty);
          expect(
            await store.read(key: 'registered_machines'),
            isNotNull, // persisted recovery data retained
          );
        },
      );

      test('logout clears the scoped machine cache and mappings', () async {
        await seedAccount('user@example.com', 'cryptpw_abc123');
        await seedMachinesCache([
          {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
        ]);
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );
        await service.initialize();
        await service.saveMapping(
          transportType: 'ble',
          deviceId: 'AA:BB:CC',
          serial: '1337',
        );

        await service.logout();

        expect(service.usableRegisteredMachines, isEmpty);
        expect(service.hasUsableAccountCache, isFalse);
        expect(
          await service.lookupMapping(
            transportType: 'ble',
            deviceId: 'AA:BB:CC',
          ),
          isNull,
        );
        expect(await store.read(key: 'registered_machines'), isNull);
        expect(await store.read(key: 'identity_mappings'), isNull);
      });

      test(
        'logout removes credentials when scoped cache deletion fails',
        () async {
          await seedAccount('user@example.com', 'cryptpw_abc123');
          await seedMachinesCache([
            {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
          ]);
          store.failingDeleteKey = 'registered_machines';

          await expectLater(service.logout(), throwsStateError);

          expect(await store.read(key: 'email'), isNull);
          expect(await store.read(key: 'password'), isNull);
        },
      );

      test(
        'successful account replacement clears the previous scoped state',
        () async {
          final oldAuth = base64Encode(utf8.encode('old@example.com:oldcrypt'));
          httpClient = http_testing.MockClient((request) async {
            if (request.url.path == '/support/api/login_test') {
              if (request.headers['authorization'] == 'Basic $oldAuth') {
                return http.Response('0\n', 200);
              }
              return http.Response('newcrypt\n', 200);
            }
            return http.Response('0\n', 200);
          });
          await seedAccount('old@example.com', 'oldcrypt');
          await seedMachinesCache([
            {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
          ], account: 'old@example.com');
          await store.write(
            key: 'identity_mappings',
            value: jsonEncode({
              'account': 'old@example.com',
              'mappings': [
                {
                  'transportType': 'ble',
                  'deviceId': 'AA:BB:CC',
                  'serial': '1337',
                },
              ],
            }),
          );
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: store,
            baseUrl: _baseUrl,
          );
          await service.initialize();
          expect(
            (await service.lookupMapping(
              transportType: 'ble',
              deviceId: 'AA:BB:CC',
            ))?.serial,
            '1337',
          );

          final ok = await service.login('new@example.com', 'newpw');

          expect(ok, isTrue);
          expect(await store.read(key: 'email'), 'new@example.com');
          expect(service.usableRegisteredMachines, isEmpty);
          expect(await store.read(key: 'registered_machines'), isNull);
          expect(
            await service.lookupMapping(
              transportType: 'ble',
              deviceId: 'AA:BB:CC',
            ),
            isNull,
          );
        },
      );

      test(
        'failed replacement login preserves account data and cache',
        () async {
          final goodAuth = base64Encode(
            utf8.encode('good@example.com:cryptpw_abc123'),
          );
          httpClient = http_testing.MockClient((request) async {
            if (request.headers['authorization'] == 'Basic $goodAuth') {
              return http.Response('cryptpw_abc123\n', 200);
            }
            return http.Response('0\n', 200);
          });
          await seedAccount('good@example.com', 'cryptpw_abc123');
          await seedMachinesCache([
            {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
          ], account: 'good@example.com');
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: store,
            baseUrl: _baseUrl,
          );
          await service.initialize();

          final ok = await service.login('bad@example.com', 'wrongpw');

          expect(ok, isFalse);
          expect(await store.read(key: 'email'), 'good@example.com');
          expect(service.usableRegisteredMachines.map((m) => m.serial), [
            '1337',
          ]);
          expect(await store.read(key: 'registered_machines'), isNotNull);
        },
      );

      test('mapping round-trip persists across service instances', () async {
        await seedAccount('user@example.com', 'cryptpw_abc123');
        await seedMachinesCache([
          {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
          {'serial': '1338', 'sku': 'DE-DE1PRO220V7-00533', 'model': 'DE1Pro'},
        ]);
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );
        await service.initialize();

        await service.saveMapping(
          transportType: 'ble',
          deviceId: 'AA:BB:CC',
          serial: '1338',
        );
        await service.saveMapping(
          transportType: 'ble',
          deviceId: 'AA:BB:CC',
          serial: '1337', // replaces the earlier mapping for same device
        );

        expect(
          (await service.lookupMapping(
            transportType: 'ble',
            deviceId: 'AA:BB:CC',
          ))?.serial,
          '1337',
        );
        expect(
          await service.lookupMapping(
            transportType: 'wifi',
            deviceId: 'AA:BB:CC',
          ),
          isNull,
        );
        expect(
          await service.lookupMapping(
            transportType: 'ble',
            deviceId: 'DD:EE:FF',
          ),
          isNull,
        );

        final restarted = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );
        await restarted.initialize();
        expect(
          (await restarted.lookupMapping(
            transportType: 'ble',
            deviceId: 'AA:BB:CC',
          ))?.serial,
          '1337',
        );
      });

      test('failed mapping persistence does not publish the mapping', () async {
        httpClient = clientWithSn(snBody: '1338 DE-DE1PRO220V7-00533\n');
        await seedAccount('user@example.com', 'cryptpw_abc123');
        await seedMachinesCache([
          {'serial': '1338', 'sku': 'DE-DE1PRO220V7-00533', 'model': 'DE1Pro'},
        ]);
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );
        await service.initialize();
        await service.accountReady;
        store.failingWriteKey = 'identity_mappings';
        store.remainingWriteFailures = 1;

        await expectLater(
          service.saveMapping(
            transportType: 'ble',
            deviceId: 'AA:BB:CC',
            serial: '1338',
          ),
          throwsStateError,
        );

        expect(
          await service.lookupMapping(
            transportType: 'ble',
            deviceId: 'AA:BB:CC',
          ),
          isNull,
        );
      });

      test(
        'mappings are pruned when their serial leaves the account list',
        () async {
          httpClient = clientWithSn(snBody: '1338 DE-DE1PRO220V7-00533\n');
          await seedAccount('user@example.com', 'cryptpw_abc123');
          await seedMachinesCache([
            {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
            {
              'serial': '1338',
              'sku': 'DE-DE1PRO220V7-00533',
              'model': 'DE1Pro',
            },
          ]);
          await store.write(
            key: 'identity_mappings',
            value: jsonEncode({
              'account': 'user@example.com',
              'mappings': [
                {
                  'transportType': 'ble',
                  'deviceId': 'AA:BB:CC',
                  'serial': '1337', // not in the refreshed list
                },
              ],
            }),
          );
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: store,
            baseUrl: _baseUrl,
          );
          await service.initialize();

          await pumpEventQueue();

          expect(service.usableRegisteredMachines.map((m) => m.serial), [
            '1338',
          ]);
          expect(
            await service.lookupMapping(
              transportType: 'ble',
              deviceId: 'AA:BB:CC',
            ),
            isNull,
          );
        },
      );

      test('a failed mapping prune is persisted on the next refresh', () async {
        var snCalls = 0;
        httpClient = http_testing.MockClient((request) async {
          if (request.url.path == '/support/api/sn') {
            snCalls++;
            return http.Response('1338 DE-DE1PRO220V7-00533\n', 200);
          }
          return http.Response('cryptpw_abc123\n', 200);
        });
        await seedAccount('user@example.com', 'cryptpw_abc123');
        await seedMachinesCache([
          {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
          {'serial': '1338', 'sku': 'DE-DE1PRO220V7-00533', 'model': 'DE1Pro'},
        ]);
        await store.write(
          key: 'identity_mappings',
          value: jsonEncode({
            'account': 'user@example.com',
            'mappings': [
              {
                'transportType': 'ble',
                'deviceId': 'AA:BB:CC',
                'serial': '1337',
              },
            ],
          }),
        );
        store.failingWriteKey = 'identity_mappings';
        store.remainingWriteFailures = 1;
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        await service.initialize();
        await service.accountReady;

        expect(snCalls, 1);
        expect(
          (jsonDecode((await store.read(key: 'identity_mappings'))!)['mappings']
              as List),
          hasLength(1),
        );

        await service.accountReady;

        expect(snCalls, 2);
        expect(
          (jsonDecode((await store.read(key: 'identity_mappings'))!)['mappings']
              as List),
          isEmpty,
        );
      });

      test('hasUsableAccountCache stays false without linked credentials even '
          'with a cached machine list', () async {
        await seedMachinesCache([
          {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
        ]);
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        await service.initialize();

        expect(service.hasUsableAccountCache, isFalse);
        expect(service.usableRegisteredMachines, isEmpty);
      });

      test('a machine cache bound to another account is not loaded', () async {
        await seedAccount('user@example.com', 'cryptpw_abc123');
        await seedMachinesCache([
          {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
        ], account: 'other@example.com');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        await service.initialize();

        expect(service.usableRegisteredMachines, isEmpty);
      });

      test('a malformed machine cache is ignored', () async {
        await seedAccount('user@example.com', 'cryptpw_abc123');
        await store.write(key: 'registered_machines', value: '{not json');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );

        await service.initialize();

        expect(service.usableRegisteredMachines, isEmpty);
      });

      test(
        'a mapping persisted without an account binding is not loaded',
        () async {
          await seedAccount('user@example.com', 'cryptpw_abc123');
          await store.write(
            key: 'identity_mappings',
            value: jsonEncode({
              'mappings': [
                {
                  'transportType': 'ble',
                  'deviceId': 'AA:BB:CC',
                  'serial': '1337',
                },
              ],
            }),
          );
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: store,
            baseUrl: _baseUrl,
          );

          await service.initialize();

          expect(
            await service.lookupMapping(
              transportType: 'ble',
              deviceId: 'AA:BB:CC',
            ),
            isNull,
          );
        },
      );

      test('saveMapping without a linked account throws', () async {
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );
        await service.initialize();

        expect(
          () => service.saveMapping(
            transportType: 'ble',
            deviceId: 'AA:BB:CC',
            serial: '1338',
          ),
          throwsA(isA<StateError>()),
        );
      });

      test('a later successful validation after a transient failure refreshes '
          'the machine list', () async {
        var loginCalls = 0;
        var snCalls = 0;
        httpClient = http_testing.MockClient((request) async {
          if (request.url.path == '/support/api/login_test') {
            loginCalls++;
            if (loginCalls == 1) throw Exception('SocketException');
            return http.Response('cryptpw_abc123\n', 200);
          }
          if (request.url.path == '/support/api/sn') {
            snCalls++;
            return http.Response('1338 DE-DE1PRO220V7-00533\n', 200);
          }
          return http.Response('0\n', 200);
        });
        await seedAccount('user@example.com', 'cryptpw_abc123');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
          retryInterval: Duration.zero,
        );

        await service.initialize();
        await pumpEventQueue();

        // Startup validation failed transiently; no refresh happened.
        expect(snCalls, 0);
        expect(service.usableRegisteredMachines, isEmpty);

        // A later successful validation refreshes the machine list.
        expect(await service.isLoggedIn(), isTrue);
        await pumpEventQueue();

        expect(snCalls, 1);
        expect(service.usableRegisteredMachines.map((m) => m.serial), ['1338']);
      });

      test(
        'accountReady completes once the shared startup refresh settles',
        () async {
          final snGate = Completer<void>();
          var snCalls = 0;
          httpClient = http_testing.MockClient((request) async {
            if (request.url.path == '/support/api/login_test') {
              return http.Response('cryptpw_abc123\n', 200);
            }
            if (request.url.path == '/support/api/sn') {
              snCalls++;
              await snGate.future;
              return http.Response('1338 DE-DE1PRO220V7-00533\n', 200);
            }
            return http.Response('0\n', 200);
          });
          await seedAccount('user@example.com', 'cryptpw_abc123');
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: store,
            baseUrl: _baseUrl,
          );

          await service.initialize();
          await pumpEventQueue();

          final ready = service.accountReady;
          expect(snCalls, 1);

          snGate.complete();
          await ready;

          expect(service.usableRegisteredMachines.map((m) => m.serial), [
            '1338',
          ]);
          expect(snCalls, 1);
        },
      );

      test(
        'a transient sn failure is retried on a later accountReady await',
        () async {
          var snCalls = 0;
          httpClient = http_testing.MockClient((request) async {
            if (request.url.path == '/support/api/login_test') {
              return http.Response('cryptpw_abc123\n', 200);
            }
            if (request.url.path == '/support/api/sn') {
              snCalls++;
              if (snCalls == 1) throw Exception('timeout');
              return http.Response('1338 DE-DE1PRO220V7-00533\n', 200);
            }
            return http.Response('0\n', 200);
          });
          await seedAccount('user@example.com', 'cryptpw_abc123');
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: store,
            baseUrl: _baseUrl,
          );
          await service.initialize();
          await pumpEventQueue();

          expect(snCalls, 1);
          expect(service.usableRegisteredMachines, isEmpty);

          await service.accountReady;
          await pumpEventQueue();

          expect(snCalls, 2);
          expect(service.usableRegisteredMachines.map((m) => m.serial), [
            '1338',
          ]);
        },
      );

      test(
        'a transient machine-cache write failure is retried by accountReady',
        () async {
          var snCalls = 0;
          httpClient = http_testing.MockClient((request) async {
            if (request.url.path == '/support/api/sn') {
              snCalls++;
              return http.Response('1338 DE-DE1PRO220V7-00533\n', 200);
            }
            return http.Response('cryptpw_abc123\n', 200);
          });
          await seedAccount('user@example.com', 'cryptpw_abc123');
          await seedMachinesCache([
            {'serial': '1337', 'sku': 'DE-DE1220V-00001', 'model': 'DE1'},
          ]);
          store.failingWriteKey = 'registered_machines';
          store.remainingWriteFailures = 1;
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: store,
            baseUrl: _baseUrl,
          );

          await service.initialize();
          await service.accountReady;

          expect(snCalls, 1);
          expect(
            jsonDecode(
              (await store.read(key: 'registered_machines'))!,
            )['machines'][0]['serial'],
            '1337',
          );

          await service.accountReady;

          expect(snCalls, 2);
          expect(
            jsonDecode(
              (await store.read(key: 'registered_machines'))!,
            )['machines'][0]['serial'],
            '1338',
          );
        },
      );

      test(
        'a superseded pre-fetch refresh cannot invalidate a replacement login',
        () async {
          final deleteStore = _GateFirstMachinesDeleteStore(store);
          final emailStore = _GateFirstEmailReadStore(deleteStore);
          final oldAuth = base64Encode(
            utf8.encode('old@example.com:old_cryptpw'),
          );
          httpClient = http_testing.MockClient((request) async {
            if (request.url.path == '/support/api/login_test') {
              return http.Response('new_cryptpw\n', 200);
            }
            if (request.headers['authorization'] == 'Basic $oldAuth') {
              return http.Response('unauthorized', 401);
            }
            return http.Response('2222 DE-DE1PRO220V7-00533\n', 200);
          });
          await seedAccount('old@example.com', 'old_cryptpw');
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: emailStore,
            baseUrl: _baseUrl,
          );

          final staleRefresh = service.refreshRegisteredMachines();
          await emailStore.started.future;
          final login = service.login('new@example.com', 'hunter2');
          await deleteStore.started.future;

          emailStore.release.complete();
          Object? staleError;
          try {
            await staleRefresh;
          } catch (error) {
            staleError = error;
          } finally {
            deleteStore.gate.complete();
          }

          expect(staleError, isNull);
          expect(await login, isTrue);
          expect(await service.isLoggedIn(), isTrue);
          expect(await store.read(key: 'email'), 'new@example.com');
        },
      );

      test('accountReady abandons a superseded refresh', () async {
        final oldSnStarted = Completer<void>();
        final oldSnRelease = Completer<void>();
        final newSnStarted = Completer<void>();
        final newSnRelease = Completer<void>();
        var snCalls = 0;
        httpClient = http_testing.MockClient((request) async {
          if (request.url.path == '/support/api/sn') {
            snCalls++;
            if (snCalls == 1) {
              oldSnStarted.complete();
              await oldSnRelease.future;
              return http.Response('1111 DE-DE1220V-00001\n', 200);
            }
            newSnStarted.complete();
            await newSnRelease.future;
            return http.Response('2222 DE-DE1PRO220V7-00533\n', 200);
          }
          return http.Response('cryptpw_abc123\n', 200);
        });
        await seedAccount('old@example.com', 'cryptpw_abc123');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );
        await service.initialize();
        await oldSnStarted.future;

        var readyCompleted = false;
        final ready = service.accountReady.then((_) => readyCompleted = true);
        final login = service.login('new@example.com', 'hunter2');
        await newSnStarted.future;

        newSnRelease.complete();
        try {
          expect(await login, isTrue);
          await pumpEventQueue();
          expect(readyCompleted, isTrue);
          await ready;
          expect(service.usableRegisteredMachines.map((m) => m.serial), [
            '2222',
          ]);
        } finally {
          if (!oldSnRelease.isCompleted) oldSnRelease.complete();
          await pumpEventQueue();
        }
      });

      test('an in-flight refresh from the old account cannot overwrite a '
          'replacement login', () async {
        final oldSnGate = Completer<void>();
        var snCalls = 0;
        httpClient = http_testing.MockClient((request) async {
          if (request.url.path == '/support/api/login_test') {
            return http.Response('cryptpw_abc123\n', 200);
          }
          if (request.url.path == '/support/api/sn') {
            snCalls++;
            if (snCalls == 1) {
              // The old account's startup refresh stays pending.
              await oldSnGate.future;
              return http.Response('1111 DE-DE1220V-00001\n', 200);
            }
            return http.Response('2222 DE-DE1PRO220V7-00533\n', 200);
          }
          return http.Response('0\n', 200);
        });
        await seedAccount('old@example.com', 'cryptpw_abc123');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: store,
          baseUrl: _baseUrl,
        );
        await service.initialize();
        await pumpEventQueue();

        expect(await service.login('new@example.com', 'hunter2'), isTrue);
        await pumpEventQueue();
        expect(service.usableRegisteredMachines.map((m) => m.serial), ['2222']);

        oldSnGate.complete();
        await pumpEventQueue();

        expect(service.usableRegisteredMachines.map((m) => m.serial), ['2222']);
        final persisted =
            jsonDecode((await store.read(key: 'registered_machines'))!)
                as Map<String, dynamic>;
        expect(persisted['account'], 'new@example.com');
        expect(
          (persisted['machines'] as List).map((m) => (m as Map)['serial']),
          ['2222'],
        );
      });

      test('a stale old-account refresh is hidden and cannot clobber the '
          'replacement account cache', () async {
        final gatedStore = _GateFirstMachinesWriteStore(store);
        var snCalls = 0;
        httpClient = http_testing.MockClient((request) async {
          if (request.url.path == '/support/api/login_test') {
            return http.Response('cryptpw_abc123\n', 200);
          }
          if (request.url.path == '/support/api/sn') {
            snCalls++;
            if (snCalls == 1) {
              return http.Response('1111 DE-DE1220V-00001\n', 200);
            }
            return http.Response('2222 DE-DE1PRO220V7-00533\n', 200);
          }
          return http.Response('0\n', 200);
        });
        await gatedStore.write(key: 'email', value: 'old@example.com');
        await gatedStore.write(key: 'password', value: 'cryptpw_abc123');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: gatedStore,
          baseUrl: _baseUrl,
        );
        await service.initialize();
        await pumpEventQueue();

        expect(snCalls, 1);
        expect(service.usableRegisteredMachines.map((m) => m.serial), ['1111']);

        // The old refresh validated and is now blocked writing its cache.
        // A replacement login lands in that window and waits on the lock.
        final loginFuture = service.login('new@example.com', 'hunter2');
        await pumpEventQueue();

        expect(service.usableRegisteredMachines, isEmpty);
        expect(await service.isLoggedIn(), isFalse);

        gatedStore.gate.complete();
        expect(await loginFuture, isTrue);
        await pumpEventQueue();

        expect(service.usableRegisteredMachines.map((m) => m.serial), ['2222']);
        final persisted =
            jsonDecode((await store.read(key: 'registered_machines'))!)
                as Map<String, dynamic>;
        expect(persisted['account'], 'new@example.com');
        expect(
          (persisted['machines'] as List).map((m) => (m as Map)['serial']),
          ['2222'],
        );
      });

      test(
        'an in-flight refresh cannot resurrect scoped data after logout',
        () async {
          final snGate = Completer<void>();
          httpClient = http_testing.MockClient((request) async {
            if (request.url.path == '/support/api/login_test') {
              return http.Response('cryptpw_abc123\n', 200);
            }
            if (request.url.path == '/support/api/sn') {
              await snGate.future;
              return http.Response('1338 DE-DE1PRO220V7-00533\n', 200);
            }
            return http.Response('0\n', 200);
          });
          await seedAccount('user@example.com', 'cryptpw_abc123');
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: store,
            baseUrl: _baseUrl,
          );
          await service.initialize();
          await pumpEventQueue();

          await service.logout();
          expect(store.hasCredentials, isFalse);

          snGate.complete();
          await pumpEventQueue();

          expect(service.usableRegisteredMachines, isEmpty);
          expect(await store.read(key: 'registered_machines'), isNull);
        },
      );

      test(
        'a replacement login hides the previous account cache until cleared',
        () async {
          final gatedStore = _GateFirstMachinesDeleteStore(store);
          var snCalls = 0;
          httpClient = http_testing.MockClient((request) async {
            if (request.url.path == '/support/api/login_test') {
              return http.Response('cryptpw_abc123\n', 200);
            }
            if (request.url.path == '/support/api/sn') {
              snCalls++;
              if (snCalls == 1) {
                return http.Response('1111 DE-DE1220V-00001\n', 200);
              }
              return http.Response('2222 DE-DE1PRO220V7-00533\n', 200);
            }
            return http.Response('0\n', 200);
          });
          await gatedStore.write(key: 'email', value: 'old@example.com');
          await gatedStore.write(key: 'password', value: 'cryptpw_abc123');
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: gatedStore,
            baseUrl: _baseUrl,
          );
          await service.initialize();
          await pumpEventQueue();

          expect(service.usableRegisteredMachines.map((m) => m.serial), [
            '1111',
          ]);

          service.reportAuthenticationFailure();

          final loginFuture = service.login('new@example.com', 'hunter2');
          await pumpEventQueue();

          // The scoped-state clear is blocked on the gated delete; the old
          // account's in-memory cache must not resurface meanwhile.
          expect(service.usableRegisteredMachines, isEmpty);

          gatedStore.gate.complete();
          await loginFuture;
          await pumpEventQueue();

          expect(service.usableRegisteredMachines.map((m) => m.serial), [
            '2222',
          ]);
          final persisted =
              jsonDecode((await store.read(key: 'registered_machines'))!)
                  as Map<String, dynamic>;
          expect(persisted['account'], 'new@example.com');
        },
      );

      test('mapping queued during account replacement stays cleared', () async {
        final gatedStore = _GateFirstMachinesDeleteStore(store);
        var snCalls = 0;
        httpClient = http_testing.MockClient((request) async {
          if (request.url.path == '/support/api/login_test') {
            return http.Response('cryptpw_abc123\n', 200);
          }
          if (request.url.path == '/support/api/sn') {
            snCalls++;
            return http.Response(
              snCalls == 1
                  ? '1111 DE-DE1220V-00001\n'
                  : '2222 DE-DE1PRO220V7-00533\n',
              200,
            );
          }
          return http.Response('0\n', 200);
        });
        await gatedStore.write(key: 'email', value: 'old@example.com');
        await gatedStore.write(key: 'password', value: 'cryptpw_abc123');
        service = DecentAccountService(
          httpClient: httpClient,
          credentialStore: gatedStore,
          baseUrl: _baseUrl,
        );
        await service.initialize();
        await pumpEventQueue();

        final loginFuture = service.login('new@example.com', 'hunter2');
        await pumpEventQueue();
        final mappingFuture = service.saveMapping(
          transportType: 'ble',
          deviceId: 'AA:BB:CC',
          serial: '2222',
        );
        await pumpEventQueue();

        gatedStore.gate.complete();
        expect(await loginFuture, isTrue);
        await mappingFuture;

        expect(
          await service.lookupMapping(
            transportType: 'ble',
            deviceId: 'AA:BB:CC',
          ),
          isNull,
        );
        expect(await store.read(key: 'identity_mappings'), isNull);
      });

      test(
        'a refresh queued behind logout cannot repersist scoped data',
        () async {
          final gatedStore = _GateEmailDeleteStore(store);
          final snGate = Completer<void>();
          httpClient = http_testing.MockClient((request) async {
            if (request.url.path == '/support/api/login_test') {
              return http.Response('cryptpw_abc123\n', 200);
            }
            if (request.url.path == '/support/api/sn') {
              await snGate.future;
              return http.Response('1111 DE-DE1220V-00001\n', 200);
            }
            return http.Response('0\n', 200);
          });
          await seedAccount('user@example.com', 'cryptpw_abc123');
          service = DecentAccountService(
            httpClient: httpClient,
            credentialStore: gatedStore,
            baseUrl: _baseUrl,
          );
          await service.initialize();
          await pumpEventQueue();

          // The startup refresh is in flight (blocked on /sn) when logout
          // starts; logout clears and blocks on the gated email delete.
          final logoutFuture = service.logout();
          await pumpEventQueue();

          // The stale refresh now resolves /sn and queues behind logout's
          // scoped-state clear on the account write lock.
          snGate.complete();
          await pumpEventQueue();

          // Logout finishes; the queued refresh must see the bumped
          // generation and bail before persisting.
          gatedStore.gate.complete();
          await logoutFuture;
          await pumpEventQueue();

          expect(service.usableRegisteredMachines, isEmpty);
          expect(await store.read(key: 'registered_machines'), isNull);
          expect(await store.read(key: 'identity_mappings'), isNull);
          expect(store.hasCredentials, isFalse);
        },
      );
    });
  });
}
