import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:reaprime/src/services/storage/new_owner_recovery_admission.dart';
import 'package:reaprime/src/services/storage/new_owner_reset_journal.dart';
import 'package:reaprime/src/services/storage/process_session_identity.dart';

const String newOwnerRecoveryLockFileName = 'owner.lock';

const String newOwnerRecoveryClaimPrefix = 'owner-';

const String newOwnerRecoveryClaimSuffix = '.claim';

/// Resolves the claim file name owned by one process-session identity.
///
/// The identity is encoded rather than used verbatim so every platform accepts
/// the name and no two identities can collapse into the same file.
String newOwnerRecoveryClaimFileName(String processSessionId) {
  final token = base64Url
      .encode(utf8.encode(processSessionId))
      .replaceAll('=', '');
  return '$newOwnerRecoveryClaimPrefix$token$newOwnerRecoveryClaimSuffix';
}

/// The single authoritative holder of new-owner recovery state for one process.
///
/// Nothing else in the app opens the journal. [open] first reads the marker
/// without claiming, so an absent marker leaves the filesystem untouched and
/// normal startup unchanged. When a marker exists it establishes ownership over
/// both boundaries before deciding: an exclusively created claim file excludes
/// every other engine in this process, because POSIX record locks are per
/// process, and a process-lifetime advisory lock excludes other Decaid
/// processes. The claim is taken first so a refused engine never opens the lock
/// file at all: closing any descriptor for it would drop the locks this process
/// already holds on that inode. Only then does it re-read the marker and decide
/// startup admission.
final class NewOwnerRecoveryStartup {
  NewOwnerRecoveryStartup._(
    this._ownership, {
    required this.admission,
    this.journal,
    this.journalPath,
  });

  static Future<NewOwnerRecoveryStartup> open({
    required String recoveryDirectory,
    String? processSessionId,
    ProcessSessionIdentityResolver? identity,
  }) async {
    final journalPath = p.join(recoveryDirectory, newOwnerResetJournalFileName);
    final store = NewOwnerResetJournalFileStore(File(journalPath));

    if (store.read() is NewOwnerResetJournalAbsent) {
      return NewOwnerRecoveryStartup._(
        null,
        admission: const NewOwnerRecoveryAdmissionDecision(
          NewOwnerRecoveryAdmission.normalStartup,
        ),
        journalPath: journalPath,
      );
    }

    final session =
        processSessionId ??
        await (identity ?? ProcessSessionIdentityResolver()).resolve();
    if (session == null || session.trim().isEmpty) {
      return NewOwnerRecoveryStartup._(
        null,
        admission: const NewOwnerRecoveryAdmissionDecision(
          NewOwnerRecoveryAdmission.uncertain,
          detail:
              'recovery state exists but this platform exposes no process-level '
              'identity, so no instance can own it',
        ),
        journalPath: journalPath,
      );
    }

    final claim = NewOwnerRecoveryClaim.tryClaim(
      Directory(recoveryDirectory),
      session,
    );
    if (claim == null) {
      final claimPath = p.join(
        recoveryDirectory,
        newOwnerRecoveryClaimFileName(session),
      );
      return NewOwnerRecoveryStartup._(
        null,
        admission: NewOwnerRecoveryAdmissionDecision(
          NewOwnerRecoveryAdmission.uncertain,
          detail: File(claimPath).existsSync()
              ? 'another engine in this Decaid process owns new-owner recovery '
                    'state; this instance will not start normal services'
              : 'the new-owner recovery ownership claim could not be created',
        ),
        journalPath: journalPath,
      );
    }

    NewOwnerRecoveryLock? lock;
    try {
      lock = NewOwnerRecoveryLock.tryAcquire(
        File(p.join(recoveryDirectory, newOwnerRecoveryLockFileName)),
      );
    } on FileSystemException catch (error) {
      claim.release();
      return NewOwnerRecoveryStartup._(
        null,
        admission: NewOwnerRecoveryAdmissionDecision(
          NewOwnerRecoveryAdmission.uncertain,
          detail:
              'the recovery directory could not be locked: ${error.message}',
        ),
        journalPath: journalPath,
      );
    }
    if (lock == null) {
      claim.release();
      return NewOwnerRecoveryStartup._(
        null,
        admission: const NewOwnerRecoveryAdmissionDecision(
          NewOwnerRecoveryAdmission.uncertain,
          detail:
              'another Decaid process owns new-owner recovery state; this '
              'instance will not start normal services',
        ),
        journalPath: journalPath,
      );
    }

    final lease = NewOwnerResetJournalLease();
    final journal = NewOwnerResetJournal(
      store,
      processSessionId: session,
      authority: lease,
    );
    final result = journal.load();
    if (result is NewOwnerResetJournalAbsent) {
      lock.release();
      claim.release();
      return NewOwnerRecoveryStartup._(
        null,
        admission: const NewOwnerRecoveryAdmissionDecision(
          NewOwnerRecoveryAdmission.uncertain,
          detail:
              'new-owner recovery state disappeared while ownership was being '
              'established',
        ),
        journalPath: journalPath,
      );
    }
    return NewOwnerRecoveryStartup._(
      _NewOwnerRecoveryOwnership(lock, claim, lease),
      admission: decideNewOwnerRecoveryAdmission(
        result,
        processSessionId: session,
      ),
      journal: journal,
      journalPath: journalPath,
    );
  }

  final NewOwnerRecoveryAdmissionDecision admission;

