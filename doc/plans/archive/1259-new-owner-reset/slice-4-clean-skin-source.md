# Slice 4: qualify a clean bundled skin source, read-only

Status: engineering scope confirmed by supervisor before implementation. This is not approval of a bundled-only final reset policy. Parent #1259 remains open; risk L3 because this is a prerequisite for eventual retention of persisted packages.

## Objective and delta from Slice 3

Slice 3 establishes only the observed preferred device configuration and selected runnable managed directory. It deliberately does not establish clean package provenance. Before any escrow or reset can safely retain skin files, the package source must be distinguished from personal files placed in the installation.

This slice adds the narrower prerequisite: an opt-in, read-only WebUIStorage query that qualifies an exact installed selected package against a clean build-bundled archive. Return a typed qualified/rejected observation, not an escrow handle, reset eligibility or durable preservation. Do not change Slice 3 acceptance or add a production caller. Reject unsupported custom/updated packages rather than copy their directories or silently select a different skin.

## Confirmed current-source facts

- `new_owner_retention_preflight.dart` returns `RetainedManagedSkinPackage(skinId, directoryName)` and explicitly calls it an observation, not provenance or escrow.
- `WebUIStorage.resolveManagedSelectedSkin` owns strict selected identity, containment, manifest and readable entrypoint inspection. Reuse it; do not introduce a second managed-root resolver or registry owner.
- `WebUIStorage._copyBundledSkins` loads `assets/bundled_skins/manifest.json` and bundled ZIPs through Flutter's asset bundle. Existing installations are not overwritten merely because a bundle is present.
- `WebUIStorage._installFromZip` unwraps a single top-level directory, then `_installFromDirectory` uses the manifest identity when present and requires `index.html`. The installed directory can contain later modifications and arbitrary extra files; managed/runnable alone does not show clean origin.
- `WebUIReaMetadata` contains mutable source URLs/version hints, not an authenticated package file inventory. It must not become retention authority.
- The existing journal already owns reset configuration and package references. This prerequisite needs no second persistence record, journal schema or lifecycle owner.

These are source findings, not new tested behavior. Flutter 3.47.9 / Dart 3.13.7 matches the pinned CI SDK. The initial worktree is clean and carries the brief's copied verified ignored assets.

## Approved scope

An owner-local method taking the exact selected skin ID and optional observed runtime path. First resolve via the existing strict managed selection query. Then inspect only app-bundled asset ZIPs listed by the app bundle manifest and establish a unique matching declared skin ID. Use a constructor-injected AssetBundle defaulting to rootBundle for deterministic tests; normal installation behavior stays unchanged.

Qualification requires a safe, unambiguous archive layout, a selected manifest identity and readable nonempty entrypoint; no symlinks, traversal, duplicate/colliding paths or unsupported entry types. Bound the manifest to 256 KiB / 64 source IDs, each ZIP to 32 MiB compressed, 4096 entries, 16 MiB per file and 64 MiB total uncompressed, and total inspected sources to 128 MiB compressed. Inspect headers and declared sizes before decompression; enforce actual lengths as well. Installed traversal uses the same count/depth/byte budgets and bounded reads; reject over-budget input. Current copied bundles have at most 195 entries, 18.1 MB compressed, 22.8 MB total and 4.8 MB largest file, so these conservative limits accommodate those inputs but are qualification limits, not installer policy. Bound relative depth to 32 components and length to 1024 characters. Reject absolute/drive/backslash/dot/dot-dot/empty components, NUL, Windows-invalid/reserved/trailing-dot-or-space components and case-fold collisions on every platform; do not sanitize or rename. Account for directory/file prefix collisions and duplicate entries, including after one-top-level-folder normalization. Use non-following enumeration and reject links/unsupported types before file-content reads. Do not recursively follow a symlink or inspect its target. ASCII-only path qualification is acceptable as a conservative observation limit if non-ASCII normalization cannot be shown unambiguous without a new dependency. Compare the entire installed selected package with the clean archive's normalized package files: equal relative paths and bytes, with no extra personal files. Walk only that managed selected directory, never outside links. Reject links rather than follow them in this new qualification query. Never return arbitrary manifest/URL/account metadata or file payloads. The positive observation carries only selected skin ID and clean bundled asset key, explicitly not durable escrow.

