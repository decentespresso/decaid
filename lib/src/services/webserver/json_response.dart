import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';

const _jsonHeaders = {'Content-Type': 'application/json'};

Response jsonOk(Object? data) =>
    Response.ok(jsonEncode(data), headers: _jsonHeaders);

Response jsonOkConditional(Request request, Object? data) {
  final body = jsonEncode(data);
  final digest = sha256.convert(utf8.encode(body)).toString().substring(0, 16);
  final etag = '"$digest"';

  final ifNoneMatch = request.headers['if-none-match']?.trim();
  if (ifNoneMatch != null && (ifNoneMatch == '*' || ifNoneMatch == etag)) {
    return Response.notModified(headers: {'ETag': etag});
  }

  return Response.ok(body, headers: {..._jsonHeaders, 'ETag': etag});
}

Response jsonCreated(Object? data) =>
    Response(201, body: jsonEncode(data), headers: _jsonHeaders);

Response jsonAccepted([Object? data]) => Response(
  202,
  body: data != null ? jsonEncode(data) : null,
  headers: _jsonHeaders,
);

Response jsonMultiStatus(Object? data) =>
    Response(207, body: jsonEncode(data), headers: _jsonHeaders);

Response jsonBadRequest(Object? data) =>
    Response.badRequest(body: jsonEncode(data), headers: _jsonHeaders);

Response jsonForbidden(Object? data) =>
    Response(403, body: jsonEncode(data), headers: _jsonHeaders);

Response jsonUnauthorized(Object? data) =>
    Response(401, body: jsonEncode(data), headers: _jsonHeaders);

Response jsonNotFound(Object? data) =>
    Response.notFound(jsonEncode(data), headers: _jsonHeaders);

Response jsonConflict(Object? data) =>
    Response(409, body: jsonEncode(data), headers: _jsonHeaders);

Response jsonRequestTimeout(Object? data) =>
    Response(408, body: jsonEncode(data), headers: _jsonHeaders);

Response jsonPayloadTooLarge(Object? data) =>
    Response(413, body: jsonEncode(data), headers: _jsonHeaders);

Response jsonTooManyRequests(Object? data) =>
    Response(429, body: jsonEncode(data), headers: _jsonHeaders);

Response jsonError(Object? data) =>
    Response.internalServerError(body: jsonEncode(data), headers: _jsonHeaders);

Response jsonNotImplemented(Object? data) =>
    Response(501, body: jsonEncode(data), headers: _jsonHeaders);

Response jsonBadGateway(Object? data) =>
    Response(502, body: jsonEncode(data), headers: _jsonHeaders);

Response jsonServiceUnavailable(Object? data) =>
    Response(503, body: jsonEncode(data), headers: _jsonHeaders);

Response jsonGatewayTimeout(Object? data) =>
    Response(504, body: jsonEncode(data), headers: _jsonHeaders);
