import 'package:flutter/material.dart';
import 'package:reaprime/src/settings/backup_import_response.dart';

SnackBar backupImportErrorSnackBar(BackupImportException error) => SnackBar(
  content: Text(error.userMessage),
  duration: error.reason == 'too_many_entries'
      ? const Duration(seconds: 12)
      : const Duration(seconds: 4),
);
