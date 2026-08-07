import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';

/// Persists the encrypted credential blob as opaque bytes. Abstracted so the
/// crypto logic can be unit-tested with an in-memory backend (no filesystem).
abstract class SecretBlobStore {
  Future<Uint8List?> read();
  Future<void> write(Uint8List bytes);
  Future<void> delete();
}

/// AES-256-GCM encrypted key/value credential store.
///
/// Backs macOS, where the Keychain (Data Protection Keychain) is unavailable to
/// Developer-ID / sideloaded builds and returns errSecMissingEntitlement
/// (-34018). Mirrors the pattern used by Slack/VS Code/Obsidian on macOS: an
/// AES-GCM file whose key is bound to the machine (a copied file can't be
/// decrypted off-host) but not to the binary signature (so it survives
/// auto-updates).
///
/// The whole store is one encrypted JSON map. Each op reads, decrypts, mutates,
/// re-encrypts with a fresh random nonce, and writes. Operations are serialized
/// so concurrent isolates can't interleave a partial encrypt/decrypt.
class EncryptedCredentialStore implements CredentialStore {
  final SecretKey _key;
  final SecretBlobStore _blob;
  final AesGcm _algo = AesGcm.with256bits();

  Future<void> _lock = Future<void>.value();

  EncryptedCredentialStore({
    required List<int> keyBytes,
    required SecretBlobStore blob,
  }) : _key = SecretKey(keyBytes),
       _blob = blob;

  @override
  Future<String?> read({required String key}) =>
      _locked(() async => (await _load())[key]);

  @override
  Future<void> write({required String key, required String value}) =>
      _locked(() async {
        final map = await _load();
        map[key] = value;
        await _save(map);
      });

  @override
  Future<void> delete({required String key}) => _locked(() async {
    final map = await _load();
    if (map.remove(key) != null) {
      await _save(map);
    }
  });

  /// Reads and decrypts the store. A missing or undecryptable file (corruption,
  /// machine-UUID change) is treated as an empty store rather than an error —
  /// the user just re-logs in and the file is rewritten with the current key.
  Future<Map<String, String>> _load() async {
    final bytes = await _blob.read();
    if (bytes == null || bytes.isEmpty) return {};
    try {
      final box = SecretBox.fromConcatenation(
        bytes,
        nonceLength: 12,
        macLength: 16,
      );
      final clear = await _algo.decrypt(box, secretKey: _key);
      final decoded = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      return {};
    }
  }

  Future<void> _save(Map<String, String> map) async {
    if (map.isEmpty) {
      await _blob.delete();
      return;
    }
    final box = await _algo.encrypt(
      utf8.encode(jsonEncode(map)),
      secretKey: _key,
    );
    await _blob.write(Uint8List.fromList(box.concatenation()));
  }

  Future<T> _locked<T>(Future<T> Function() action) {
    final prev = _lock;
    final completer = Completer<void>();
    _lock = completer.future;
    return prev.then((_) => action()).whenComplete(completer.complete);
  }
}

/// Filesystem-backed [SecretBlobStore] with atomic writes and `chmod 600`.
class FileBlobStore implements SecretBlobStore {
  final String path;

  FileBlobStore(this.path);

  @override
  Future<Uint8List?> read() async {
    final file = File(path);
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  @override
  Future<void> write(Uint8List bytes) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(path);
    try {
      await Process.run('chmod', ['600', path]);
    } catch (_) {
      // chmod is best-effort; the OS user-container already isolates per user.
    }
  }

  @override
  Future<void> delete() async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
}
