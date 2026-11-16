import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:reaprime/src/services/github_credentials.dart';
import 'package:reaprime/src/services/github_rate_limit.dart';
import 'package:reaprime/src/services/github_request.dart';

class GithubTokenVerification {
  const GithubTokenVerification({
    required this.authenticated,
    required this.message,
  });

  final bool authenticated;
  final String message;
}

class GithubTokenVerifier {
  const GithubTokenVerifier({
    this._client,
    this.timeout = const Duration(seconds: 10),
  });

  final http.Client? _client;
  final Duration timeout;

  Future<GithubTokenVerification> verify(
    GithubCredentialSnapshot authorization,
  ) async {
    if (!authorization.isUser) {
      return _failure('Paste or save a token first.');
    }
    final uri = Uri.https('api.github.com', '/user');
    final abort = Completer<void>();
    final request =
        http.AbortableRequest('GET', uri, abortTrigger: abort.future)
          ..followRedirects = false
          ..headers.addAll(
            githubRequestHeaders(uri, authorization: authorization),
          );
    final ownedClient = _client == null ? http.Client() : null;
    try {
      final response = await _readResponse(
        _client ?? ownedClient!,
        request,
      ).timeout(timeout);
      if (response.statusCode == 401) {
        return _failure('Token is invalid, revoked, or expired.');
      }
      if (response.statusCode == 403 || response.statusCode == 429) {
        final limit = GithubRateLimit();
        final limited = limit.recordIfLimited(response);
        final reset = limit.resetAt;
        return _failure(
          limited && reset != null
              ? 'GitHub rate limit reached. Try again after ${reset.toIso8601String()}.'
              : 'GitHub refused or rate limited this request. Check token permissions or try again later.',
        );
      }
      if (response.statusCode >= 300 && response.statusCode < 400) {
        return _failure(
          'GitHub returned an unexpected redirect. Token not verified.',
        );
      }
      if (response.statusCode != 200) {
        return _failure('GitHub is unavailable. Try again later.');
      }
      if (authorization.containsSecret(response.body)) {
        return _failure('GitHub response rejected for security reasons.');
      }
      final data = jsonDecode(response.body);
      final login = data is Map<String, dynamic> ? data['login'] : null;
      if (login is! String ||
          login.length > 39 ||
          !RegExp(r'^[A-Za-z0-9]+(?:[-_][A-Za-z0-9]+)*$').hasMatch(login) ||
          authorization.containsSecret(login)) {
        return _failure('GitHub returned an invalid identity response.');
      }
      return GithubTokenVerification(
        authenticated: true,
        message:
            'Authenticated as $login. Token authenticates. Creating Decaid '
            'issues and uploading Gists have not been tested.',
      );
    } on TimeoutException {
      return _failure('GitHub token check timed out. Try again.');
    } on FormatException {
      return _failure('GitHub returned an invalid identity response.');
    } catch (_) {
      return _failure(
        'Could not connect to GitHub. Check your connection and try again.',
      );
    } finally {
      abort.complete();
      ownedClient?.close();
    }
  }

  Future<http.Response> _readResponse(
    http.Client client,
    http.BaseRequest request,
  ) async => http.Response.fromStream(await client.send(request));

  GithubTokenVerification _failure(String message) =>
      GithubTokenVerification(authenticated: false, message: message);
}
