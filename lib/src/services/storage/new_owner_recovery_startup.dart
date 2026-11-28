import 'dart:io';

import 'package:reaprime/src/services/storage/new_owner_recovery_admission.dart';
import 'package:reaprime/src/services/storage/new_owner_recovery_owner.dart';

const String newOwnerRecoveryDiagnosticsFileName = 'recovery-startup.log';

/// Appends one line to the recovery diagnostics file and returns its path.
///
/// Returns null when the file cannot be written. The file is separate from the
/// normal rotating log, so a blocked launch never creates or truncates it.
Future<String?> writeNewOwnerRecoveryDiagnostics({
  required String logDirectory,
  required String message,
  DateTime? timestamp,
}) async {
  try {
    final directory = Directory(logDirectory);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
    final file = File('$logDirectory/$newOwnerRecoveryDiagnosticsFileName');
    final at = (timestamp ?? DateTime.now()).toUtc().toIso8601String();
    await file.writeAsString(
      '$at $message\n',
      mode: FileMode.append,
      flush: true,
    );
    return file.path;
  } catch (_) {
    return null;
  }
}

/// The startup composition boundary `main()` uses.
///
/// Exactly one branch runs. Normal diagnostics are initialised only for an
/// admitted startup, and immediately before the normal services they belong to.
/// A failure to resolve the recovery directory, open the journal or initialise
/// normal diagnostics reaches [presentFailure] instead of starting a partial
/// app, and no normal service callback runs in that case. Recovery diagnostics
/// are best effort: their failure never suppresses [presentRecovery] or
/// [presentFailure].
Future<void> runNewOwnerRecoveryStartup({
  required Future<NewOwnerRecoveryStartup> Function() open,
  required Future<void> Function() openNormalDiagnostics,
  required Future<void> Function() startNormalServices,
  required Future<String?> Function(String message) writeRecoveryDiagnostics,
  required void Function(
    NewOwnerRecoveryAdmissionDecision admission,
    String? logFilePath,
  )
  presentRecovery,
  required void Function(
    Object error,
    StackTrace stackTrace,
    String? logFilePath,
  )
  presentFailure,
}) async {
  Future<String?> describeRecovery(String message) async {
    try {
      return await writeRecoveryDiagnostics(message);
    } catch (_) {
      return null;
    }
  }

  final NewOwnerRecoveryStartup startup;
  try {
    startup = await open();
  } catch (error, stackTrace) {
    presentFailure(
      error,
      stackTrace,
      await describeRecovery('new-owner recovery could not be opened: $error'),
    );
    return;
  }

  if (!startup.admission.permitsNormalStartup) {
    presentRecovery(
      startup.admission,
      await describeRecovery(
        'new-owner recovery state "${startup.admission.kind.name}" blocks '
        'normal startup: ${startup.admission.detail}',
      ),
    );
    return;
  }

  try {
    await openNormalDiagnostics();
  } catch (error, stackTrace) {
    presentFailure(
      error,
      stackTrace,
      await describeRecovery(
        'startup diagnostics could not be initialised: $error',
      ),
    );
    return;
  }

  await startNormalServices();
}
