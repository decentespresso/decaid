import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:shelf/shelf.dart';

import 'json_response.dart';

const smallRequestBodyBytes = 64 * 1024;
const largeRequestBodyBytes = 1024 * 1024;
const smallRequestBodyTimeout = Duration(seconds: 10);
const largeRequestBodyTimeout = Duration(seconds: 30);

final class RequestBodyReadException implements Exception {
  final int statusCode;

  const RequestBodyReadException._(this.statusCode);

  const RequestBodyReadException.tooLarge() : this._(413);

  const RequestBodyReadException.timedOut() : this._(408);

  Response get response => statusCode == 413
      ? jsonPayloadTooLarge({'error': 'Request body is too large'})
      : jsonRequestTimeout({'error': 'Request body timed out'});
}

Middleware requestBodyReadMiddleware() {
  return (innerHandler) {
    return (request) async {
      try {
        return await innerHandler(request);
      } on RequestBodyReadException catch (error) {
        return error.response;
      }
    };
  };
}

Future<Uint8List> readBoundedRequestBody(
  Request request, {
  required int maxBytes,
  Duration timeout = largeRequestBodyTimeout,
}) async {
  final declaredLength = request.contentLength;
  if (declaredLength != null && declaredLength > maxBytes) {
    throw const RequestBodyReadException.tooLarge();
  }

  final deadline = Stopwatch()..start();
  final bytes = BytesBuilder(copy: false);
  final iterator = StreamIterator<List<int>>(request.read());
  try {
    while (true) {
      final remaining = timeout - deadline.elapsed;
      if (remaining <= Duration.zero) {
        throw const RequestBodyReadException.timedOut();
      }
      final hasNext = await iterator.moveNext().timeout(
        remaining,
        onTimeout: () => throw const RequestBodyReadException.timedOut(),
      );
      if (!hasNext) break;
      if (bytes.length + iterator.current.length > maxBytes) {
        throw const RequestBodyReadException.tooLarge();
      }
      bytes.add(iterator.current);
    }
    return bytes.takeBytes();
  } finally {
    await iterator.cancel();
  }
}

Future<String> readBoundedRequestBodyString(
  Request request, {
  required int maxBytes,
  Duration timeout = largeRequestBodyTimeout,
}) async {
  final bytes = await readBoundedRequestBody(
    request,
    maxBytes: maxBytes,
    timeout: timeout,
  );
  return (request.encoding ?? utf8).decode(bytes);
}
