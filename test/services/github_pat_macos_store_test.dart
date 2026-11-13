import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:reaprime/src/models/feedback/feedback_request.dart';
import 'package:reaprime/src/services/account/encrypted_credential_store.dart';
import 'package:reaprime/src/services/feedback_service.dart';
import 'package:reaprime/src/services/github_credential_store.dart';
import 'package:reaprime/src/services/github_credentials.dart';
import 'package:reaprime/src/services/github_rate_limit.dart';
import 'package:reaprime/src/services/github_request.dart';
import 'package:path/path.dart' as p;

Future<void> deleteEntity(String path) async {
  switch (await FileSystemEntity.type(path, followLinks: false)) {
    case FileSystemEntityType.file:
      await File(path).delete();
    case FileSystemEntityType.directory:
      await Directory(path).delete(recursive: true);
    case FileSystemEntityType.link:
      await Link(path).delete();
    case FileSystemEntityType.notFound:
      break;
    default:
      throw StateError('unexpected file type');
  }
}

Future<void> expectUnreadable(
  GithubCredentialProvider credentials, {
  required String bundledToken,
}) async {
  await expectLater(
    credentials.currentForRequest(),
    throwsA(
      isA<GithubCredentialException>().having(
        (error) => error.toString(),
        'message',
        contains('Stored token cannot be read'),
      ),
    ),
  );
  expect(credentials.isUnreadable, isTrue);
  await expectLater(
    credentials.feedbackSnapshot(bundledToken: bundledToken),
    throwsA(
      isA<GithubCredentialException>().having(
        (error) => error.toString(),
        'message',
        contains('Stored token cannot be read'),
      ),
    ),
  );

  var requests = 0;
  await expectLater(
    githubGet(
      'https://api.github.com/repos/acme/project',
      rateLimit: GithubRateLimit(),
      credentials: credentials,
      client: MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      }),
    ),
    throwsA(isA<GithubCredentialException>()),
  );
  expect(requests, 0);

  final service = FeedbackService(
    githubToken: bundledToken,
    credentials: credentials,
    currentSerialNumbers: () => const [],
    installedComponents: () => const [],
    httpClient: MockClient((_) async {
      requests++;
      return http.Response('{}', 200);
    }),
  );
  final result = await service.submitFeedback(
    FeedbackRequest(
      description: 'storage failure',
      type: FeedbackType.bug,
      includeLogs: false,
      includeSystemInfo: false,
    ),
  );
  expect(result.success, isFalse);
  expect(result.errorMessage, contains('Could not read the GitHub credential'));
  expect(requests, 0);
}

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('github-pat-store-');
  });

  tearDown(() => directory.delete(recursive: true));

  test(
    'saves, replaces, reads, and removes using the encrypted file',
    () async {
      final store = GithubPatFileCredentialStore(
        systemGuid: 'machine-a',
        supportDirectory: directory.path,
      );
      final credentials = GithubCredentialProvider(store: store);

      await credentials.save('first-token');
      expect(
        (await credentials.currentForRequest()).authorizationHeader,
        'Bearer first-token',
      );
      await credentials.save('second-token');
      expect(
        (await credentials.currentForRequest()).authorizationHeader,
        'Bearer second-token',
      );
      await credentials.remove();
      expect((await credentials.currentForRequest()).isAnonymous, isTrue);
      expect(File(store.filePath).existsSync(), isFalse);
    },
  );

  test('absent PAT remains anonymous and can use bundled fallback', () async {
    final credentials = GithubCredentialProvider(
      store: GithubPatFileCredentialStore(
        systemGuid: 'machine-a',
        supportDirectory: directory.path,
      ),
    );

    expect((await credentials.currentForRequest()).isAnonymous, isTrue);
    final fallback = await credentials.feedbackSnapshot(
      bundledToken: 'bundled-token',
    );
    expect(fallback.isBundled, isTrue);
    expect(fallback.authorizationHeader, 'Bearer bundled-token');
  });

  test('does not treat an unreadable parent as an absent PAT', () async {
    if (Process.runSync('/usr/bin/id', ['-u']).stdout.toString().trim() ==
        '0') {
      markTestSkipped('root can read chmod 000 directories');
      return;
    }
    final store = GithubPatFileCredentialStore(
      systemGuid: 'machine-a',
      supportDirectory: directory.path,
    );
    final credentials = GithubCredentialProvider(store: store);
    await credentials.save('protected-token');
    await Process.run('/bin/chmod', ['000', directory.path]);
    try {
      final inaccessible = GithubCredentialProvider(
        store: GithubPatFileCredentialStore(
          systemGuid: 'machine-a',
          supportDirectory: directory.path,
        ),
      );
      await expectUnreadable(inaccessible, bundledToken: 'bundled-token');
    } finally {
      await Process.run('/bin/chmod', ['700', directory.path]);
    }
  });

  test(
    'hard storage failures do not fall back to bundled credentials',
    () async {
      final cases = <Future<void> Function(GithubPatFileCredentialStore)>[
        (store) async {
          await File(store.filePath).writeAsBytes(const []);
        },
        (store) async {
          await Directory(store.filePath).create();
        },
        (store) async {
          await Link(store.filePath).create('${store.filePath}.missing');
        },
        (store) async {
          await File(store.filePath).writeAsBytes([1, 2, 3]);
        },
      ];
      for (final prepare in cases) {
        final store = GithubPatFileCredentialStore(
          systemGuid: 'machine-a',
          supportDirectory: directory.path,
        );
        await prepare(store);
        await expectUnreadable(
          GithubCredentialProvider(store: store),
          bundledToken: 'bundled-token',
        );
        await deleteEntity(store.filePath);
      }

      final validStore = GithubPatFileCredentialStore(
        systemGuid: 'machine-a',
        supportDirectory: directory.path,
      );
      await GithubCredentialProvider(store: validStore).save('secret-token');
      await expectUnreadable(
        GithubCredentialProvider(
          store: GithubPatFileCredentialStore(
            systemGuid: 'machine-b',
            supportDirectory: directory.path,
          ),
        ),
        bundledToken: 'bundled-token',
      );
    },
  );

  test('lazy factory retries after a failed creation', () async {
    if (!Platform.isMacOS) {
      markTestSkipped('macOS lazy PAT storage is not active on this platform');
      return;
    }
    var attempts = 0;
    final store = createDefaultGithubCredentialStore(
      secureStore: GithubPatFileCredentialStore(
        systemGuid: 'machine-a',
        supportDirectory: directory.path,
      ),
      create: () async {
        attempts++;
        if (attempts == 1) throw const GithubPatStorageException();
        return GithubPatFileCredentialStore(
          systemGuid: 'machine-a',
          supportDirectory: directory.path,
        );
      },
    );

    await expectLater(
      store.read(key: GithubCredentialProvider.storageKey),
      throwsA(isA<GithubPatStorageException>()),
    );
    expect(await store.read(key: GithubCredentialProvider.storageKey), isNull);
    expect(attempts, 2);
  });

  test('persists after recreating the provider', () async {
    final first = GithubCredentialProvider(
      store: GithubPatFileCredentialStore(
        systemGuid: 'machine-a',
        supportDirectory: directory.path,
      ),
    );
    await first.save('persistent-token');

    final second = GithubCredentialProvider(
      store: GithubPatFileCredentialStore(
        systemGuid: 'machine-a',
        supportDirectory: directory.path,
      ),
    );
    await second.load();
    expect(second.current.authorizationHeader, 'Bearer persistent-token');
  });

  test('does not remove a PAT when its parent becomes inaccessible', () async {
    if (Process.runSync('/usr/bin/id', ['-u']).stdout.toString().trim() ==
        '0') {
      markTestSkipped('root can read chmod 000 directories');
      return;
    }
    final first = GithubCredentialProvider(
      store: GithubPatFileCredentialStore(
        systemGuid: 'machine-a',
        supportDirectory: directory.path,
      ),
    );
    await first.save('protected-token');

    final persisted = GithubCredentialProvider(
      store: GithubPatFileCredentialStore(
        systemGuid: 'machine-a',
        supportDirectory: directory.path,
      ),
    );
    await persisted.load();
    expect(persisted.current.authorizationHeader, 'Bearer protected-token');

    final chmod = await Process.run('/bin/chmod', ['000', directory.path]);
    expect(chmod.exitCode, 0);
    try {
      await expectLater(
        persisted.remove(),
        throwsA(isA<GithubCredentialException>()),
      );
      expect(persisted.current.authorizationHeader, 'Bearer protected-token');
      expect(persisted.current.isUser, isTrue);
      expect(persisted.readState, GithubCredentialReadState.configured);
    } finally {
      final restore = await Process.run('/bin/chmod', ['700', directory.path]);
      expect(restore.exitCode, 0);
    }

    final filePath = p.join(directory.path, githubPatFileName);
    expect(File(filePath).existsSync(), isTrue);
    final restored = GithubCredentialProvider(
      store: GithubPatFileCredentialStore(
        systemGuid: 'machine-a',
        supportDirectory: directory.path,
      ),
    );
    await restored.load();
    expect(restored.current.authorizationHeader, 'Bearer protected-token');
    await restored.remove();
    expect(restored.current.isAnonymous, isTrue);
    expect(File(filePath).existsSync(), isFalse);
  });

  test('is separate from the Decent account encrypted file', () async {
    const guid = 'machine-a';
    const bundleId = 'net.tadel.reaprime';
    final accountPath = p.join(directory.path, 'secure_storage_v1.dat');
    final account = EncryptedCredentialStore(
      keyBytes: sha256.convert(utf8.encode('$guid$bundleId')).bytes,
      blob: FileBlobStore(accountPath),
    );
    await account.write(key: 'email', value: 'account@example.com');
    await account.write(key: 'password', value: 'account-password');
    final accountBytesBeforePat = await File(accountPath).readAsBytes();

    final pat = GithubPatFileCredentialStore(
      systemGuid: guid,
      supportDirectory: directory.path,
    );
    await pat.write(key: GithubCredentialProvider.storageKey, value: 'pat');
    expect(await File(accountPath).readAsBytes(), accountBytesBeforePat);
    await pat.write(
      key: GithubCredentialProvider.storageKey,
      value: 'replacement-pat',
    );
    expect(await File(accountPath).readAsBytes(), accountBytesBeforePat);
    await pat.delete(key: GithubCredentialProvider.storageKey);
    expect(await File(accountPath).readAsBytes(), accountBytesBeforePat);

    expect(await account.read(key: 'email'), 'account@example.com');
    expect(await account.read(key: 'password'), 'account-password');
    expect(
      await account.read(key: GithubCredentialProvider.storageKey),
      isNull,
    );
    expect(await pat.read(key: 'email'), isNull);

    final patKeyOnAccount = EncryptedCredentialStore(
      keyBytes: sha256
          .convert(utf8.encode('$guid$bundleId$githubPatPurpose'))
          .bytes,
      blob: FileBlobStore(accountPath),
      strict: true,
    );
    await expectLater(
      patKeyOnAccount.read(key: 'email'),
      throwsA(isA<EncryptedCredentialStoreException>()),
    );
  });

  test('corruption and wrong keys are hard unreadable states', () async {
    final store = GithubPatFileCredentialStore(
      systemGuid: 'machine-a',
      supportDirectory: directory.path,
    );
    final credentials = GithubCredentialProvider(store: store);
    await credentials.save('secret-token');
    final file = File(store.filePath);
    final bytes = await file.readAsBytes();
    bytes[bytes.length - 1] ^= 0xff;
    await file.writeAsBytes(bytes, flush: true);

    final corruptedCredentials = GithubCredentialProvider(store: store);
    await expectUnreadable(corruptedCredentials, bundledToken: 'bundled-token');
    await corruptedCredentials.save('replacement-token');
    final recovered = GithubCredentialProvider(
      store: GithubPatFileCredentialStore(
        systemGuid: 'machine-a',
        supportDirectory: directory.path,
      ),
    );
    expect(
      (await recovered.currentForRequest()).authorizationHeader,
      'Bearer replacement-token',
    );

    final wrongKey = GithubPatFileCredentialStore(
      systemGuid: 'machine-b',
      supportDirectory: directory.path,
    );
    final wrongCredentials = GithubCredentialProvider(store: wrongKey);
    await expectUnreadable(wrongCredentials, bundledToken: 'bundled-token');
  });

  test(
    'corrupted storage can be removed and remains removed after recreation',
    () async {
      final store = GithubPatFileCredentialStore(
        systemGuid: 'machine-a',
        supportDirectory: directory.path,
      );
      await store.write(
        key: GithubCredentialProvider.storageKey,
        value: 'token',
      );
      final bytes = await File(store.filePath).readAsBytes();
      bytes[0] ^= 0xff;
      await File(store.filePath).writeAsBytes(bytes, flush: true);

      final credentials = GithubCredentialProvider(store: store);
      await expectLater(
        credentials.load(),
        throwsA(isA<GithubCredentialException>()),
      );
      await credentials.remove();
      expect(credentials.current.isAnonymous, isTrue);
      expect(File(store.filePath).existsSync(), isFalse);

      final recreated = GithubCredentialProvider(
        store: GithubPatFileCredentialStore(
          systemGuid: 'machine-a',
          supportDirectory: directory.path,
        ),
      );
      expect((await recreated.currentForRequest()).isAnonymous, isTrue);
      await recreated.save('replacement-token');
      final persisted = GithubCredentialProvider(
        store: GithubPatFileCredentialStore(
          systemGuid: 'machine-a',
          supportDirectory: directory.path,
        ),
      );
      expect(
        (await persisted.currentForRequest()).authorizationHeader,
        'Bearer replacement-token',
      );
      await persisted.remove();
      final afterRemoval = GithubCredentialProvider(
        store: GithubPatFileCredentialStore(
          systemGuid: 'machine-a',
          supportDirectory: directory.path,
        ),
      );
      expect((await afterRemoval.currentForRequest()).isAnonymous, isTrue);
    },
  );

  test('does not store the token in plaintext and creates mode 0600', () async {
    final token = 'plain-text-must-not-appear';
    final store = GithubPatFileCredentialStore(
      systemGuid: 'machine-a',
      supportDirectory: directory.path,
    );
    await store.write(key: GithubCredentialProvider.storageKey, value: token);
    final file = File(store.filePath);
    final bytes = await file.readAsBytes();
    expect(utf8.decode(bytes, allowMalformed: true), isNot(contains(token)));
    expect((await file.stat()).mode & 0x1ff, 0x180);
  });

  test('cleans up the temporary file when final replacement fails', () async {
    final store = GithubPatFileCredentialStore(
      systemGuid: 'machine-a',
      supportDirectory: directory.path,
    );
    await Directory(store.filePath).create();

    await expectLater(
      store.write(key: GithubCredentialProvider.storageKey, value: 'token'),
      throwsA(isA<GithubPatStorageException>()),
    );

    final leftovers = (await directory.list().toList())
        .where(
          (entry) => p
              .basename(entry.path)
              .startsWith('.github_pat_secure_storage_v1.'),
        )
        .toList();
    expect(leftovers, isEmpty);
  });
}
