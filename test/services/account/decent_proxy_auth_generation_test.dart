import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/account/decent_proxy_service.dart';

import 'decent_proxy_service_test.dart' as helpers;

class _DelayedCredentialStore extends helpers.FakeCredentialStore {
  final Future<void> Function(String) onRead;
  final Future<void> Function(String) onWrite;

  _DelayedCredentialStore({required this.onRead, required this.onWrite});

  @override
  Future<String?> read({required String key}) async {
    final value = await super.read(key: key);
    await onRead(key);
    return value;
  }

  @override
  Future<void> write({required String key, required String value}) async {
    await onWrite(key);
    await super.write(key: key, value: value);
  }
}

void main() {
  late helpers.FakeCredentialStore store;
  late DecentAccountService account;
  Future<void> Function(String)? readHook;
  Future<void> Function(String)? writeHook;

  setUp(() async {
    readHook = null;
    writeHook = null;
    store = _DelayedCredentialStore(
      onRead: (key) async => await readHook?.call(key),
      onWrite: (key) async => await writeHook?.call(key),
    );
    await store.write(key: 'email', value: 'user@example.com');
    await store.write(key: 'password', value: 'stable-token');
    final client = MockClient((request) async {
      return switch (request.url.path) {
        '/support/api/login_test' => http.Response('stable-token', 200),
        '/support/api/sn' => http.Response('6262 DE-DE1PRO', 200),
        _ => throw StateError('Unexpected request: ${request.url}'),
      };
    });
    addTearDown(client.close);
    account = DecentAccountService(httpClient: client, credentialStore: store);
    expect(await account.login('user@example.com', 'password'), isTrue);
  });

  DecentProxyService proxy(
    MockClientHandler handler, {
    Future<bool> Function(String)? requireConsent,
    bool trackGeneration = true,
  }) {
    final client = MockClient(handler);
    addTearDown(client.close);
    return DecentProxyService(
      httpClient: client,
      credentialStore: store,
      requireConsent: requireConsent ?? (_) async => true,
      onAuthFailure: account.reportAuthenticationFailure,
      isAuthKnownInvalid: account.isAuthKnownInvalid,
      authenticationGeneration: trackGeneration
          ? () => account.authenticationGeneration
          : null,
    );
  }

  test(
    'changed credentials suppress old 401 without a generation provider',
    () async {
      final started = Completer<void>();
      final response = Completer<http.Response>();
      final service = proxy((_) async {
        started.complete();
        return response.future;
      }, trackGeneration: false);
      final pending = service.proxyGet(
        callerId: 'plugin:shot-upload',
        path: 'support/api/sn',
      );
      await started.future;
      expect(await account.login('new@example.com', 'password'), isTrue);
      response.complete(http.Response('unauthorized', 401));
      expect((await pending).statusCode, 401);
      expect(await account.isAuthKnownInvalid(), isFalse);
    },
  );

  test('generation is checked after rereading credentials for a 401', () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    final readStarted = Completer<void>();
    final finishRead = Completer<void>();
    final service = proxy((_) async {
      started.complete();
      return response.future;
    });
    final pending = service.proxyGet(
      callerId: 'plugin:shot-upload',
      path: 'support/api/sn',
    );
    await started.future;
    readHook = (key) async {
      if (key != 'password') return;
      readHook = null;
      readStarted.complete();
      await finishRead.future;
    };
    response.complete(http.Response('unauthorized', 401));
    await readStarted.future;
    expect(await account.login('user@example.com', 'password'), isTrue);
    finishRead.complete();
    expect((await pending).statusCode, 401);
    expect(await account.isAuthKnownInvalid(), isFalse);
  });

  test(
    'a login still writing credentials after consent blocks the request',
    () async {
      final consentStarted = Completer<void>();
      final grantConsent = Completer<bool>();
      final writeStarted = Completer<void>();
      final finishWrite = Completer<void>();
      var requests = 0;
      final service = proxy(
        (_) async {
          requests++;
          return http.Response('unauthorized', 401);
        },
        requireConsent: (_) {
          consentStarted.complete();
          return grantConsent.future;
        },
      );
      final pending = service.proxyGet(
        callerId: 'plugin:shot-upload',
        path: 'support/api/sn',
      );
      await consentStarted.future;
      writeHook = (key) async {
        if (key != 'password') return;
        writeHook = null;
        writeStarted.complete();
        await finishWrite.future;
      };
      final login = account.login('user@example.com', 'password');
      await writeStarted.future;
      grantConsent.complete(true);
      await expectLater(
        pending,
        throwsA(isA<DecentAccountAuthInvalidException>()),
      );
      finishWrite.complete();
      expect(await login, isTrue);
      expect(requests, 0);
      expect(await account.isAuthKnownInvalid(), isFalse);
    },
  );

  for (final email in ['new@example.com', 'user@example.com']) {
    test('old 401 cannot invalidate a later login as $email', () async {
      final started = Completer<void>();
      final response = Completer<http.Response>();
      final service = proxy((request) async {
        if (!started.isCompleted) {
          started.complete();
          return response.future;
        }
        return http.Response('ok', 200);
      });
      final pending = service.proxyGet(
        callerId: 'plugin:shot-upload',
        path: 'support/api/sn',
      );
      await started.future;
      expect(await account.login(email, 'password'), isTrue);
      response.complete(http.Response('unauthorized', 401));

      expect((await pending).statusCode, 401);
      expect(await account.isAuthKnownInvalid(), isFalse);
      expect(await account.isLoggedIn(), isTrue);
      expect(
        (await service.proxyGet(
          callerId: 'plugin:shot-upload',
          path: 'support/api/sn',
        )).statusCode,
        200,
      );
    });
  }

  test(
    'current 401 invalidates authentication and blocks the next call',
    () async {
      final service = proxy((_) async => http.Response('unauthorized', 401));
      expect(
        (await service.proxyGet(
          callerId: 'plugin:shot-upload',
          path: 'support/api/sn',
        )).statusCode,
        401,
      );
      expect(await account.isAuthKnownInvalid(), isTrue);
      await expectLater(
        service.proxyGet(
          callerId: 'plugin:shot-upload',
          path: 'support/api/sn',
        ),
        throwsA(isA<DecentAccountAuthInvalidException>()),
      );
    },
  );

  for (final email in ['new@example.com', 'user@example.com']) {
    test(
      '401 rejects the credentials committed during consent as $email',
      () async {
        final consentStarted = Completer<void>();
        final consent = Completer<bool>();
        final service = proxy(
          (_) async => http.Response('unauthorized', 401),
          requireConsent: (_) {
            consentStarted.complete();
            return consent.future;
          },
        );
        final pending = service.proxyGet(
          callerId: 'plugin:shot-upload',
          path: 'support/api/sn',
        );
        await consentStarted.future;
        expect(await account.login(email, 'password'), isTrue);
        consent.complete(true);
        expect((await pending).statusCode, 401);
        expect(await account.isAuthKnownInvalid(), isTrue);
      },
    );
  }

  test(
    'a login during the final credential read aborts before sending',
    () async {
      final readStarted = Completer<void>();
      final finishRead = Completer<void>();
      var requests = 0;
      final service = proxy(
        (_) async {
          requests++;
          return http.Response('ok', 200);
        },
        requireConsent: (_) async {
          readHook = (key) async {
            if (key != 'email') return;
            readHook = null;
            readStarted.complete();
            await finishRead.future;
          };
          return true;
        },
      );
      final pending = service.proxyGet(
        callerId: 'plugin:shot-upload',
        path: 'support/api/sn',
      );
      final result = expectLater(pending, throwsStateError);
      await readStarted.future;
      expect(await account.login('new@example.com', 'password'), isTrue);
      finishRead.complete();
      await result;
      expect(requests, 0);
      expect(await account.isAuthKnownInvalid(), isFalse);
    },
  );

  test(
    'credential reread failure preserves the upstream 401 response',
    () async {
      final service = proxy((_) async {
        readHook = (_) async => throw StateError('secure storage unavailable');
        return http.Response(
          'unauthorized',
          401,
          headers: {'x-upstream': 'preserved'},
        );
      });
      final response = await service.proxyGet(
        callerId: 'plugin:shot-upload',
        path: 'support/api/sn',
      );
      readHook = null;
      expect(response.statusCode, 401);
      expect(response.body, 'unauthorized');
      expect(response.headers['x-upstream'], 'preserved');
      expect(await account.isAuthKnownInvalid(), isFalse);
    },
  );
}
