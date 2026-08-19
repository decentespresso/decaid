import 'dart:convert';

import 'package:reaprime/src/services/account/decent_account_service.dart'
    show CredentialStore;

enum AccountConsentDecision { allowed, denied }

class AccountConsentStore {
  final CredentialStore _credentialStore;
  final String _storageKey;

  Map<String, AccountConsentDecision>? _decisions;
  Future<void>? _loading;
  Future<void> _writeTail = Future<void>.value();

  AccountConsentStore({
    required CredentialStore credentialStore,
    String storageKey = 'account_proxy_consent',
  }) : _credentialStore = credentialStore,
       _storageKey = storageKey;

  Future<AccountConsentDecision?> read(String key) async {
    await _ensureLoaded();
    return _decisions![key];
  }

  Future<void> write(String key, AccountConsentDecision decision) {
    return _enqueue(() async {
      await _ensureLoaded();
      final updated = {..._decisions!, key: decision};
      await _persist(updated);
      _decisions = updated;
    });
  }

  Future<void> _ensureLoaded() async {
    if (_decisions != null) return;
    final loading = _loading;
    if (loading != null) return loading;

    final next = _load();
    _loading = next;
    try {
      await next;
    } finally {
      if (identical(_loading, next)) _loading = null;
    }
  }

  Future<void> _load() async {
    final raw = await _credentialStore.read(key: _storageKey);
    if (raw == null || raw.isEmpty) {
      _decisions = const {};
      return;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        _decisions = const {};
        return;
      }
      final loaded = <String, AccountConsentDecision>{};
      for (final entry in decoded.entries) {
        if (entry.key is! String || entry.value is! String) continue;
        final decision = switch (entry.value as String) {
          'allowed' => AccountConsentDecision.allowed,
          'denied' => AccountConsentDecision.denied,
          _ => null,
        };
        if (decision != null) loaded[entry.key as String] = decision;
      }
      _decisions = loaded;
    } on FormatException {
      _decisions = const {};
    }
  }

  Future<void> _persist(Map<String, AccountConsentDecision> decisions) {
    return _credentialStore.write(
      key: _storageKey,
      value: jsonEncode(
        decisions.map((key, decision) => MapEntry(key, decision.name)),
      ),
    );
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final result = _writeTail.then((_) => operation());
    _writeTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }
}
