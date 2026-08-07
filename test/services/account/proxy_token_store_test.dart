import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart'
    show CredentialStore;
import 'package:reaprime/src/services/account/proxy_token_service.dart';
import 'package:reaprime/src/services/account/proxy_token_store.dart';

class _FakeCredentialStore implements CredentialStore {
  final Map<String, String> _data = {};

  @override
  Future<String?> read({required String key}) async => _data[key];

  @override
  Future<void> write({required String key, required String value}) async =>
      _data[key] = value;

  @override
  Future<void> delete({required String key}) async => _data.remove(key);
}

void main() {
  late _FakeCredentialStore creds;
  late ProxyTokenStore store;

  setUp(() {
    creds = _FakeCredentialStore();
    store = ProxyTokenStore(credentialStore: creds);
  });

  test('load returns empty list when nothing persisted', () async {
    expect(await store.load(), isEmpty);
  });

  test('save then load round-trips token records', () async {
    final created = DateTime.utc(2026, 6, 18, 12);
    await store.save([
      PersistedProxyToken(
        token: 'tok-abc',
        label: 'laptop',
        scopes: {ProxyTokenService.scopeAccountProxy},
        createdAt: created,
      ),
      PersistedProxyToken(
        token: 'tok-def',
        label: 'ci',
        scopes: {
          ProxyTokenService.scopeAccountProxy,
          ProxyTokenService.scopeAccountProxyWrite,
        },
        createdAt: created,
      ),
    ]);

    final loaded = await store.load();
    expect(loaded, hasLength(2));
    expect(loaded[0].token, 'tok-abc');
    expect(loaded[0].label, 'laptop');
    expect(loaded[0].scopes, {ProxyTokenService.scopeAccountProxy});
    expect(loaded[0].createdAt, created);
    expect(
      loaded[1].scopes,
      contains(ProxyTokenService.scopeAccountProxyWrite),
    );
  });

  test('save overwrites the previous set', () async {
    await store.save([
      PersistedProxyToken(
        token: 'old',
        label: 'old',
        scopes: {ProxyTokenService.scopeAccountProxy},
        createdAt: DateTime.utc(2026),
      ),
    ]);
    await store.save([]);
    expect(await store.load(), isEmpty);
  });
}
