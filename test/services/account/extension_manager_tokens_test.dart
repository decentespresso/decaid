import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/controllers/account_tokens_controller.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart'
    show CredentialStore;
import 'package:reaprime/src/services/account/proxy_token_service.dart';
import 'package:reaprime/src/services/account/proxy_token_store.dart';

class _FakeCredentialStore implements CredentialStore {
  final Map<String, String> data = {};

  @override
  Future<String?> read({required String key}) async => data[key];

  @override
  Future<void> write({required String key, required String value}) async =>
      data[key] = value;

  @override
  Future<void> delete({required String key}) async => data.remove(key);
}

void main() {
  late _FakeCredentialStore credentials;
  late ProxyTokenService service;
  late AccountTokensController controller;

  ProxyTokenStore storeOver(_FakeCredentialStore credentials) =>
      ProxyTokenStore(credentialStore: credentials);

  Future<({ProxyTokenService service, AccountTokensController controller})>
  restart() async {
    final restartedService = ProxyTokenService();
    final restartedController = AccountTokensController(
      tokenService: restartedService,
      store: storeOver(credentials),
    );
    await restartedController.initialize();
    return (service: restartedService, controller: restartedController);
  }

  setUp(() async {
    credentials = _FakeCredentialStore();
    service = ProxyTokenService();
    controller = AccountTokensController(
      tokenService: service,
      store: storeOver(credentials),
    );
    await controller.initialize();
  });

  test(
    'an extension manager token is persisted with only extensions:manage',
    () async {
      await controller.createExtensionManager(label: 'deploy script');

      final persisted = await storeOver(credentials).load();
      expect(persisted, hasLength(1));
      expect(persisted.single.label, 'deploy script');
      expect(persisted.single.scopes, {
        ProxyTokenService.scopeExtensionsManage,
      });
    },
  );

  test(
    'an extension manager token validates as its api caller with its label',
    () async {
      final token = await controller.createExtensionManager(
        label: 'deploy script',
      );

      final caller = service.validate(token)!;
      final record = controller.tokens.single;
      expect(caller.id, 'api:${record.id}');
      expect(caller.label, 'deploy script');
      expect(caller.scopes, {ProxyTokenService.scopeExtensionsManage});
    },
  );

  test(
    'extension management and account proxy scopes never come together',
    () async {
      final manager = await controller.createExtensionManager(label: 'deploy');
      final reader = await controller.create(label: 'reader');
      final writer = await controller.create(label: 'writer', write: true);

      expect(
        service.validate(manager)!.scopes,
        isNot(contains(ProxyTokenService.scopeAccountProxy)),
      );
      expect(
        service.validate(manager)!.scopes,
        isNot(contains(ProxyTokenService.scopeAccountProxyWrite)),
      );
      for (final accountToken in [reader, writer]) {
        expect(
          service.validate(accountToken)!.scopes,
          isNot(contains(ProxyTokenService.scopeExtensionsManage)),
        );
      }
      expect(
        service.validate(service.skinToken)!.scopes,
        isNot(contains(ProxyTokenService.scopeExtensionsManage)),
      );
    },
  );

  test(
    'an extension manager token survives a restart with its scope',
    () async {
      final token = await controller.createExtensionManager(label: 'deploy');
      final id = controller.tokens.single.id;

      final restarted = await restart();

      final caller = restarted.service.validate(token)!;
      expect(caller.id, 'api:$id');
      expect(caller.label, 'deploy');
      expect(caller.scopes, {ProxyTokenService.scopeExtensionsManage});
      expect(restarted.controller.tokens.single.scopes, {
        ProxyTokenService.scopeExtensionsManage,
      });
    },
  );

  test(
    'a revoked extension manager token stays revoked after a restart',
    () async {
      final token = await controller.createExtensionManager(label: 'deploy');

      await controller.revoke(token);

      expect(service.validate(token), isNull);
      expect(controller.tokens, isEmpty);
      expect(await storeOver(credentials).load(), isEmpty);

      final restarted = await restart();
      expect(restarted.service.validate(token), isNull);
      expect(restarted.controller.tokens, isEmpty);
    },
  );

  test(
    'a store that fails to load leaves no named tokens and allows new ones',
    () async {
      credentials.data['account_proxy_tokens'] = '{not json';
      final startedService = ProxyTokenService();
      final startedController = AccountTokensController(
        tokenService: startedService,
        store: storeOver(credentials),
      );

      await expectLater(startedController.initialize(), completes);

      expect(startedController.tokens, isEmpty);

      final token = await startedController.createExtensionManager(
        label: 'recovery',
      );
      expect(startedService.validate(token)!.scopes, {
        ProxyTokenService.scopeExtensionsManage,
      });

      final restarted = await restart();
      expect(restarted.service.validate(token)!.label, 'recovery');
    },
  );

  test('extension manager tokens need no Decent account', () async {
    final noAccountService = ProxyTokenService();
    final noAccountController = AccountTokensController(
      tokenService: noAccountService,
      store: storeOver(_FakeCredentialStore()),
    );
    await noAccountController.initialize();

    final token = await noAccountController.createExtensionManager(
      label: 'headless',
    );

    expect(noAccountService.validate(token)!.scopes, {
      ProxyTokenService.scopeExtensionsManage,
    });
  });
}
