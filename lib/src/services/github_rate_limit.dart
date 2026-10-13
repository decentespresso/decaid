import 'package:http/http.dart' as http;

class GithubRateLimit {
  final DateTime Function() _now;
  DateTime? _until;

  GithubRateLimit({DateTime Function()? now}) : _now = now ?? DateTime.now;

  DateTime? get resetAt {
    final until = _until;
    if (until == null) return null;
    if (_now().isBefore(until)) return until;
    _until = null;
    return null;
  }

  bool get isLimited => resetAt != null;

  bool recordIfLimited(http.Response response) {
    final limited =
        (response.statusCode == 403 || response.statusCode == 429) &&
        response.headers['x-ratelimit-remaining'] == '0';
    if (!limited) return false;
    final reset = int.tryParse(response.headers['x-ratelimit-reset'] ?? '');
    if (reset != null && reset >= 0 && reset <= 8640000000000) {
      _until = DateTime.fromMillisecondsSinceEpoch(reset * 1000, isUtc: true);
    }
    return true;
  }
}
