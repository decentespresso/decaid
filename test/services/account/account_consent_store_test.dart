import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/account/account_consent_store.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart'
    show CredentialStore;

class _CredentialStore implements CredentialStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    values.remove(key);
  }
}

void main() {
  late _CredentialStore credentials;
  late AccountConsentStore store;

  setUp(() {
    credentials = _CredentialStore();
    store = AccountConsentStore(credentialStore: credentials);
  });

  test('returns no decision for an unknown caller', () async {
    expect(await store.read('skin:aileen'), isNull);
  });

  test('allowed and denied decisions survive store recreation', () async {
    await store.write('skin:aileen', AccountConsentDecision.allowed);
    await store.write('api:laptop', AccountConsentDecision.denied);

    final reloaded = AccountConsentStore(credentialStore: credentials);
    expect(await reloaded.read('skin:aileen'), AccountConsentDecision.allowed);
    expect(await reloaded.read('api:laptop'), AccountConsentDecision.denied);
  });

  test('malformed persisted data fails closed', () async {
    credentials.values['account_proxy_consent'] = '{broken';

    expect(await store.read('skin:aileen'), isNull);
  });
}
