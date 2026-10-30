import 'package:flutter/material.dart';
import 'package:reaprime/src/util/remote_error.dart';

SnackBar remoteErrorSnackBar(
  Object error, {
  required String action,
  VoidCallback? onRetry,
}) => SnackBar(
  content: Text(remoteErrorMessage(error, action: action)),
  action: onRetry == null
      ? null
      : SnackBarAction(label: 'Retry', onPressed: onRetry),
);
