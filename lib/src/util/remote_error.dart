import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:reaprime/src/util/remote_update_exception.dart';
import 'package:reaprime/src/util/user_facing_exception.dart';

class RemoteServiceException implements Exception {
  final int statusCode;
  final String userMessage;

  const RemoteServiceException(this.statusCode, this.userMessage);

  @override
  String toString() =>
      'RemoteServiceException: HTTP $statusCode ($userMessage)';
}

RemoteServiceException remoteHttpError(
  int statusCode,
) => RemoteServiceException(statusCode, switch (statusCode) {
  401 => 'Sign in to the service and try again.',
  403 =>
    'The service refused access. Check repository access or try again later.',
  404 =>
    'The repository, release, or download was not found. Check the address and try again.',
  429 => 'The service is receiving too many requests. Try again later.',
  _ => 'The service could not complete the request. Try again later.',
});

String? _connectionAdvice(Object error) => switch (error) {
  TlsException() =>
    'A secure connection could not be established. Try again later.',
  TimeoutException() => 'The connection took too long. Try again.',
  SocketException() ||
  http.ClientException() ||
  HttpException() => 'Check your internet connection and try again.',
  _ => null,
};

String remoteErrorMessage(Object error, {required String action}) {
  final prefix = "Couldn't $action.";
  if (error is RemoteUpdateException) {
    final heading = error.isPartial
        ? "Some updates couldn't be completed."
        : prefix;
    final advice = error.failures
        .map((failure) => _errorAdvice(failure.error))
        .toSet();
    final detail = advice.length == 1
        ? advice.single
        : 'Check the affected items and try again.';
    return '$heading $detail';
  }
  return '$prefix ${_errorAdvice(error)}';
}

String _errorAdvice(Object error) {
  final advice = _connectionAdvice(error);
  if (advice != null) return advice;
  if (error is RemoteServiceException) return error.userMessage;
  if (error is UserFacingException) return error.message;
  if (error is FormatException) {
    return 'The downloaded data or package is invalid. Check the source and try again.';
  }
  if (error is FileSystemException) {
    return 'Check storage space and file permissions, then try again.';
  }
  return 'Try again.';
}
