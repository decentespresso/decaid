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
}
