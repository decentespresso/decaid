import 'package:http/http.dart' as http;
import 'package:reaprime/build_info.dart';

const releaseRedirectLimit = 5;

const _redirectStatuses = {301, 302, 303, 307, 308};

const _ownedHeaders = {
  'user-agent',
  'authorization',
  'proxy-authorization',
  'cookie',
};

String releaseUserAgent({String version = BuildInfo.version}) {
  final trimmed = version.trim();
  return 'Decaid/${trimmed.isEmpty ? 'unknown' : trimmed}';
}

Map<String, String> releaseRequestHeaders({
  Map<String, String> headers = const {},
  String version = BuildInfo.version,
}) => {
  for (final entry in headers.entries)
    if (!_ownedHeaders.contains(entry.key.toLowerCase()))
      entry.key: entry.value,
  'User-Agent': releaseUserAgent(version: version),
};

Future<http.StreamedResponse> releaseStreamRequest(
  http.Client client,
  Uri url, {
  String method = 'GET',
  Map<String, String> headers = const {},
  int maxRedirects = releaseRedirectLimit,
}) async {
  var target = url;
  for (var hop = 0; ; hop++) {
    final request = http.Request(method, target)
      ..followRedirects = false
      ..headers.addAll(releaseRequestHeaders(headers: headers));
    final response = await client.send(request);
    final location = response.headers['location'];
    if (hop >= maxRedirects ||
        location == null ||
        !_redirectStatuses.contains(response.statusCode)) {
      return response;
    }
    final next = target.resolve(location);
    if (next.scheme != 'http' && next.scheme != 'https') return response;
    await response.stream.drain<void>();
    target = next;
  }
}

Future<http.Response> releaseGet(
  String url, {
  http.Client? client,
  Map<String, String> headers = const {},
  int maxRedirects = releaseRedirectLimit,
}) => _bufferedReleaseRequest(
  url,
  method: 'GET',
  client: client,
  headers: headers,
  maxRedirects: maxRedirects,
);

Future<http.Response> releaseHead(
  String url, {
  http.Client? client,
  Map<String, String> headers = const {},
  int maxRedirects = releaseRedirectLimit,
}) => _bufferedReleaseRequest(
  url,
  method: 'HEAD',
  client: client,
  headers: headers,
  maxRedirects: maxRedirects,
);

Future<http.Response> _bufferedReleaseRequest(
  String url, {
  required String method,
  required int maxRedirects,
  http.Client? client,
  Map<String, String> headers = const {},
}) async {
  final ownedClient = client == null ? http.Client() : null;
  try {
    final response = await releaseStreamRequest(
      ownedClient ?? client!,
      Uri.parse(url),
      method: method,
      headers: headers,
      maxRedirects: maxRedirects,
    );
    return await http.Response.fromStream(response);
  } finally {
    ownedClient?.close();
  }
}
