import 'package:http/http.dart' as http;
import 'package:reaprime/src/services/github_credentials.dart';
import 'package:reaprime/src/services/github_rate_limit.dart';
import 'package:reaprime/src/util/remote_error.dart';

class GithubRequestException extends RemoteServiceException {
  final String message;
  final bool rateLimited;
  final DateTime? resetAt;
  final bool credentialRejected;

  GithubRequestException(
    this.message, {
    int statusCode = 0,
    this.rateLimited = false,
    this.resetAt,
    this.credentialRejected = false,
    String? userMessageOverride,
  }) : super(
         statusCode,
         userMessageOverride ??
             (credentialRejected
                 ? _credentialMessage
                 : rateLimited
                 ? _cooldownMessage(resetAt)
                 : statusCode == 304
                 ? 'GitHub returned an unexpected not-modified response. Try again.'
                 : remoteHttpError(statusCode).userMessage),
       );

  @override
  String toString() => message;
}

const _credentialMessage =
    'GitHub rejected the configured credential. Open Advanced Settings to replace or remove it.';
const _credentialReflectedMessage =
    'GitHub response rejected for security reasons.';

String _cooldownMessage(DateTime? resetAt) {
  if (resetAt == null) {
    return 'GitHub updates are temporarily unavailable. Try again later.';
  }
  final utc = resetAt.toUtc();
  final hour = utc.hour.toString().padLeft(2, '0');
  final minute = utc.minute.toString().padLeft(2, '0');
  return 'GitHub updates are temporarily unavailable until $hour:$minute UTC. '
      'Try again later.';
}

bool _isGithubApiOrigin(Uri uri) =>
    uri.scheme == 'https' &&
    uri.host == 'api.github.com' &&
    uri.port == 443 &&
    uri.userInfo.isEmpty;

Map<String, String> githubRequestHeaders(
  Uri uri, {
  Map<String, String> headers = const {},
  GithubCredentialSnapshot? authorization,
}) {
  final requestHeaders = <String, String>{
    'Accept': 'application/vnd.github.v3+json',
    'User-Agent': 'Decaid',
    ...headers,
  };
  if (_isGithubApiOrigin(uri) && authorization?.authorizationHeader != null) {
    requestHeaders['Authorization'] = authorization!.authorizationHeader!;
  } else {
    requestHeaders.removeWhere(
      (key, _) => key.toLowerCase() == 'authorization',
    );
  }
  return requestHeaders;
}

Future<http.Response> githubGet(
  String url, {
  required GithubRateLimit rateLimit,
  http.Client? client,
  Map<String, String> headers = const {},
  bool allowNotModified = false,
  GithubCredentialProvider? credentials,
}) async {
  final provider = credentials;
  final authorization = provider == null
      ? const GithubCredentialSnapshot.anonymous()
      : await provider.currentForRequest();
  final identityKey = authorization.identityKey;
  final resetAt = rateLimit.resetAtFor(identityKey);
  if (resetAt != null) {
    throw GithubRequestException(
      'GitHub rate limit active; update checks resume at '
      '${resetAt.toIso8601String()}',
      statusCode: 429,
      rateLimited: true,
      resetAt: resetAt,
    );
  }
  final uri = Uri.parse(url);
  final request = http.Request('GET', uri)
    ..headers.addAll(
      githubRequestHeaders(uri, headers: headers, authorization: authorization),
    )
    ..followRedirects = !(authorization.isUser && _isGithubApiOrigin(uri));
  final ownedClient = client == null ? http.Client() : null;
  try {
    final streamed = await (client ?? ownedClient!).send(request);
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode == 200 ||
        (allowNotModified && response.statusCode == 304)) {
      if (authorization.containsSecret(response.body)) {
        throw GithubRequestException(
          _credentialReflectedMessage,
          statusCode: response.statusCode,
          userMessageOverride: _credentialReflectedMessage,
        );
      }
      return response;
    }
    final limited = rateLimit.recordIfLimited(
      response,
      identityKey: identityKey,
    );
    final credentialRejected =
        authorization.isUser &&
        !limited &&
        (response.statusCode == 401 ||
            response.statusCode == 403 ||
            response.statusCode == 404);
    var message = credentialRejected
        ? _credentialMessage
        : 'GitHub request failed: HTTP ${response.statusCode}';
    if (limited) {
      final reset = rateLimit.resetAtFor(identityKey);
      final context = reset == null
          ? 'reset time unavailable'
          : 'resets at ${reset.toIso8601String()}';
      message = '$message (rate limit remaining: 0; $context)';
    }
    throw GithubRequestException(
      message,
      statusCode: response.statusCode,
      rateLimited: limited,
      resetAt: limited ? rateLimit.resetAtFor(identityKey) : null,
      credentialRejected: credentialRejected,
    );
  } catch (error) {
    if (error is GithubRequestException) rethrow;
    if (error is RemoteServiceException) rethrow;
    if (authorization.isUser) {
      throw GithubRequestException(
        'Could not connect to GitHub. Check your connection and try again.',
        userMessageOverride: 'Check your internet connection and try again.',
      );
    }
    rethrow;
  } finally {
    ownedClient?.close();
  }
}