The query may reject otherwise runnable packages conservatively. Qualification establishes content correspondence with trusted build assets, not historical installation origin. No reads are atomic with a mutable filesystem: an in-process read-only observer cannot prevent hostile concurrent swaps or a file changing after inspection. Document that trusted-root/quiescence is a future guarded-operation precondition, not a guarantee of this API. Include discriminating positives using the actual normal installer on disposable roots for flat and single-top-level-folder ZIP layouts, plus a real rootBundle source control; a blanket refusal must fail those tests. It does not reinterpret current preflight success, installation behavior or runtime serving policy. Missing/corrupt/unreadable/ambiguous sources or any uncertain package read reject distinctly. A qualified result is time-of-observation evidence only; a future guarded operation must revalidate and acquire/preserve the clean asset independently.

## Acceptance criteria

1. Resolve the exact managed selected ID through the existing WebUIStorage owner, preserving Slice 3's selection and containment refusals; no fallback selection or installation/startup/reset integration.
2. Qualify only a unique clean bundled ZIP source whose package ID and complete file bytes match the installed selected package. Reject unsupported custom/updated/modified packages, extra personal files, absent/corrupt/ambiguous bundled sources and unsafe archive layouts.
3. Reject selected package links, escaped paths, inaccessible reads and malformed metadata without outside traversal, copying, extraction, writes or claims of preservation. Output contains only a skin ID and asset key, or an explicit rejection.
4. Exercise real production filesystem/asset-reader paths, positive controls, failure injections and seeded filesystem/preferences/journal canaries. Show focused red-to-green; existing preflight/journal/startup tests remain green.
5. Destructive reset remains disabled. No new lifecycle/storage owner, journal changes, recovery-marker arming, deletion/cleanup, account/cloud/device/native work, UI/API or consent change.

## File boundary and verification

Worker scope: `lib/src/webui_support/webui_storage.dart` and a new `test/webui_support/webui_retention_source_test.dart` only. Lead authored/archived this design under the pure-text exception and added a narrow observer-limit note to `doc/Skins.md`. If implementation cannot remain small within these owners, stop and propose a narrower pass rather than adding a subsystem.

Focused command: `flutter test --no-pub test/webui_support/webui_retention_source_test.dart test/services/storage/new_owner_retention_preflight_test.dart`. Baseline: existing retention preflight plus journal tests. Final gates: exact changed-file format check; focused suite above; `flutter analyze --no-pub`; full `flutter test --no-pub --concurrency=4` with machine-event timing evidence matching CI. Freeze the candidate and obtain independent two-model review/cross-exam because file provenance is security-shaped. No device/runtime installation is needed for this inactive read-only query; tests use disposable roots and synthetic canaries. Linux build smoke, native erasure, power-loss and physical Android customer handoff remain not tested.

## Compatibility, exclusions and remaining blockers

No persistence schema, plugin event, REST/WebSocket, reconnect or primary/auxiliary role changes. Existing selected managed custom skins continue to serve; they simply lack a qualified build-bundled clean source. This does not approve a general custom package policy or silently downgrade the factory choice to the bundled version.

Non-goals from #1259: backend data deletion, actual machine reset, OS factory reset, an MDM/provisioning protocol, remote API, onboarding-v2 visual redesign.

No escrow or package copies, no whole-directory retention, no metadata trust shortcut and no new retention policy. Existing journal durability, native stores/payload purge, lifecycle draining, restoration/readback, secure credentials, guarded handoff, custom package clean-source provenance and physical end-to-end acceptance remain prerequisites before destructive reset. No filesystem experiment establishes native power-loss or directory-sync guarantees.

## Implemented mechanisms and conservative limits

The owner keeps ZIP interpretation in locked `archive` 4.0.9. A fixed-field
central-directory framing/count guard runs before `ZipDirectory.read`, so the
library cannot materialize more than 4096 records from the directory that guard
validated. This guard validates only framing and resource bounds; it does not
extract or replace the library's package interpretation. It rejects a ZIP64
end-of-central-directory locator positioned immediately before the selected EOCD,
as well as ZIP64 entry-count/offset sentinels and trailing EOCD data: the library
honours such a locator without requiring the sentinel fields, so it would
otherwise parse and materialize a directory the guard never framed. It also
rejects a central record whose compressed size, uncompressed size or local header
offset is the 0xffffffff sentinel, or whose extra field carries a ZIP64
extended-information record, so ZIP64 per-entry encoding never reaches the
library's resolution step. It also
rejects an archive carrying a second end-of-central-directory signature below the
framed one, because the library's tail search reads non-overlapping 1024-byte
chunks and can skip a final record that starts in the three bytes before a chunk
boundary, selecting an earlier record instead. With exactly one end signature in
the file, no selection rule can reach a directory the guard did not frame. A budgeted
input stream caps aggregate local-header/payload-view reads at 128 MiB to reject
repeated-local-header amplification. The library reads the central subset through
its own memory view rather than the budgeted stream, so that subset is bounded by
the guard's record cap and the 32 MiB source limit, not by the input counter.

