# New-owner reset: isolated journal foundation

This bounded part of #1259 supplies a schema, transitions and explicitly supplied file persistence.
It has no production imports/callers, startup barrier, UI, destructive entry point or live-store
reset adapter. It does not reset onboarding, application data, accounts, telemetry or devices.
[Inventory](inventory.md) and [native capability findings](capabilities.md) retain the broader
rationale and unresolved requirements. This slice is not the complete new-owner reset feature.

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

A future native workflow must keep the acknowledging process terminal, offer explicit finish/close,
and consume only behind an early startup barrier in a later process. Neither UI nor close/launch
behavior is implemented here. Process identities are injected: callers must supply one stable,
non-secret identity for the process lifetime, different after restart. Tests model identities;
they do not establish an OS-wide identity mechanism. PID reuse, fresh object construction or an
isolate-local static must not be mistaken for a new process. One writer owns the journal; no
cross-isolate/process coordination or locking is supplied.

## Filesystem boundary and limits

The caller supplies one file in an isolated, owned directory; no AppDirectories/live app path is
resolved. The file store stages `<file>.tmp`, writes/flushes/closes, then renames over the canonical
file. Regular stale staging is not read as an acknowledged handoff. Directory/link/non-regular
canonical/staging paths are rejected rather than followed or recursively deleted. Failure cleanup
only attempts the regular staged file. These checks are not atomic protection against hostile
concurrent path swaps; the directory must be trusted and the single-writer boundary enforced.

The in-memory record changes only after the store operation returns successfully. Tested failures
are pre-commit write/staging/access faults. There is no claim that every filesystem can preserve the
old canonical file after every native replace failure or ambiguous commit result. On this host,
Dart delete can report PathNotFoundException under an inaccessible parent; absence confirmation uses
an access-sensitive length lookup rather than trusting typeSync/existsSync alone.

Isolated filesystem tests run on the host filesystem; rename atomicity/replacement on other
platforms is not established. File flush is used, but the directory is not fsynced. There is **no
power-loss durability guarantee**, physical process-kill test, or native-platform erasure evidence.
Modelled pre/post-replace fixtures are not such evidence. A lost marker after destructive work
would be unsafe: production integration must first establish durable marker/startup recovery
semantics rather than interpreting this foundation as power-loss-safe admission.

## Verification surface

`test/unit/services/storage/new_owner_reset_journal_test.dart` covers ordered transitions,
duplicates, strict schema/payload rejection, missing/unreadable paths, outbound validation, isolated
file replacement, staging/symlink sentinels, failed writes/acknowledgement/consume, ready without
acknowledgement, rebuilt same-session owners, modelled later-session consumption and staged versus
committed acknowledgement fixtures. Non-root POSIX permission cases are platform-conditional.

Focused check:

```sh
flutter test test/unit/services/storage/new_owner_reset_journal_test.dart
```

The full repository analyze/test gates remain required for this change. No test of this module
proves deletion/restoration/readback of application stores, zero hardware writes, native SDK purge,
WebView cleanup, or customer onboarding. Those remain separate implementation boundaries requiring
review and appropriate execution authorization before any destructive feature is exposed.
