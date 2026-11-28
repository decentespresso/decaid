import 'package:reaprime/src/services/storage/new_owner_reset_journal.dart';

/// What the recovery journal requires from this process before any normal
/// Decaid service starts.
enum NewOwnerRecoveryAdmission {
  /// No journal exists: the existing normal startup runs unchanged.
  normalStartup,

  /// A reset started and did not finish: guarded recovery only.
  resetInProgress,

  /// The reset finished and is terminal until an explicit handoff.
  readyForNewOwner,

  /// The handoff was armed by this process, so this process stays terminal.
  handoffArmedThisProcess,

  /// The handoff was armed by an earlier process. This is eligibility only:
  /// the marker does not prove any store was erased or restored, so normal
  /// customer startup is not admitted here either.
  handoffEligible,

  /// The marker is missing, unreadable, ambiguous, or owned elsewhere. Fail
  /// closed with a visible recovery error.
  uncertain,
}

final class NewOwnerRecoveryAdmissionDecision {
  const NewOwnerRecoveryAdmissionDecision(this.kind, {this.detail});

  final NewOwnerRecoveryAdmission kind;

  /// Operator-readable, non-secret explanation for [kind].
  final String? detail;

  bool get permitsNormalStartup =>
      kind == NewOwnerRecoveryAdmission.normalStartup;

  /// False only for [NewOwnerRecoveryAdmission.normalStartup]; a blocked
  /// admission never starts accounts, telemetry, uploads, plugins, skins, the
  /// API, or the database.
  bool get blocksNormalStartup => !permitsNormalStartup;
}

NewOwnerRecoveryAdmissionDecision decideNewOwnerRecoveryAdmission(
  NewOwnerResetJournalReadResult result, {
  required String processSessionId,
}) {
  switch (result) {
    case NewOwnerResetJournalAbsent():
      return const NewOwnerRecoveryAdmissionDecision(
        NewOwnerRecoveryAdmission.normalStartup,
      );
    case NewOwnerResetJournalPresent(:final record):
      switch (record.state) {
        case NewOwnerResetState.resetting:
          return NewOwnerRecoveryAdmissionDecision(
            NewOwnerRecoveryAdmission.resetInProgress,
            detail:
                'reset stage ${record.stage!.name} is outstanding; the reset '
                'must be resumed and verified before normal startup',
          );
        case NewOwnerResetState.ready:
          return const NewOwnerRecoveryAdmissionDecision(
            NewOwnerRecoveryAdmission.readyForNewOwner,
            detail: 'the reset is complete and awaits an explicit handoff',
          );
        case NewOwnerResetState.handoffArmed:
          if (record.armedBySessionId == processSessionId) {
            return const NewOwnerRecoveryAdmissionDecision(
              NewOwnerRecoveryAdmission.handoffArmedThisProcess,
              detail:
                  'this process armed the handoff; it must not consume its own '
                  'handoff',
            );
          }
          return const NewOwnerRecoveryAdmissionDecision(
            NewOwnerRecoveryAdmission.handoffEligible,
            detail:
                'an earlier process armed the handoff; eligibility alone does '
                'not prove any store was erased or restored',
          );
      }
    case NewOwnerResetJournalUnreadable(:final reason):
      return NewOwnerRecoveryAdmissionDecision(
        NewOwnerRecoveryAdmission.uncertain,
        detail: reason,
      );
  }
}
