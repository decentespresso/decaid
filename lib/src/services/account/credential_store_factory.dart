import 'dart:convert';
import 'dart:io' show Platform;

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:reaprime/src/services/account/credential_store.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/account/development_identity.dart';
import 'package:reaprime/src/services/account/encrypted_credential_store.dart';

typedef ProductionCredentialStoreFactory = Future<CredentialStore> Function();

Future<CredentialStore> createCredentialStore({
  bool developmentIdentity = false,
  ProductionCredentialStoreFactory? productionStoreFactory,
}) async {
  if (developmentIdentity && developmentIdentityEnabled) {
    return InMemoryCredentialStore();
  }
  return (productionStoreFactory ?? _createProductionCredentialStore)();
}

Future<CredentialStore> _createProductionCredentialStore() async {
  if (Platform.isMacOS) {
    return _createMacOSStore();
  }
  return SecureCredentialStore();
}

const _bundleId = 'net.tadel.reaprime';

Future<EncryptedCredentialStore> _createMacOSStore() async {
  final macInfo = await DeviceInfoPlugin().macOsInfo;

  final guid = macInfo.systemGUID ?? 'unknown-machine';
  final keyBytes = sha256.convert(utf8.encode('$guid$_bundleId')).bytes;

  final dir = await getApplicationSupportDirectory();
  final path = p.join(dir.path, 'secure_storage_v1.dat');

  return EncryptedCredentialStore(
    keyBytes: keyBytes,
    blob: FileBlobStore(path),
  );
}
