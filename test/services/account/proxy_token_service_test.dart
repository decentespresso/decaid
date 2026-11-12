import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/account/proxy_token_service.dart';

void main() {
  test('mints a non-empty skin token that validates as the skin caller', () {
    final service = ProxyTokenService();

    expect(service.skinToken, isNotEmpty);
    final caller = service.validate(service.skinToken);
    expect(caller, isNotNull);
    expect(caller!.id, 'skin');
    expect(caller.scopes, contains(ProxyTokenService.scopeAccountProxy));
    expect(
      caller.scopes,
      isNot(contains(ProxyTokenService.scopeAccountProxyWrite)),
    );
  });

  test('two instances mint different skin tokens', () {
    expect(ProxyTokenService().skinToken, isNot(ProxyTokenService().skinToken));
  });

  test('rotating the skin token binds identity and revokes the old token', () {
    final service = ProxyTokenService();
    final oldToken = service.skinToken;

    final newToken = service.rotateSkinToken(
      const ProxyCaller(
        id: 'skin:aileen',
        scopes: {ProxyTokenService.scopeAccountProxy},
      ),
    );

    expect(newToken, isNot(oldToken));
    expect(service.validate(oldToken), isNull);
    expect(service.validate(newToken)?.id, 'skin:aileen');
  });

  test('revoking the skin token ends the served skin session', () {
    final service = ProxyTokenService();
    final token = service.rotateSkinToken(
      const ProxyCaller(
        id: 'skin:aileen',
        scopes: {ProxyTokenService.scopeAccountProxy},
      ),
    );

    service.revokeSkinToken();

    expect(service.validate(token), isNull);
  });

  test('unknown tokens do not validate', () {
    final service = ProxyTokenService();
    expect(service.validate('nope'), isNull);
  });

  test('registers and revokes API-client tokens', () {
    final service = ProxyTokenService();
    service.registerToken(
      'tok-123',
      const ProxyCaller(
        id: 'api:laptop',
        scopes: {ProxyTokenService.scopeAccountProxy},
      ),
    );

    expect(service.validate('tok-123')!.id, 'api:laptop');

    service.revokeToken('tok-123');
    expect(service.validate('tok-123'), isNull);
  });

  test('registers API-client tokens with the write scope', () {
    final service = ProxyTokenService();
    service.registerToken(
      'write-token',
      const ProxyCaller(
        id: 'api:writer',
        scopes: {ProxyTokenService.scopeAccountProxyWrite},
      ),
    );

    final caller = service.validate('write-token');
    expect(caller, isNotNull);
    expect(caller!.scopes, contains(ProxyTokenService.scopeAccountProxyWrite));
    expect(caller.scopes, isNot(contains(ProxyTokenService.scopeAccountProxy)));
  });

  test('the skin token cannot be revoked', () {
    final service = ProxyTokenService();
    service.revokeToken(service.skinToken);
    expect(service.validate(service.skinToken), isNotNull);
  });

  test('the extension management scope is extensions:manage', () {
    expect(ProxyTokenService.scopeExtensionsManage, 'extensions:manage');
  });

  test('a process token shorter than 32 characters is not registered', () {
    final service = ProxyTokenService();
    final short = 'x' * (ProxyTokenService.minimumProcessTokenLength - 1);

    final registered = service.registerProcessToken(
      short,
      const ProxyCaller(
        id: 'cli',
        scopes: {ProxyTokenService.scopeExtensionsManage},
      ),
    );

    expect(registered, isFalse);
    expect(service.validate(short), isNull);
  });

  test('a process token with a space or a comma is not registered', () {
    final service = ProxyTokenService();
    const caller = ProxyCaller(
      id: 'cli',
      scopes: {ProxyTokenService.scopeExtensionsManage},
    );

    for (final token in [
      'correct horse battery staple decaid extensions',
      '${'z' * 40},${'z' * 40}',
      '${'z' * 40}\t',
    ]) {
      expect(service.registerProcessToken(token, caller), isFalse);
      expect(service.validate(token), isNull);
    }
  });

  test('a process token of 32 characters or more is registered', () {
    final service = ProxyTokenService();
    final token = 'y' * ProxyTokenService.minimumProcessTokenLength;

    final registered = service.registerProcessToken(
      token,
      const ProxyCaller(
        id: 'cli',
        scopes: {ProxyTokenService.scopeExtensionsManage},
      ),
    );

    expect(registered, isTrue);
    final caller = service.validate(token);
    expect(caller?.id, 'cli');
    expect(caller?.scopes, {ProxyTokenService.scopeExtensionsManage});
  });

  test('a registered caller keeps its label', () {
    final service = ProxyTokenService();
    service.registerToken(
      'labelled-token',
      const ProxyCaller(
        id: 'api:station',
        scopes: {ProxyTokenService.scopeExtensionsManage},
        label: 'Station laptop',
      ),
    );

    expect(service.validate('labelled-token')?.label, 'Station laptop');
    expect(service.validate(service.skinToken)?.label, isNull);
  });
}
