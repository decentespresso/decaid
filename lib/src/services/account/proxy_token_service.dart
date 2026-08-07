import 'dart:convert';
import 'dart:math';

class ProxyCaller {
  final String id;
  final Set<String> scopes;

  const ProxyCaller({required this.id, required this.scopes});
}

class ProxyTokenService {
  static const String scopeAccountProxy = 'account:proxy';

  static const String scopeAccountProxyWrite = 'account:proxy:write';

  final Map<String, ProxyCaller> _tokens = {};
  late final String _skinToken;

  ProxyTokenService({String? skinToken}) {
    _skinToken = skinToken ?? generateToken();
    _tokens[_skinToken] = const ProxyCaller(
      id: 'skin',
      scopes: {scopeAccountProxy},
    );
  }

  String get skinToken => _skinToken;

  void registerToken(String token, ProxyCaller caller) {
    _tokens[token] = caller;
  }

  void revokeToken(String token) {
    if (token == _skinToken) return;
    _tokens.remove(token);
  }

  ProxyCaller? validate(String token) => _tokens[token];

  static String generateToken() {
    final rng = Random.secure();
    final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
    return base64Url.encode(bytes);
  }
}
