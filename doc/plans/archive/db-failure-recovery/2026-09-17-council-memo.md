# Council Memo — Database-Failure Recovery Actions

Date: 2026-09-17
Plan reviewed: `doc/plans/db-failure-support-package/2026-09-17-plan.md`

## Question and scope

Should the database-failure screen get two actions — save the user's data to a
file, and a destructive reset — and are the reset semantics, the archive
extraction, and the packer implementation right? In scope: safety/UX of the
reset, the scrub set, the shared archive/save extraction, the packer primitive,
and module layering. Out of scope: a restore/import flow, and changing the
server export endpoint.

## Roster, passes, fallbacks

| Slot | Agent | Requested context | Model | Run |
| --- | --- | --- | --- | --- |
| Advisor 1 | `oracle` | `fork` (inherits parent session) | `gpt-5.6-sol:high` | `61c1b6b2` |
| Advisor 2 | `reviewer` | `runtime-default-unknown` (fresh) | `gpt-5.6-sol:high` | `92b1af56` |

No `council-*` profiles exist on this machine, so both slots used the skill's
documented fallbacks. The `oracle` fallback is **forked and context-aware**; the
`reviewer` fallback kept its normal fresh context. Passes run: 1. Pass 2 was not
needed — see Convergence. Workflow run `6df5a6a4`.

## Recommendation

Revise the plan, then implement. Both advisors returned **high confidence** and
agreed on every material point except the scrub set, which is an owner decision.

The single most valuable finding: **`AppDirectories.logs` is the whole support
root on mobile** (`lib/src/services/storage/app_directories.dart:14-27`,
`doc/AI_STORAGE_NOTES.md:31`). The plan's recursive log walk would have embedded
the SQLite database, the Hive store, plugins, and web-ui inside a `logs/`
prefix, duplicating the entire tree into the recovery package. Log collection
must be an explicit allowlist of `log.txt` and `webview_console.log`.

## Claim matrix

### Agreements (accepted)

| # | Claim | Sources | Disposition |
| --- | --- | --- | --- |
| A1 | Recursive log walk is unsafe; mobile `logs == support`. Allowlist the two log files. | `app_directories.dart:14-27`, `AI_STORAGE_NOTES.md:31` | Accept, plan bug |
| A2 | Promote `StreamingZipWriter` now; `archive` buffers compressed entries, which is the SQLite case. | `AI_API_NOTES.md:322-323`, `streaming_zip_writer.dart:31-38,243-289`, `test/data_export/streaming_zip_test.dart` | Accept, reverses plan |
| A3 | Serialize the two actions; disable both while either runs, so reset cannot race the packer. | plan `:175-185` | Accept |
| A4 | "Save all data" is inaccurate — SharedPreferences and the secure store are not included. Rename. | `AI_STORAGE_NOTES.md:45-52` | Accept |
| A5 | Reset's rename does **not** guarantee escape from a Windows-held handle; startup tolerates close failure. Report partial failure honestly. | `database.dart:53-74` | Accept, plan overstated |
| A6 | Mobile share cleanup must stay deferred — the OS share sheet reads the file asynchronously. | `AI_API_NOTES.md:367-370`, `temp_archive_files.dart` | Accept, plan said "always disposed" |
| A7 | `deliverArchive` alone does not remove the double write; `BackupTransferService.downloadExportZip` takes a `Directory` and hardcodes `export.zip`. | `backup_transfer_service.dart:28-54` | Accept, plan incomplete |
| A8 | Database reset belongs under `services/storage/`, not `services/export/`. | layering | Accept |
| A9 | Resolve `AppDirectories` paths before `Isolate.run`; the resolver calls `path_provider`. | `app_directories.dart:14-20` | Accept |
| A10 | Make the view callbacks required and wire concrete functions at the composition point. | `AGENTS.md:80-85` | Accept |
| A11 | Resolve open questions 1-3 now (exclude plugins/web-ui, single confirmation, instruct manual reopen); defer the logical-dump question. | plan `:277-291` | Accept |

### Rejected

| # | Claim | Reason for rejection |
| --- | --- | --- |
| R1 | "`archive`'s default is level 6 is false; public `ZipEncoder` defaults to `bestSpeed`." | Partly right, but not a plan defect. `ZipFileEncoder.create()` passes `level: level` explicitly, so a `null` argument overrides `startEncode`'s `bestSpeed` default and `add()` falls back to `?? 6` (`zip_encoder.dart:128,249`). The plan's claim was correct **for `ZipFileEncoder`**; the reviewer's correction holds for direct `ZipEncoder` calls. Moot after A2, since `StreamingZipWriter` hardcodes `level: 6` in `ZLibCodec` and we are making that configurable. |
| R2 | Include Hive in the scrub set unconditionally. | See owner decision O1. Hive is plugin KV state, not the failing database (`main.dart:585`, `plugin_manager.dart:83`, `ws/kv_store_handler.dart:4`), so this is product intent, not an evidence question. |

### Disputed, resolved to an owner decision

**O1 — Hive in the reset scope.** `oracle`: remove only SQLite + WAL/SHM; Hive
is plugin state, not the failing database. `reviewer`: include Hive; the scrub
set is right. Evidence settles what Hive *is* but not what the user wants
"reset database" to mean. Parent recommendation: **include Hive**, because the
recovery package already contains `store/` and an export/reset pair that is
asymmetric leaves stale plugin KV pointing at a deleted database. Not
independent of the label decision in A4.

## Owner decisions

1. **Reset scope.** Database-only (SQLite trio) vs database + Hive (recommended,
   symmetric with the package). Explicitly out of scope either way:
   `SharedPreferences` and secure credentials, per
   `AI_STORAGE_NOTES.md:52` ("a settings reset must not clear account
   credentials unless explicitly requested").
2. **Naming.** "Save recovery package" / "Reset local database" (recommended) vs
   expanding the export to genuinely cover all stores.
3. **Packer memory strategy.** Promote `StreamingZipWriter` now (recommended by
   both advisors and by `AI_API_NOTES.md:322-323`) vs accept `ZipFileEncoder`'s
   one-entry buffer on low-memory mobile devices.

## Convergence

No disputed claim remains that both affects the recommendation and can plausibly
be settled by advisor evidence. O1 is a product decision, not an evidence gap.
Per the pass contract, no Pass 2 round was added for symmetry.

## Confidence and what would change the decision

High. Recommendations follow direct dependency source, the repo's own documented
rationale for the streaming writer, startup close behaviour, and existing tests.

Would change the decision:

- Measured peak RSS on representative low-memory mobile devices showing
  `ZipFileEncoder` safely handles the largest supported database (both advisors
  named this) — would allow deferring the writer promotion.
- A verified cross-platform picker primitive that atomically replaces an
  existing target — would simplify the `.part` handling.
- A product requirement for a privacy/factory wipe rather than database
  recovery — would expand the reset scope and require separate credential
  consent.
