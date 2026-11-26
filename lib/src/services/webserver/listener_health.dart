import 'dart:convert';
import 'dart:io';
import 'dart:math';

const listenerIdentityHeader = 'x-decaid-listener-id';

String newListenerIdentity() {
  final random = Random.secure();
  return base64UrlEncode(List<int>.generate(16, (_) => random.nextInt(256)));
}

class ListenerHealth {
  const ListenerHealth._();

  static Future<bool> probe(
    Uri uri, {
    Duration timeout = const Duration(seconds: 2),
    int? expectedStatus,
    String? expectedLocation,
    String? expectedContentType,
    String? expectedListenerId,
  }) async {
    if (expectedListenerId != null && expectedListenerId.isEmpty) return false;
    final client = HttpClient()
      ..connectionTimeout = timeout
      ..idleTimeout = timeout
      ..autoUncompress = false;
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.followRedirects = false;
      final response = await request.close().timeout(timeout);
      await response.drain<void>().timeout(timeout);
      if (expectedStatus != null && response.statusCode != expectedStatus) {
        return false;
      }
      if (expectedLocation != null &&
          response.headers.value(HttpHeaders.locationHeader) !=
              expectedLocation) {
        return false;
      }
      if (expectedContentType != null &&
          !(response.headers.value(HttpHeaders.contentTypeHeader) ?? '')
              .toLowerCase()
              .startsWith(expectedContentType.toLowerCase())) {
        return false;
      }
      if (expectedListenerId != null &&
          response.headers.value(listenerIdentityHeader) !=
              expectedListenerId) {
        return false;
      }
      return expectedStatus != null ||
          (response.statusCode >= 200 && response.statusCode < 500);
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
