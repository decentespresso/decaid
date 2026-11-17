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

## Second review round: TclProfileParser correctness fixes

`TclParser.parse`'s generic braced-value heuristics (map vs. list vs. plain
string) are ambiguous in ways that only show up on inputs the three-frame
fixture didn't exercise:

- **Single-frame `advanced_shot` loses its frame boundary.** When
  `advanced_shot`'s list has more than one frame, `TclParser.parse` can't
  collapse the value (its "all one bracketed token" shortcut doesn't apply),
  so it returns the frames still individually braced:
  `{frame1} {frame2}`. With exactly one frame, that shortcut *does* apply and
  the parser strips the frame's own wrapping braces, leaving just its flat
  `key value key value ...` text indistinguishable from a plain string.
  `TclProfileParser._parseSteps` re-splitting that text as if it still had
  per-frame braces produced an unnamed 0-bar step instead of the real one.
  Fix: a leading `{` is the only signal that more splitting is needed: its
  absence means the whole string is already one frame.
- **A four-plus-word `profile_title`/`profile_notes` reads as a map.** The
  same heuristic treats an even-length run of plain tokens as key/value
  pairs (used correctly for `advanced_shot` frames' own fields), so `{My
  Best Coffee Shot}` parsed to `{"My": "Best", "Coffee": "Shot"}` instead of
  the string. Fix: `_flatten` reconstructs the original space-joined text
  from whatever shape `TclParser.parse` returned, since these text fields
  are never actually structured.
- **A malformed frame (too few tokens, or an odd trailing key) was silently
  dropped** via `whereType` filtering, importing a shorter, truncated
  recipe with no error. Fix: reject the whole profile instead
  (`MalformedProfileFrameException`).
- **`settings_profile_type` didn't recognize de1app's pre-alias names.**
  de1app's own `fix_profile_type` (`de1plus/profile.tcl`) normalizes
  `settings_2`/`settings_profile_pressure` to `settings_2a`,
  `settings_profile_flow` to `settings_2b`, and
  `settings_profile_advanced`/`settings_2c2` to `settings_2c` before
  deciding what a profile type means. `TclProfileParser` only rejected the
  post-normalization `settings_2a`/`settings_2b` strings, so the raw aliases
  (and any other unrecognized type) passed straight through as if
  `settings_2c`. Fix: apply the same normalization, then accept only
  `settings_2c` and reject everything else.
- **`beverage_type` defaulted unrecognized values to espresso.**
  `Profile.fromJson`'s `_parseBeverageType` silently falls back to
  `BeverageType.espresso` for anything that isn't one of its enum names,
  which is correct general model behavior but wrong for import: de1app's
  `tea`/`filter`/`tea_portafilter`/`descale` values (mapped by
  `tools/ingest_profiles.py`'s `BEVERAGE_TYPE_MAP` to
  `pourover`/`cleaning`) would otherwise silently become espresso. Fix:
  apply the same mapping in `TclProfileParser` before building the profile
  JSON, and reject anything still unrecognized
  (`UnsupportedBeverageTypeException`) instead of reaching that fallback.

See `test/import/tcl_profile_parser_test.dart` for the regression covering
each case, and `doc/Profiles.md`'s "de1app Legacy `.tcl` Profile Import"
section for the resulting supported/unsupported type and beverage-type
tables.

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
