import 'package:flutter_test/flutter_test.dart';
import 'package:reaprime/src/services/account/decent_account_service.dart';
import 'package:reaprime/src/services/github_credentials.dart';

class _MemoryStore implements CredentialStore {
  String? value;
  Object? readFailure;
  Object? writeFailure;
  Object? deleteFailure;
  var reads = 0;
  var writes = 0;
  var deletes = 0;

  @override
  Future<String?> read({required String key}) async {
    reads++;
    if (readFailure != null) throw readFailure!;
    return value;
  }

  @override
  Future<void> write({required String key, required String value}) async {
    writes++;
    if (writeFailure != null) throw writeFailure!;
    this.value = value;
  }

  @override
  Future<void> delete({required String key}) async {
    deletes++;
    if (deleteFailure != null) throw deleteFailure!;
    value = null;
  }
}

void main() {
  test(
    'loads trimmed credentials and persists them across provider instances',
    () async {
      final store = _MemoryStore();
      final credentials = GithubCredentialProvider(store: store);

      await credentials.save('  secret-token  ');
      expect(credentials.current.isUser, isTrue);
      expect(credentials.current.authorizationHeader, 'Bearer secret-token');

      final restored = GithubCredentialProvider(store: store);
      await restored.load();
      expect(restored.current.isUser, isTrue);
      expect(restored.current.authorizationHeader, 'Bearer secret-token');
    },
  );

  test('empty, replace, and remove update live state', () async {
    final store = _MemoryStore();
    final credentials = GithubCredentialProvider(store: store);
    await credentials.save('first');
    await credentials.save(' second ');
    expect(credentials.current.authorizationHeader, 'Bearer second');

    await credentials.remove();
    expect(credentials.current.isAnonymous, isTrue);
    expect(store.value, isNull);

    await expectLater(
      credentials.save(' \t '),
      throwsA(isA<GithubCredentialException>()),
    );
    expect(credentials.current.isAnonymous, isTrue);
  });

  test(
    'storage failures preserve the previous state and hide details',
    () async {
      final store = _MemoryStore();
      final credentials = GithubCredentialProvider(store: store);
      await credentials.save('keep-this-secret');

      store.writeFailure = StateError('keep-this-secret');
      await expectLater(
        credentials.save('new-secret'),
        throwsA(
          isA<GithubCredentialException>().having(
            (e) => e.toString(),
            'message',
            isNot(contains('secret')),
          ),
        ),
      );
      expect(
        credentials.current.authorizationHeader,
        'Bearer keep-this-secret',
      );

      store.deleteFailure = StateError('keep-this-secret');
      await expectLater(
        credentials.remove(),
        throwsA(
          isA<GithubCredentialException>().having(
            (e) => e.toString(),
            'message',
            isNot(contains('secret')),
          ),
        ),
      );
      expect(
        credentials.current.authorizationHeader,
        'Bearer keep-this-secret',
      );

      store.readFailure = StateError('keep-this-secret');
      await expectLater(
        GithubCredentialProvider(store: store).load(),
        throwsA(
          isA<GithubCredentialException>().having(
            (e) => e.toString(),
            'message',
            isNot(contains('secret')),
          ),
        ),
      );
    },
  );

  test(
    'feedback selection uses user identity or an immutable bundled fallback',
    () async {
      final credentials = GithubCredentialProvider(store: _MemoryStore());
      final bundled = credentials.selectForFeedback(
        bundledToken: 'bundled-secret',
      );
      expect(bundled.isBundled, isTrue);
      expect(bundled.authorizationHeader, 'Bearer bundled-secret');
      expect(bundled.identityKey, isNot('anonymous'));

      await credentials.save('user-secret');
      final selected = credentials.selectForFeedback(
        bundledToken: 'bundled-secret',
      );
      await credentials.remove();
      expect(selected.authorizationHeader, 'Bearer user-secret');
      expect(selected.isUser, isTrue);
    },
  );
}
