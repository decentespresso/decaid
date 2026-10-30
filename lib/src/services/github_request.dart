import 'package:http/http.dart' as http;
import 'package:reaprime/src/services/github_rate_limit.dart';
import 'package:reaprime/src/util/remote_error.dart';

class GithubRequestException extends RemoteServiceException {
  final String message;
  final bool rateLimited;
  final DateTime? resetAt;

  GithubRequestException(
    this.message, {
    int statusCode = 0,
    this.rateLimited = false,
    this.resetAt,
  }) : super(
         statusCode,
         rateLimited
             ? _cooldownMessage(resetAt)
             : statusCode == 304
             ? 'GitHub returned an unexpected not-modified response. Try again.'
             : remoteHttpError(statusCode).userMessage,
       );

  @override
  String toString() => message;
}

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

Future<http.Response> githubGet(
  String url, {
  required GithubRateLimit rateLimit,
  http.Client? client,
  Map<String, String> headers = const {},
  bool allowNotModified = false,
}) async {
  final resetAt = rateLimit.resetAt;
  if (resetAt != null) {
    throw GithubRequestException(
      'GitHub rate limit active; update checks resume at '
      '${resetAt.toIso8601String()}',
      statusCode: 429,
      rateLimited: true,
      resetAt: resetAt,
    );
  }
  final requestHeaders = {
    'Accept': 'application/vnd.github.v3+json',
    'User-Agent': 'Decaid',
    ...headers,
  };
  final response = client == null
      ? await http.get(Uri.parse(url), headers: requestHeaders)
      : await client.get(Uri.parse(url), headers: requestHeaders);
  if (response.statusCode == 200 ||
      (allowNotModified && response.statusCode == 304)) {
    return response;
  }
  final limited = rateLimit.recordIfLimited(response);
  var message = 'GitHub request failed: HTTP ${response.statusCode}';
  if (response.statusCode == 403 || response.statusCode == 429) {
    final body = response.body
        .substring(0, response.body.length > 200 ? 200 : response.body.length)
        .replaceAll(RegExp(r'[\x00-\x1f\x7f]'), ' ')
        .trim();
    final suffix = response.body.length > 200 ? '…' : '';
    if (body.isNotEmpty) message = '$message: $body$suffix';
    if (limited) {
      final reset = rateLimit.resetAt;
      final context = reset == null
          ? 'reset time unavailable'
          : 'resets at ${reset.toIso8601String()}';
      message = '$message (rate limit remaining: 0; $context)';
    }
  }
  throw GithubRequestException(
    message,
    statusCode: response.statusCode,
    rateLimited: limited,
    resetAt: limited ? rateLimit.resetAt : null,
  );
}