The selected ID is resolved through the same owner used for serving, in a strict
non-following mode: a linked package directory, manifest or entrypoint rejects
without canonicalizing, reading or probing the link target. Serving and
installation keep their existing link-following behavior; only this query is
strict.
Manifest/file declared lengths, supported types/codecs, safe normalized paths and
case-folded implicit directory prefixes are validated before content inflation.
The sum of declared compressed file lengths is also capped at 64 MiB.

Neither `archive`'s direct `Inflate` nor the runtime's raw-deflate decoder strictly
rejects every incomplete stream. The implemented deflate reader wraps the ZIP's
raw deflate bytes in a gzip frame with that entry's declared CRC32 and length,
then uses `dart:io`'s chunked gzip decoder and a non-collecting bounded sink. The
sink accepts at most the already-capped declared length and aborts on excess
output during inflation; gzip trailer validation rejects missing final blocks,
truncated streams and trailing deflate garbage. Exact output length and CRC32 are
also checked independently. Stored entries use the same size/CRC contract.
Decoder errors become explicit rejection. Runtime chunk allocation precedes sink
acceptance (64 KiB chunks observed on the pinned host), so the declared budget
bounds retained output, not an assertion of zero decoder overhead. Compressed
framing requires a bounded per-file copy. Local/central names, codecs, encryption
and descriptor flags are reconciled; local size fields overwritten by the library
are not claimed as independent checks. No new archive dependency is introduced.

Installed traversal uses lazy non-following enumeration and counts every entry,
including empty directories, before descending or reading file content. Missing,
corrupt or ambiguous competing source identity blocks qualification even when
another source matches; only a demonstrably different identity can be ignored.
The output remains a time-of-observation result, not origin proof or reset power.

Tests cover actual installer layouts, synthetic production asset-channel reads
with the default rootBundle, both codecs, small-budget lying headers, strict
codec/header failures, competing-source uncertainty and count/prefix limits.
They also cover rejection of a ZIP64 alternate central directory before any parse
(the static parse-read counter stays unset), contained manifest and entrypoint
links rejected without following their targets (recorded filesystem-access calls),
an archive entry name containing a backslash rejected instead of normalized, and
the chunk-boundary case where an earlier end record would have governed the
library's parse. A central record using ZIP64 sentinel fields rejects, while an
ordinary non-ZIP64 extra field still qualifies. The optional runtime skin path is exercised in strict mode: a
sibling alias is rejected as ambiguous before any link-following operation, while
the real selected package still qualifies.
A real bundled-asset control also runs locally when those ignored build assets
exist; CI's documented stub skips only that additional control. Mutation evidence
shows that post-inflate rejection alone fails the accepted-output-byte assertion,
removing the parse budget fails the shared-local-header read-count assertion, and
reducing complete byte comparison to a length check or removing the content CRC
check fails only the equal-length modified-file and reconciled-checksum variants.
The two static testing counters expose maximum accepted bytes/read counts only,
never package data; they are not synchronization or production authority.

Remaining limits include non-atomic filesystem observation, conservative rejection
of otherwise runnable archive layouts, and host-only decoder/resource measurements.
There is no browser/native cleanup, custom-package provenance, durable escrow,
power-loss guarantee or physical new-owner handoff evidence.

## Scope checkpoint disposition

Supervisor confirmed this read-only prerequisite before worker dispatch, with explicit limits for archive/file resources, cross-platform path collisions, non-following link inspection, real installation-layout positives and mutable-filesystem observation gaps added above. Qualification is content correspondence only. Custom/updated selections keep serving normally; unresolved clean-source provenance remains a future reset blocker. No final bundled-only product policy, escrow or destructive reset is approved.
