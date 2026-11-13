// ignore_for_file: deprecated_member_use, prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:reaprime/src/services/account/credential_store.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';

class GithubCredentialException implements Exception {
  final String message;

  const GithubCredentialException(this.message);

  @override
  String toString() => message;
}

const githubPatAndroidSharedPreferencesName = 'decaid_github_pat';
const githubPatAndroidKeyPrefix = 'decaid_github_pat';

const githubPatAndroidOptions = AndroidOptions(
  sharedPreferencesName: githubPatAndroidSharedPreferencesName,
  preferencesKeyPrefix: githubPatAndroidKeyPrefix,
  migrateOnAlgorithmChange: true,
);
const githubPatIosOptions = IOSOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
  synchronizable: false,
);
const githubPatMacOsOptions = MacOsOptions(
  accessibility: KeychainAccessibility.first_unlock_this_device,
  synchronizable: false,
);

const _githubPatStorage = FlutterSecureStorage(
  aOptions: githubPatAndroidOptions,
  iOptions: githubPatIosOptions,
  mOptions: githubPatMacOsOptions,
);

class GithubCredentialSnapshot {
  final String _token;
  final String identityKey;
  final bool isUser;
  final bool isBundled;

  const GithubCredentialSnapshot._({
    required String token,
    required this.identityKey,
    required this.isUser,
    required this.isBundled,
  }) : _token = token;

  const GithubCredentialSnapshot.anonymous()
    : _token = '',
      identityKey = 'anonymous',
      isUser = false,
      isBundled = false;

  bool get isAnonymous => !isUser && !isBundled;

  String? get authorizationHeader => _token.isEmpty ? null : 'Bearer $_token';

  bool containsSecret(String value) =>
      _token.isNotEmpty && value.contains(_token);

  String redact(String value) =>
      containsSecret(value) ? value.replaceAll(_token, '[REDACTED]') : value;

  factory GithubCredentialSnapshot.user(String token) =>
      GithubCredentialSnapshot._(
        token: token,
        identityKey: 'user:${_identityDigest(token)}',
        isUser: true,
        isBundled: false,
      );

  factory GithubCredentialSnapshot.bundled(String token) =>
      GithubCredentialSnapshot._(
        token: token,
        identityKey: 'bundled:${_identityDigest(token)}',
        isUser: false,
        isBundled: true,
      );
}

String _identityDigest(String token) =>
    sha256.convert(utf8.encode(token)).toString();

class GithubCredentialProvider {
  static const String storageKey = 'decaid.github.personal_access_token.v1';
  static const _storageError =
      'GitHub credential storage failed. Check device secure storage and try again.';
  static const _emptyError =
      'Enter a GitHub personal access token, or remove the configured token.';

  final CredentialStore _store;
  final Duration _loadTimeout;
  GithubCredentialSnapshot _current =
      const GithubCredentialSnapshot.anonymous();
  Future<void>? _loadFuture;
  bool _loaded = false;

  GithubCredentialProvider({
    CredentialStore? store,
    Duration loadTimeout = const Duration(seconds: 2),
  }) : assert(loadTimeout > Duration.zero),
       assert(loadTimeout <= const Duration(seconds: 5)),
       _store = store ?? SecureCredentialStore(storage: _githubPatStorage),
       _loadTimeout = loadTimeout;

  GithubCredentialSnapshot get current => _current;

  Future<void> load() => _ensureLoaded();

  Future<GithubCredentialSnapshot> currentForRequest() async {
    await _ensureLoaded();
    return _current;
  }

  Future<void> _ensureLoaded() {
    if (_loaded) return Future.value();
    final existing = _loadFuture;
    if (existing != null) return existing;
    final future = _read();
    _loadFuture = future;
    future.then<void>(
      (_) {
        if (identical(_loadFuture, future)) _loadFuture = null;
      },
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_loadFuture, future)) _loadFuture = null;
      },
    );
    return future;
  }

  Future<void> _read() async {
    try {
      final value =
          (await _store.read(key: storageKey).timeout(_loadTimeout))?.trim() ??
          '';
      _current = value.isEmpty
          ? const GithubCredentialSnapshot.anonymous()
          : GithubCredentialSnapshot.user(value);
      _loaded = true;
    } on TimeoutException {
      throw const GithubCredentialException(_storageError);
    } on GithubCredentialException {
      rethrow;
    } catch (_) {
      throw const GithubCredentialException(_storageError);
    }
  }

  Future<void> save(String value) async {
    final token = value.trim();
    if (token.isEmpty) {
      throw const GithubCredentialException(_emptyError);
    }
    await _ensureLoaded();
    try {
      await _store.write(key: storageKey, value: token);
    } catch (_) {
      throw const GithubCredentialException(_storageError);
    }
    _current = GithubCredentialSnapshot.user(token);
  }

  Future<void> remove() async {
    await _ensureLoaded();
    try {
      await _store.delete(key: storageKey);
    } catch (_) {
      throw const GithubCredentialException(_storageError);
    }
    _current = const GithubCredentialSnapshot.anonymous();
  }

  Future<GithubCredentialSnapshot> feedbackSnapshot({
    String? bundledToken,
  }) async {
    await _ensureLoaded();
    return selectForFeedback(bundledToken: bundledToken);
  }

  GithubCredentialSnapshot selectForFeedback({String? bundledToken}) {
    if (_current.isUser) return _current;
    final token = bundledToken?.trim() ?? '';
    return token.isEmpty
        ? const GithubCredentialSnapshot.anonymous()
        : GithubCredentialSnapshot.bundled(token);
  }
}
