# New-owner reset: isolated journal foundation

This bounded part of #1259 supplies a schema, transitions and explicitly supplied file persistence.
It performs no destructive work and resets no onboarding, application data, accounts, telemetry or
devices. [Inventory](inventory.md) and [native capability findings](capabilities.md) retain the
broader rationale and unresolved requirements.

Since [the recovery-admission slice](recovery-admission-slice.md), the journal also has one production
caller: `main()` opens it through `NewOwnerRecoveryStartup` before Firebase and every normal service,
and a blocked admission presents `NewOwnerRecoveryApp` instead of starting them. That slice adds the
owned on-disk location, the cross-process lock, the per-process identity claim, the ambiguity-safe
file store and the kernel-backed process-session identity; the schema and transition contract below
is unchanged.

## State contract

Schema version 1 contains only state, outstanding stage, retained machine/scale IDs, optional skin
ID/package reference, and the opaque session ID that acknowledged handoff. Unknown fields at every
level, missing fields, wrong types, unknown versions/states/stages and inconsistent state fields
fail closed. Typed outbound configuration is validated before journal transitions write or publish.
The low-level file store is an internal persistence seam; transition validation belongs to the
journal API. No arbitrary map, credential, consent, queue, user data or backup payload is carried.

`resetting(deletion)` → `resetting(restoration)` → `resetting(verification)` → `ready` → `handoffArmed`.

- Completing the outstanding stage advances; repeating an earlier completed stage does nothing.
  Skipping stages or completing stages after ready is rejected. Completion records the caller's
  assertion, not proof any real store was erased.
- Starting over an existing journal is rejected: recovery must resume it, not clobber it.
- Ready remains terminal until explicit acknowledgement. Acknowledgement writes handoffArmed
  before publishing acceptance; duplicate acknowledgement is rejected without advancing state.
- The acknowledging session cannot consume handoff, even through a newly constructed object.
  A different supplied process-session identity can consume it by deleting the journal. Failed
  deletion leaves the in-memory armed record and recovery data available for retry.
- Missing journal is an explicit absent result. Corrupt/unreadable/non-regular paths are not absent;
  transitions require a successful load and refuse to overwrite an unreadable journal.

A native workflow must keep the acknowledging process terminal, offer explicit finish/close, and
consume only behind an early startup barrier in a later process. Close/launch behaviour and handoff
consumption are still not implemented: the admission slice treats a later-process handoff as
eligibility only. Process identities are supplied by `ProcessSessionIdentityResolver` (or injected by
tests) as one stable, non-secret identity for the process lifetime, different after restart, derived
from kernel facts on Android/Linux and from a native process-start-time channel on iOS/macOS; there is
no PID-plus-clock fallback, and an unresolved identity fails closed. See
[recovery-admission-slice.md](recovery-admission-slice.md). PID reuse, fresh object construction or an
isolate-local static is never mistaken for a new process. One owner holds the journal per process
identity: a cross-process advisory lock plus an exclusively created per-identity claim file.

The kernel branch is verified across real processes rather than only through fakes: the focused test
launches `test/unit/services/storage/process_identity_probe.dart` as a plain-Dart child (a separate
process with no engine) that resolves the same production function, and requires both launches to be
non-empty, to differ from the parent's identity and to differ from each other; on a host without
kernel sources the launch still runs and reports the absence instead of skipping. That check was also
re-run on a Linux `aarch64` host, where one parent and two child launches produced three distinct
`proc:<boot id>:<pid>:<ticks>` values sharing one boot id. An earlier revision expected a child to
resolve the parent's identity, which is false by construction.

## Filesystem boundary and limits

The caller supplies one file in an isolated, owned directory. Production resolves
`<support>/new-owner-recovery` through `AppDirectories`; see
[recovery-admission-slice.md](recovery-admission-slice.md) for the namespace boundary and the
platform durability limits. The file store stages `<file>.tmp`, writes/flushes/closes, then renames
over the canonical file. Regular stale staging is not read as an acknowledged handoff.
Directory/link/non-regular canonical/staging paths are rejected rather than followed or recursively
deleted. Failure cleanup only attempts the regular staged file. These checks are not atomic
protection against hostile concurrent path swaps; the directory must be trusted and the
single-writer boundary enforced.

The in-memory record changes only after the store operation returns successfully. A persistence
failure whose outcome cannot be established is reported as
`NewOwnerResetJournalIndeterminateWriteException` (a `NewOwnerResetJournalWriteException`) and leaves
the instance refusing mutation until it reloads. On this host, Dart delete can report
PathNotFoundException under an inaccessible parent; absence confirmation therefore does not trust
`typeSync`/`existsSync` alone.

Every handle also requires a `NewOwnerResetJournalLease` from the composition that owns it. A revoked
lease makes all four mutators throw `NewOwnerResetJournalLeaseRevokedException` before any read or
write, and `load()` never restores authority; see
[recovery-admission-slice.md](recovery-admission-slice.md) for the release ordering.

Isolated filesystem tests run on the host filesystem; rename atomicity/replacement on other
platforms is not established. File flush is used, but the directory is not fsynced. There is **no**
power-loss durability guarantee. A process-kill probe (marker written, writer SIGKILLed, a separate
process read the record) is process-termination evidence only. A lost marker after destructive work
would be unsafe, so every platform stays destructive-reset-disabled until directory durability is
established.

## Verification surface

`test/unit/services/storage/new_owner_reset_journal_test.dart` covers ordered transitions,
duplicates, strict schema/payload rejection, invalid UTF-8, nested skin shape, missing/unreadable
paths, outbound validation, isolated file replacement, staging/symlink sentinels, injected
byte-write/flush/close/rename/delete faults, ambiguous commit classification, competing stale owner
instances, failed acknowledgement/consume, ready without acknowledgement, rebuilt same-session
owners, revoked-authority refusals for every mutator with a reload in between, and modelled
later-session consumption. Non-root POSIX permission cases are platform-conditional.

Focused check:

```sh
flutter test test/unit/services/storage/new_owner_reset_journal_test.dart
```

The full repository analyze/test gates remain required for this change. No test of this module
proves deletion/restoration/readback of application stores, zero hardware writes, native SDK purge,
WebView cleanup, or customer onboarding. Those remain separate implementation boundaries requiring
review and appropriate execution authorization before any destructive feature is exposed.

The presentation side of the admission was later observed on an authorised offline API 35 emulator
(debug and profile builds, synthetic markers, no credentials or account actions): every blocked or
uncertain marker rendered the blocked or error state and produced no normal-service log lines, and the
absent marker started normally. That supersedes any reading of this document as "modelled only", but
only for Android startup behaviour: journal durability across process kill, filesystem semantics
beyond the host, power loss, handoff consumption and Apple platforms remain unproven, and the
initialisation-fencing runs are not erasure evidence. See
[capabilities.md](capabilities.md#android-emulator-observations-after-deferral) for the boundary of
that run and the superseded pre-deferral counterexample.
