import 'dart:convert';
import 'dart:math';

class ProxyCaller {
  final String id;
  final Set<String> scopes;
  final String? label;

  const ProxyCaller({required this.id, required this.scopes, this.label});
}

class ProxyTokenService {
  static const String scopeAccountProxy = 'account:proxy';

  static const String scopeAccountProxyWrite = 'account:proxy:write';

  static const String scopeExtensionsManage = 'extensions:manage';

  static const int minimumProcessTokenLength = 32;

  final Map<String, ProxyCaller> _tokens = {};
  late String _skinToken;

  ProxyTokenService({String? skinToken}) {
    _skinToken = skinToken ?? generateToken();
    _tokens[_skinToken] = const ProxyCaller(
      id: 'skin',
      scopes: {scopeAccountProxy},
    );
  }

  String get skinToken => _skinToken;

  String rotateSkinToken(ProxyCaller caller) {
    _tokens.remove(_skinToken);
    _skinToken = generateToken();
    _tokens[_skinToken] = caller;
    return _skinToken;
  }

  void revokeSkinToken() {
    _tokens.remove(_skinToken);
  }

  void registerToken(String token, ProxyCaller caller) {
    _tokens[token] = caller;
  }

  bool registerProcessToken(String token, ProxyCaller caller) {
    if (token.length < minimumProcessTokenLength ||
        token.contains(RegExp(r'[\s,]'))) {
      return false;
    }
    registerToken(token, caller);
    return true;
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
