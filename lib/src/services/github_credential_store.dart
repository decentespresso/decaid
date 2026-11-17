import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/account/encrypted_credential_store.dart';

const githubPatFileName = 'github_pat_secure_storage_v1.dat';
const githubPatPurpose = 'github-personal-access-token-v1';
const githubPatBundleId = 'net.tadel.reaprime';

class GithubPatFileCredentialStore implements CredentialStore {
  final String filePath;
  final EncryptedCredentialStore _store;

  GithubPatFileCredentialStore({
    required String systemGuid,
    required String supportDirectory,
  }) : filePath = p.join(supportDirectory, githubPatFileName),
       _store = EncryptedCredentialStore(
         keyBytes: _keyFor(systemGuid),
         blob: _PrivateFileBlobStore(
           p.join(supportDirectory, githubPatFileName),
         ),
         strict: true,
       );

  static List<int> _keyFor(String systemGuid) {
    if (systemGuid.trim().isEmpty) {
      throw const GithubPatStorageException();
    }
    return sha256
        .convert(utf8.encode('$systemGuid$githubPatBundleId$githubPatPurpose'))
        .bytes;
  }

  @override
  Future<String?> read({required String key}) => _store.read(key: key);

  @override
  Future<void> write({required String key, required String value}) =>
      _store.write(key: key, value: value);

  @override
  Future<void> delete({required String key}) => _store.delete(key: key);
}

class GithubPatStorageException implements Exception {
  const GithubPatStorageException();

  @override
  String toString() => 'GitHub credential storage is unavailable.';
}

class _PrivateFileBlobStore implements SecretBlobStore {
  _PrivateFileBlobStore(this.path);

  final String path;

  @override
  Future<Uint8List?> read() async {
    final FileSystemEntityType type;
    try {
      type = await FileSystemEntity.type(path, followLinks: false);
    } catch (_) {
      throw const GithubPatStorageException();
    }
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      throw const GithubPatStorageException();
    }
    try {
      return await File(path).readAsBytes();
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2) return null;
      throw const GithubPatStorageException();
    } catch (_) {
      throw const GithubPatStorageException();
    }
  }

  @override
  Future<void> write(Uint8List bytes) async {
    final directory = p.dirname(path);
    String? temporaryPath;
    try {
      final template = p.join(
        directory,
        '.github_pat_secure_storage_v1.XXXXXX',
      );
      final result = await Process.run('/usr/bin/mktemp', [template]);
      if (result.exitCode != 0) throw const GithubPatStorageException();
      temporaryPath = (result.stdout as String).trim();
      if (temporaryPath.isEmpty) throw const GithubPatStorageException();
      await File(temporaryPath).writeAsBytes(bytes, flush: true);
      await File(temporaryPath).rename(path);
      temporaryPath = null;
    } catch (_) {
      throw const GithubPatStorageException();
    } finally {
      if (temporaryPath != null) {
        try {
          await File(temporaryPath).delete();
        } catch (_) {}
      }
    }
  }

  @override
  Future<void> delete() async {
    final FileSystemEntityType type;
    try {
      type = await FileSystemEntity.type(path, followLinks: false);
    } catch (_) {
      throw const GithubPatStorageException();
    }
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.notFound) {
      throw const GithubPatStorageException();
    }
    try {
      await File(path).delete();
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2) {
        try {
          await Directory(p.dirname(path)).list(followLinks: false).isEmpty;
          return;
        } on FileSystemException catch (parentError) {
          if (parentError.osError?.errorCode == 2) return;
          throw const GithubPatStorageException();
        } catch (_) {
          throw const GithubPatStorageException();
        }
      }
      throw const GithubPatStorageException();
    } catch (_) {
      throw const GithubPatStorageException();
    }
  }
}

class _LazyCredentialStore implements CredentialStore {
  _LazyCredentialStore(this._create);

  final Future<CredentialStore> Function() _create;
  Future<CredentialStore>? _store;

  Future<CredentialStore> _get() {
    final existing = _store;
    if (existing != null) return existing;
    final future = _create();
    _store = future;
    future.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        if (identical(_store, future)) _store = null;
      },
    );
    return future;
  }

  @override
  Future<String?> read({required String key}) async =>
      (await _get()).read(key: key);

  @override
  Future<void> write({required String key, required String value}) async =>
      (await _get()).write(key: key, value: value);

  @override
  Future<void> delete({required String key}) async =>
      (await _get()).delete(key: key);
}

Future<CredentialStore> createGithubPatCredentialStore({
  String? systemGuid,
  String? supportDirectory,
}) async {
  final guid = systemGuid ?? (await DeviceInfoPlugin().macOsInfo).systemGUID;
  if (guid == null || guid.trim().isEmpty) {
    throw const GithubPatStorageException();
  }
  final directory =
      supportDirectory ?? (await getApplicationSupportDirectory()).path;
  return GithubPatFileCredentialStore(
    systemGuid: guid,
    supportDirectory: directory,
  );
}

CredentialStore createDefaultGithubCredentialStore({
  required CredentialStore secureStore,
  Future<CredentialStore> Function()? create,
}) {
  if (!Platform.isMacOS) return secureStore;
  return _LazyCredentialStore(create ?? createGithubPatCredentialStore);
}
