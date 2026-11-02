# de1app import: merge legacy and v2 shots without loss or overlap

Follows `../de1app-history-profile-merge/design.md`, which established the
basename union; this one replaces its modification-time tiebreak.

## Problem

A bulk DE1PRO import on 0.9.1 stored shots with `profile.title == "Unknown profile"`,
no profile steps, and no annotations or context, even though the matching
`history_v2/*.json` carried the full profile and metadata.

Verified against a reporter's pair of files
(`20261101T065825.json` / exported `20261101-030853_decaid.json`):
`ShotV2JsonParser.parse` on the v2 file yields profile `Adaptive v3`, 7 steps,
dose 14.0, yield 32.3, grinder setting 9. None of that reached storage, so the
legacy `history/*.shot` sibling was imported instead.

Four defects combine:

1. `_mergedFiles(..., newerFallbackWins: true)` picks the legacy `.shot` when its
   mtime is newer than the v2 `.json`.
2. `SafFolderCopier` stages files with `safStream.copyToLocalFile`, which stamps
   each destination with the copy time. Source mtimes are gone before the
   tiebreak runs, so whichever directory is copied second wins for every shot.
3. `TclShotParser` hardcodes `steps: []` and takes the title only from
   `settings['profile_title']`. It ignores the top-level `profile` key, which
   real `.shot` files populate with the complete v2 profile as JSON.
4. `TclParser.parseBlock` ends a block at any line that trims to `}`, ignoring
   brace depth. A settings value spanning lines (for example `read_only_backup`)
   truncates `settings`; the remaining keys land in the top-level map. Whether
   `profile_title` and the bean/grinder metadata survive is luck.

## Goal

History that exists only as `.shot` must import with its profile and metadata.
History that exists in both formats must import once, from the better source.

## Merge rule

Keyed on shot id (`de1app-<clock>`), which both parsers derive from the same
`clock` field.

| Available | Result |
| --- | --- |
| v2 only | v2 |
| legacy only | legacy |
| both | v2 for profile and measurements; legacy fills metadata fields the v2 shot leaves empty |
| both, v2 unparseable | legacy |
| neither parses | one `ImportError`, shot skipped |
| two files of the same format, one shot | merged, gap-filled, stored once |

Gap-fill is one-directional: a field already set in the v2 shot is never
replaced. A field counts as empty when it is `null`, an empty string, or `0`
for the numeric metadata (dose, yield, tds, ey, enjoyment) that de1app writes
as `0` when unset.

Fields covered: bean brand/type/notes, roast date/level, grinder model/setting,
`ShotAnnotations` (dose, yield, tds, ey, enjoyment, notes), and
`WorkflowContext` (dose, yield, grinder model/setting, coffee name/roaster,
barista, drinker).

Profile, measurements, timestamp and id always come from the winning source and
are never merged.

## Known ceilings

- The legacy sibling is parsed whenever it exists, so a bulk import with both
  directories present pays for both files. Gate it on a metadata-gap check if
  that becomes slow.
- `TclShotParser` recovers the embedded profile by counting braces over the raw
  text. A profile note holding an unbalanced brace makes the recovery return
  null, and the shot falls back to a step-less profile titled from
  `settings profile_title`.

## Out of scope

Post-conversion DYE edits that overwrite a value the v2 file already has are
not recovered; gap-fill only adds what v2 lacks.
