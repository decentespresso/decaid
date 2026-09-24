# de1app import: merge legacy + v2 sources instead of picking one

## Root cause

de1app dual-writes both shots and profiles: a legacy file and a v2 file with
the *same basename*, written together.

- `save_this_espresso_to_history` (`de1plus/vars.tcl`) writes
  `history/<clock>.shot` and `history_v2/<clock>.json` for every shot, guarded
  by a still-unresolved `#TODO disable once v2 shotfiles are stable`.
- `save_profile` (`de1plus/vars.tcl`) writes `profiles/<name>.tcl` and
  `profiles_v2/<name>.json` for every profile save.

Confirmed against the canonical `decentespresso/de1app` `main` branch (GitHub
code search + raw fetch), not just a local checkout, since the local mirror
under active development had drifted ~20 months.

de1app's own bulk migration helper, `convert_all_legacy_to_v2` (defined once
each in `shot.tcl` and `profile.tcl`), has zero call sites anywhere in the
de1app source tree -- it's unreachable. So any file that predates a user's
de1app version starting the dual-write only exists in the legacy directory
and is never backfilled into the v2 one.

`De1appScanner`/`De1appImporter` treated `history_v2`/`profiles_v2` as
authoritative whenever non-empty, falling back to the legacy dir only when
the v2 dir was completely empty. In practice this silently dropped every
shot/profile from before a user's dual-write era, with no error surfaced --
e.g. one real report: 7000 files in `history/`, 4000 in `history_v2/`, only
the 4000 imported.

## Fix

Merge by basename across both directories instead of picking one directory:
prefer the v2 file when a basename exists in both (richer format), otherwise
fall back to the legacy file for that basename alone.

- `De1appScanner.scan`: `shotCount`/`profileCount` are now the size of the
  union of basenames across `history`+`history_v2` and `profiles`+
  `profiles_v2`. `shotSource` becomes `'both'` when both dirs are
  non-empty.
- `De1appImporter.import`: scans both directories itself (independent of
  `ScanResult.shotSource`) and merges per basename via a shared
  `_mergedFiles` helper.
- New `TclProfileParser` (`lib/src/import/parsers/tcl_profile_parser.dart`)
  parses legacy `profiles/*.tcl` files that have no v2 counterpart. Mirrors
  `tools/ingest_profiles.py`'s existing, already-reviewed conversion (same
  field mapping, same `settings_2a`/`settings_2b` rejection -- see
  `doc/AI_STORAGE_NOTES.md`'s "Legacy Profile Corpus Ingestion" section for
  why those two types aren't converted). Reuses `TclParser.parse` for the
  flat top-level fields and `TclParser.splitList` (added in
  8cb6194f, landed on `main` while this fix was in progress) for
  `advanced_shot`'s frame list and each frame's own `key value` pairs --
  both are the same space-separated/brace-grouped shape one level apart.

## Verification

- `test/fixtures/de1app/history/20231108T091544.shot` and
  `history_v2/20240315T143022.json` already had disjoint basenames --
  the existing fixture was silently demonstrating the bug (scanner counted
  1 shot when 2 real, distinct shots were present).
- Added `test/fixtures/de1app/profiles/legacy_lever.tcl` as a v2-less legacy
  profile fixture.
- `test/import/de1app_scanner_test.dart`, `test/import/de1app_importer_test.dart`,
  `test/import/tcl_profile_parser_test.dart` cover: union counting, same-basename
  dedup (no double import), legacy-only shot/profile import, and
  `settings_2a`/`settings_2b` rejection.
