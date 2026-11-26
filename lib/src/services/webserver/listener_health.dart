import 'dart:io';

class ListenerHealth {
  const ListenerHealth._();

  static Future<bool> probe(
    Uri uri, {
    Duration timeout = const Duration(seconds: 2),
    int? expectedStatus,
    String? expectedLocation,
    String? expectedContentType,
  }) async {
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
      return expectedStatus != null ||
          (response.statusCode >= 200 && response.statusCode < 500);
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }
}
