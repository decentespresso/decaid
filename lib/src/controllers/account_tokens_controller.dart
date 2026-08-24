import 'package:logging/logging.dart';
import 'package:reaprime/src/services/account/proxy_token_service.dart';
import 'package:reaprime/src/services/account/proxy_token_store.dart';
import 'package:uuid/uuid.dart';

class AccountTokensController {
  final ProxyTokenService _tokenService;
  final ProxyTokenStore _store;
  final void Function(String callerId, String label)? _callerLabelRegistrar;
  final Logger _log = Logger('AccountTokensController');

  final List<PersistedProxyToken> _tokens = [];

  AccountTokensController({
    required ProxyTokenService tokenService,
    required ProxyTokenStore store,
    void Function(String callerId, String label)? callerLabelRegistrar,
  }) : _tokenService = tokenService,
       _store = store,
       _callerLabelRegistrar = callerLabelRegistrar;

  List<PersistedProxyToken> get tokens => List.unmodifiable(_tokens);

  Future<void> initialize() async {
    try {
      final persisted = await _store.load();
      _tokens
        ..clear()
        ..addAll(persisted);
      for (final t in persisted) {
        _register(t);
      }
    } catch (e, st) {
      _log.warning('Failed to load persisted proxy tokens', e, st);
    }
  }

  Future<String> create({required String label, bool write = false}) async {
    final token = ProxyTokenService.generateToken();
    final scopes = <String>{
      ProxyTokenService.scopeAccountProxy,
      if (write) ProxyTokenService.scopeAccountProxyWrite,
    };
    final record = PersistedProxyToken(
      id: const Uuid().v4(),
      token: token,
      label: label,
      scopes: scopes,
      createdAt: DateTime.now(),
    );

    _register(record);
    _tokens.add(record);
    await _store.save(_tokens);
    return token;
  }

  Future<void> revoke(String token) async {
    _tokenService.revokeToken(token);
    _tokens.removeWhere((t) => t.token == token);
    await _store.save(_tokens);
  }

  void _register(PersistedProxyToken token) {
    final callerId = 'api:${token.id}';
    _tokenService.registerToken(
      token.token,
      ProxyCaller(id: callerId, scopes: token.scopes),
    );
    _callerLabelRegistrar?.call(callerId, token.label);
  }
}
