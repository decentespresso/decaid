import 'dart:convert';

import 'package:reaprime/src/services/account/decent_account_service.dart'
    show CredentialStore;

class PersistedProxyToken {
  final String token;
  final String label;
  final Set<String> scopes;
  final DateTime createdAt;

  const PersistedProxyToken({
    required this.token,
    required this.label,
    required this.scopes,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
    'token': token,
    'label': label,
    'scopes': scopes.toList(),
    'createdAt': createdAt.toIso8601String(),
  };

  factory PersistedProxyToken.fromJson(Map<String, dynamic> json) =>
      PersistedProxyToken(
        token: json['token'] as String,
        label: json['label'] as String,
        scopes: (json['scopes'] as List).map((e) => e as String).toSet(),
        createdAt: DateTime.parse(json['createdAt'] as String),
      );
}

class ProxyTokenStore {
  final CredentialStore _credentialStore;
  final String _storageKey;

  ProxyTokenStore({
    required CredentialStore credentialStore,
    String storageKey = 'account_proxy_tokens',
  }) : _credentialStore = credentialStore,
       _storageKey = storageKey;

  Future<List<PersistedProxyToken>> load() async {
    final raw = await _credentialStore.read(key: _storageKey);
    if (raw == null || raw.isEmpty) return [];
    final decoded = jsonDecode(raw) as List;
    return decoded
        .map((e) => PersistedProxyToken.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> save(List<PersistedProxyToken> tokens) async {
    if (tokens.isEmpty) {
      await _credentialStore.delete(key: _storageKey);
      return;
    }
    final encoded = jsonEncode(tokens.map((t) => t.toJson()).toList());
    await _credentialStore.write(key: _storageKey, value: encoded);
  }
}
