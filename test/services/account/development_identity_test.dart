import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/account/decent_proxy_service.dart';
import 'package:reaprime/src/services/account/development_identity.dart';
import 'package:reaprime/src/services/account/credential_store_factory.dart';

void main() {
  test('development identity capability is debug-only and explicit', () {
    const compileFlag = bool.fromEnvironment(
      'DECAID_ENABLE_DUMMY_ACCOUNT',
      defaultValue: false,
    );
    const isDebug =
        !bool.fromEnvironment('dart.vm.product') &&
        !bool.fromEnvironment('dart.vm.profile');
    expect(developmentIdentityEnabled, compileFlag && isDebug);
  });

  test(
    'development identity factory never overwrites production credentials',
    () async {
      final production = _MemoryStore()
        ..values['email'] = 'customer@example.com'
        ..values['password'] = 'real-password';

      var productionFactoryCalled = false;
      final selected = await createCredentialStore(
        developmentIdentity: true,
        productionStoreFactory: () async {
          productionFactoryCalled = true;
          return production;
        },
      );

      if (developmentIdentityEnabled) {
        expect(selected, isA<InMemoryCredentialStore>());
        expect(productionFactoryCalled, isFalse);
      } else {
        expect(selected, same(production));
        expect(productionFactoryCalled, isTrue);
      }
      expect(await production.read(key: 'email'), 'customer@example.com');
      expect(await production.read(key: 'password'), 'real-password');
    },
  );

  test('in-memory credentials do not survive a new store instance', () async {
    final first = InMemoryCredentialStore();
    await first.write(key: 'email', value: 'demo@example.com');
    await first.write(key: 'password', value: 'demo-password');

    final restarted = InMemoryCredentialStore();
    expect(await restarted.read(key: 'email'), isNull);
    expect(await restarted.read(key: 'password'), isNull);
  });

  test(
    'account and proxy clients cannot forward synthetic credentials',
    () async {
      final store = InMemoryCredentialStore();
      await store.write(key: 'email', value: 'demo@example.com');
      await store.write(key: 'password', value: 'demo-password');
      final accountClient = DevelopmentIdentityHttpClient();
      final proxyClient = DevelopmentIdentityHttpClient();
      final account = DecentAccountService(
        httpClient: accountClient,
        credentialStore: store,
      );
      final proxy = DecentProxyService(
        httpClient: proxyClient,
        credentialStore: store,
        requireConsent: (_) async => true,
      );

      expect(
        await account.verifyStoredCredentialsStatus(),
        DecentAccountStatus.indeterminate,
      );
      await expectLater(
        proxy.proxyGet(callerId: 'test', path: 'support/api/profile'),
        throwsStateError,
      );
      expect(accountClient.attemptedRequests, 1);
      expect(proxyClient.attemptedRequests, 1);
    },
  );
}

class _MemoryStore implements CredentialStore {
  final values = <String, String>{};

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async => values.remove(key);
}