  /// Null when ownership could not be established, which is itself an uncertain
  /// admission. A journal is reachable only through a claimed owner, and it
  /// stops accepting mutations as soon as [release] revokes its lease.
  final NewOwnerResetJournal? journal;
  final String? journalPath;

  /// Deliberately private: releasing ownership is only available through
  /// [release], which revokes the journal lease before anything on disk can
  /// make a successor the owner.
  final _NewOwnerRecoveryOwnership? _ownership;

  var _released = false;

  bool get blocksNormalStartup => admission.blocksNormalStartup;

  /// Runs once between the two ownership releases, so a test can observe the
  /// window a competing engine would have to interleave into.
  @visibleForTesting
  void Function()? releaseInterleaving;

  /// Releases ownership once. Repeated calls are no-ops, so a stale startup
  /// instance cannot remove a successor's claim or lock.
  ///
  /// The journal lease is revoked first, so the published handle mutates
  /// nothing from the moment any part of ownership starts disappearing. The
  /// descriptor is then unlocked and closed before the claim is removed, so no
  /// engine can claim this identity and take the process lock in between and
  /// then lose that lock to this release.
  void release() {
    if (_released) return;
    _released = true;
    final ownership = _ownership;
    ownership?.lease.revoke();
    ownership?.lock.release();
    final interleaving = releaseInterleaving;
    releaseInterleaving = null;
    interleaving?.call();
    ownership?.claim.release();
  }
}

final class _NewOwnerRecoveryOwnership {
  const _NewOwnerRecoveryOwnership(this.lock, this.claim, this.lease);

  final NewOwnerRecoveryLock lock;
  final NewOwnerRecoveryClaim claim;
  final NewOwnerResetJournalLease lease;
}

/// Runs exactly one startup branch for [startup].
///
/// This is the production composition boundary `main()` uses: no normal service
/// callback can run unless the admission permits normal startup, and every other
/// admission presents the blocked recovery state instead.
Future<void> runNewOwnerRecoveryStartup({
  required NewOwnerRecoveryStartup startup,
  required Future<void> Function() startNormalServices,
  required void Function(NewOwnerRecoveryAdmissionDecision admission)
  presentBlocked,
}) async {
  if (startup.admission.permitsNormalStartup) {
    await startNormalServices();
    return;
  }
  presentBlocked(startup.admission);
}

final class NewOwnerRecoveryClaim {
  NewOwnerRecoveryClaim._(this.path, this._token);

  /// Atomically creates this process identity's claim file and records the
  /// owning instance in it by token.
  ///
  /// Creation is exclusive, so exactly one engine per process identity wins and
  /// the losers fail closed without opening any other ownership file. Claims
  /// left by other process identities are ignored: the advisory lock already
  /// proves that process is gone, and no owner ever deletes another owner's
  /// claim.
  static NewOwnerRecoveryClaim? tryClaim(
    Directory directory,
    String processSessionId,
  ) {
    final path = p.join(
      directory.path,
      newOwnerRecoveryClaimFileName(processSessionId),
    );
    final file = File(path);
    try {
      file.createSync(exclusive: true);
    } on FileSystemException {
      return null;
    }
    final token = _newClaimToken();
    try {
      file.writeAsStringSync(token, flush: true);
    } on FileSystemException {
      _deleteQuietly(file);
      return null;
    }
    return NewOwnerRecoveryClaim._(path, token);
  }

  final String path;
  final String _token;
  bool _released = false;

  /// Idempotent and token-bound: the claim is removed once, and only by the
  /// instance that created it.
  ///
  /// A second [release] after a successor with the same process identity has
  /// claimed must not delete the successor's claim, and must not drop ownership
  /// the caller no longer has.
  void release() {
    if (_released) return;
    _released = true;
    final file = File(path);
    try {
      if (file.readAsStringSync() != _token) return;
    } on FileSystemException {
      return;
    }
    _deleteQuietly(file);
  }
}

int _claimTokenSequence = 0;

String _newClaimToken() {
  _claimTokenSequence++;
  final entropy = Random().nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
  return 'new-owner-claim:$pid:${DateTime.now().microsecondsSinceEpoch}:'
      '$_claimTokenSequence:$entropy';
}

void _deleteQuietly(File file) {
  try {
    file.deleteSync();
  } on FileSystemException {
    // A claim that cannot be removed keeps blocking this process identity and
    // changes no recovery state.
  }
}

/// A process-lifetime advisory lock over the recovery directory.
///
/// This excludes other Decaid processes. POSIX record locks are per process, so
/// it cannot exclude a second engine inside this process; [NewOwnerRecoveryClaim]
/// covers that boundary and is taken first, so no refused engine ever opens or
/// closes a descriptor for this file.
final class NewOwnerRecoveryLock {
  NewOwnerRecoveryLock._(this._handle);

  static NewOwnerRecoveryLock? tryAcquire(File lockFile) {
    final handle = lockFile.openSync(mode: FileMode.append);
    try {
      handle.lockSync(FileLock.exclusive);
    } on FileSystemException {
      handle.closeSync();
      return null;
    }
    return NewOwnerRecoveryLock._(handle);
  }

  RandomAccessFile? _handle;

  void release() {
    final handle = _handle;
    if (handle == null) return;
    _handle = null;
    try {
      handle.unlockSync();
    } on FileSystemException {
      // The lock is advisory and dies with the descriptor.
    }
    try {
      handle.closeSync();
    } on FileSystemException {
      // Closing an already-closed descriptor cannot change the admission.
    }
  }
}
