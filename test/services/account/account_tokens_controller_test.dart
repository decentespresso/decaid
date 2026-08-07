import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart'
    show CredentialStore;
import 'package:reaprime/src/controllers/account_tokens_controller.dart';
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
  late ProxyTokenService service;
  late ProxyTokenStore store;
  late AccountTokensController controller;

  setUp(() {
    service = ProxyTokenService();
    store = ProxyTokenStore(credentialStore: _FakeCredentialStore());
    controller = AccountTokensController(tokenService: service, store: store);
  });

  test('create mints a token that validates with a read scope', () async {
    final token = await controller.create(label: 'laptop');

    expect(token, isNotEmpty);
    final caller = service.validate(token);
    expect(caller, isNotNull);
    expect(caller!.id, 'api:laptop');
    expect(caller.scopes, contains(ProxyTokenService.scopeAccountProxy));
    expect(
      caller.scopes,
      isNot(contains(ProxyTokenService.scopeAccountProxyWrite)),
    );
  });

  test('create with write:true adds the write scope', () async {
    final token = await controller.create(label: 'ci', write: true);
    final caller = service.validate(token)!;
    expect(caller.scopes, contains(ProxyTokenService.scopeAccountProxy));
    expect(caller.scopes, contains(ProxyTokenService.scopeAccountProxyWrite));
  });

  test('create persists the token to the store', () async {
    await controller.create(label: 'laptop');
    final persisted = await store.load();
    expect(persisted, hasLength(1));
    expect(persisted.single.label, 'laptop');
  });

  test('tokens lists created tokens but never the skin token', () async {
    await controller.create(label: 'laptop');
    expect(controller.tokens.map((t) => t.label), ['laptop']);
    expect(
      controller.tokens.map((t) => t.token),
      isNot(contains(service.skinToken)),
    );
  });

  test('revoke removes from service and store', () async {
    final token = await controller.create(label: 'laptop');
    await controller.revoke(token);

    expect(service.validate(token), isNull);
    expect(await store.load(), isEmpty);
    expect(controller.tokens, isEmpty);
  });

  test('initialize loads persisted tokens into the service', () async {
    await store.save([
      PersistedProxyToken(
        token: 'persisted-tok',
        label: 'desktop',
        scopes: {ProxyTokenService.scopeAccountProxy},
        createdAt: DateTime.utc(2026),
      ),
    ]);

    final freshService = ProxyTokenService();
    final freshController = AccountTokensController(
      tokenService: freshService,
      store: store,
    );
    await freshController.initialize();

    expect(freshService.validate('persisted-tok')!.id, 'api:desktop');
    expect(freshController.tokens.map((t) => t.label), ['desktop']);
  });
}
