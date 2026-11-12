import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'decent_account_service.dart';

const bool developmentIdentityEnabled =
    kDebugMode &&
    bool.fromEnvironment('DECAID_ENABLE_DUMMY_ACCOUNT', defaultValue: false);

class InMemoryCredentialStore implements CredentialStore {
  final Map<String, String> _values = {};

  @override
  Future<String?> read({required String key}) async => _values[key];

  @override
  Future<void> write({required String key, required String value}) async {
    _values[key] = value;
  }

  @override
  Future<void> delete({required String key}) async {
    _values.remove(key);
  }
}

class DevelopmentIdentityHttpClient extends http.BaseClient {
  int attemptedRequests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    attemptedRequests++;
    throw StateError(
      'Development identity is offline and cannot make network requests',
    );
  }
}
