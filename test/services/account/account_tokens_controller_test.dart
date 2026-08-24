import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/account/account_consent_gate.dart';
import 'package:reaprime/src/services/account/account_consent_store.dart';
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
  late AccountConsentGate consent;
  late List<String> prompts;

  setUp(() {
    service = ProxyTokenService();
    final credentials = _FakeCredentialStore();
    store = ProxyTokenStore(credentialStore: credentials);
    prompts = [];
    consent = AccountConsentGate(
      store: AccountConsentStore(credentialStore: credentials),
      prompt: (label) async {
        prompts.add(label);
        return AccountConsentDecision.allowed;
      },
    );
    controller = AccountTokensController(
      tokenService: service,
      store: store,
      callerLabelRegistrar: consent.registerCallerLabel,
    );
  });

  test('create mints a token that validates with a read scope', () async {
    final token = await controller.create(label: 'laptop');

    expect(token, isNotEmpty);
    final caller = service.validate(token);
    expect(caller, isNotNull);
    expect(caller!.id, startsWith('api:'));
    expect(caller.id, isNot('api:laptop'));
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

  test('duplicate labels require independent consent', () async {
    final first = await controller.create(label: 'station');
    final second = await controller.create(label: 'station');
    final firstId = service.validate(first)!.id;
    final secondId = service.validate(second)!.id;

    expect(firstId, isNot(secondId));
    expect(await consent.requireConsent(firstId), isTrue);
    expect(await consent.requireConsent(secondId), isTrue);
    expect(prompts, ['station', 'station']);
  });

  test('recreated label requires new consent after revoke', () async {
    final first = await controller.create(label: 'station');
    final firstId = service.validate(first)!.id;
    expect(await consent.requireConsent(firstId), isTrue);
    await controller.revoke(first);

    final replacement = await controller.create(label: 'station');
    final replacementId = service.validate(replacement)!.id;
    expect(replacementId, isNot(firstId));
    expect(await consent.requireConsent(replacementId), isTrue);
    expect(prompts, ['station', 'station']);
  });

  test('initialize loads persisted tokens into the service', () async {
    await store.save([
      PersistedProxyToken(
        id: 'persisted-id',
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
      callerLabelRegistrar: consent.registerCallerLabel,
    );
    await freshController.initialize();

    expect(freshService.validate('persisted-tok')!.id, 'api:persisted-id');
    expect(freshController.tokens.map((t) => t.label), ['desktop']);
  });
}
