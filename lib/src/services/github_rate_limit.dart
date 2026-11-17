import 'package:http/http.dart' as http;

class GithubRateLimit {
  final DateTime Function() _now;
  final Map<String, DateTime> _untilByIdentity = {};

  GithubRateLimit({DateTime Function()? now}) : _now = now ?? DateTime.now;

  DateTime? get resetAt => resetAtFor('anonymous');

  DateTime? resetAtFor(String identityKey) {
    final until = _untilByIdentity[identityKey];
    if (until == null) return null;
    if (_now().isBefore(until)) return until;
    _untilByIdentity.remove(identityKey);
    return null;
  }

  bool get isLimited => isLimitedFor('anonymous');

  bool isLimitedFor(String identityKey) => resetAtFor(identityKey) != null;

  bool recordIfLimited(
    http.Response response, {
    String identityKey = 'anonymous',
  }) {
    final limited =
        (response.statusCode == 403 || response.statusCode == 429) &&
        response.headers['x-ratelimit-remaining'] == '0';
    if (!limited) return false;
    final reset = int.tryParse(response.headers['x-ratelimit-reset'] ?? '');
    if (reset != null && reset >= 0 && reset <= 8640000000000) {
      _untilByIdentity[identityKey] = DateTime.fromMillisecondsSinceEpoch(
        reset * 1000,
        isUtc: true,
      );
    }
    return true;
  }
}
