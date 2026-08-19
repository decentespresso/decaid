import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:reaprime/src/services/account/account_consent_store.dart';

typedef AccountConsentPrompt =
    Future<AccountConsentDecision?> Function(String callerLabel);

class ActiveSkinConsent {
  final String? id;
  final String name;
  final String path;

  const ActiveSkinConsent({this.id, required this.name, required this.path});
}

class AccountConsentGate {
  final AccountConsentStore _store;
  final ActiveSkinConsent? Function() _activeSkin;
  final AccountConsentPrompt _prompt;
  final Set<String> _trustedConsentKeys;
  final bool _trustAllConsent;
  final Logger _log;
  final Map<String, Future<bool>> _pending = {};

  AccountConsentGate({
    required AccountConsentStore store,
    required ActiveSkinConsent? Function() activeSkin,
    required AccountConsentPrompt prompt,
    Set<String> trustedConsentKeys = const {},
    bool trustAllConsent = false,
    Logger? log,
  }) : _store = store,
       _activeSkin = activeSkin,
       _prompt = prompt,
       _trustedConsentKeys = Set.unmodifiable(
         trustedConsentKeys
             .map((key) => key.trim())
             .where((key) => key.isNotEmpty),
       ),
       _trustAllConsent = trustAllConsent,
       _log = log ?? Logger('AccountConsentGate');

  Future<bool> requireConsent(String callerId) async {
    final id = callerId.trim();
    if (_trustAllConsent && id == 'skin') return true;

    final subject = _subjectFor(id);
    if (subject == null) return false;
    if (_trustAllConsent || _trustedConsentKeys.contains(subject.key)) {
      return true;
    }

    final pending = _pending[subject.key];
    if (pending != null) return pending;

    final AccountConsentDecision? known;
    try {
      known = await _store.read(subject.key);
    } catch (error, stackTrace) {
      _log.warning(
        'Failed to read consent for ${subject.key}',
        error,
        stackTrace,
      );
      return false;
    }
    if (known != null) return known == AccountConsentDecision.allowed;

    final pendingAfterRead = _pending[subject.key];
    if (pendingAfterRead != null) return pendingAfterRead;

    final request = _promptAndPersist(subject);
    _pending[subject.key] = request;
    try {
      return await request;
    } finally {
      if (identical(_pending[subject.key], request)) {
        _pending.remove(subject.key);
      }
    }
  }

  Future<bool> _promptAndPersist(_ConsentSubject subject) async {
    final AccountConsentDecision? decision;
    try {
      decision = await _prompt(subject.label);
    } catch (error, stackTrace) {
      _log.warning(
        'Consent prompt failed for ${subject.key}',
        error,
        stackTrace,
      );
      return false;
    }
    if (decision == null) return false;

    try {
      await _store.write(subject.key, decision);
    } catch (error, stackTrace) {
      _log.warning(
        'Failed to persist consent for ${subject.key}',
        error,
        stackTrace,
      );
      return false;
    }
    return decision == AccountConsentDecision.allowed;
  }

  _ConsentSubject? _subjectFor(String callerId) {
    if (callerId == 'skin') {
      final skin = _activeSkin();
      if (skin == null || skin.path.trim().isEmpty) return null;
      final id = skin.id?.trim();
      final key = id != null && id.isNotEmpty
          ? 'skin:$id'
          : 'skin:path:${_pathDigest(skin.path)}';
      final label = skin.name.trim().isEmpty ? 'Custom skin' : skin.name.trim();
      return _ConsentSubject(key, label);
    }

    if (callerId.startsWith('plugin:')) {
      final id = callerId.substring(7);
      if (id.trim().isEmpty) return null;
      return _ConsentSubject(callerId, 'Plugin "$id"');
    }
    if (callerId.startsWith('api:')) {
      final id = callerId.substring(4);
      if (id.trim().isEmpty) return null;
      return _ConsentSubject(callerId, 'API client "$id"');
    }
    return null;
  }

  String _pathDigest(String path) => sha256
      .convert(utf8.encode(p.normalize(p.absolute(path.trim()))))
      .toString();
}

class _ConsentSubject {
  final String key;
  final String label;

  const _ConsentSubject(this.key, this.label);
}
