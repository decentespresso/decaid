import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/account/encrypted_credential_store.dart';

/// In-memory blob backend so the crypto logic can be tested without files.
class InMemoryBlobStore implements SecretBlobStore {
  Uint8List? bytes;
  int writeCount = 0;

  @override
  Future<Uint8List?> read() async => bytes;

  @override
  Future<void> write(Uint8List value) async {
    bytes = value;
    writeCount++;
  }

  @override
  Future<void> delete() async => bytes = null;
}

final _keyA = List<int>.generate(32, (i) => i);
final _keyB = List<int>.generate(32, (i) => 255 - i);

void main() {
  group('EncryptedCredentialStore', () {
    late InMemoryBlobStore blob;
    late EncryptedCredentialStore store;

    setUp(() {
      blob = InMemoryBlobStore();
      store = EncryptedCredentialStore(keyBytes: _keyA, blob: blob);
    });

    test('write then read returns the stored value', () async {
      await store.write(key: 'email', value: 'a@b.com');
      expect(await store.read(key: 'email'), 'a@b.com');
    });

    test('read of missing key returns null', () async {
      expect(await store.read(key: 'nope'), isNull);
    });

    test('persisted blob is not plaintext', () async {
      await store.write(key: 'password', value: 'cryptpw_secret');
      final raw = String.fromCharCodes(blob.bytes!);
      expect(raw.contains('cryptpw_secret'), isFalse);
      expect(raw.contains('password'), isFalse);
    });

    test('each write uses a fresh nonce (different ciphertext)', () async {
      await store.write(key: 'k', value: 'v');
      final first = Uint8List.fromList(blob.bytes!);
      await store.write(key: 'k', value: 'v');
      final second = blob.bytes!;
      expect(first, isNot(equals(second)));
    });

    test('multiple keys coexist', () async {
      await store.write(key: 'email', value: 'a@b.com');
      await store.write(key: 'password', value: 'pw');
      expect(await store.read(key: 'email'), 'a@b.com');
      expect(await store.read(key: 'password'), 'pw');
    });

    test('delete removes a key', () async {
      await store.write(key: 'email', value: 'a@b.com');
      await store.delete(key: 'email');
      expect(await store.read(key: 'email'), isNull);
    });

    test('deleting the last key clears the blob file', () async {
      await store.write(key: 'email', value: 'a@b.com');
      await store.delete(key: 'email');
      expect(blob.bytes, isNull);
    });

    test(
      'survives a new store instance over the same blob (persistence)',
      () async {
        await store.write(key: 'email', value: 'a@b.com');
        final reopened = EncryptedCredentialStore(keyBytes: _keyA, blob: blob);
        expect(await reopened.read(key: 'email'), 'a@b.com');
      },
    );

    test('wrong key cannot decrypt — reads as empty store', () async {
      await store.write(key: 'email', value: 'a@b.com');
      final wrongKey = EncryptedCredentialStore(keyBytes: _keyB, blob: blob);
      expect(await wrongKey.read(key: 'email'), isNull);
    });

    test(
      'tampered ciphertext fails the GCM tag — reads as empty store',
      () async {
        await store.write(key: 'email', value: 'a@b.com');
        final tampered = Uint8List.fromList(blob.bytes!);
        tampered[tampered.length - 1] ^= 0xFF;
        blob.bytes = tampered;
        expect(await store.read(key: 'email'), isNull);
      },
    );

    test('concurrent writes do not corrupt the store', () async {
      await Future.wait([
        store.write(key: 'a', value: '1'),
        store.write(key: 'b', value: '2'),
        store.write(key: 'c', value: '3'),
      ]);
      expect(await store.read(key: 'a'), '1');
      expect(await store.read(key: 'b'), '2');
      expect(await store.read(key: 'c'), '3');
    });
  });
}
