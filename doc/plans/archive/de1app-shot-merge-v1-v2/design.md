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
`clock` field. A shared basename only makes two files candidates for each
other; nothing is merged until both parse to the same id, so a renamed or
hand-copied file cannot graft its metadata onto a different shot.

| Available | Result |
| --- | --- |
| v2 only | v2 |
| legacy only | legacy |
| both | v2 for profile and measurements; legacy fills metadata fields the v2 shot leaves empty |
| both, v2 unparseable | legacy |
| neither parses | one `ImportError`, shot skipped |
| two files of the same format, one shot | merged, gap-filled, stored once |
| same basename, different ids | two shots, nothing shared |

Discovery order is not allowed to decide anything: `Directory.list()` makes no
ordering promise, so candidates are sorted by basename first. When two
same-format records of one id disagree on a field both have filled, the
lexicographically first basename wins it.

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

## Frame reconstruction

`espresso_state_change` (v2: `state_change`) is a per-sample series whose sign
de1app flips at every frame change the DE1 reports
(`gui.tcl`'s `_state_change_chart_value`, flipped where
`current_framenumber != previous_framenumber`). Counting sign changes therefore
reproduces the machine's own frame sequence, including exits that fire early on
a pressure, flow or weight condition. Cumulative step durations remain the
fallback for records without the series, and that fallback is an approximation:
it assumes every step runs to its configured maximum.

## Parse cost

The whole import runs on the UI isolate: file reads are async, but Tcl parsing,
`jsonDecode`, snapshot construction and profile recovery are synchronous. For a
shot that exists in both formats the legacy sibling is parsed in `metadataOnly`
mode, which skips the sample lines, the snapshots and the embedded-profile scan,
since the merge takes none of those from legacy.

Measured by `test/import/de1app_parse_benchmark_test.dart` on a 600-sample shot
(macOS host, debug VM): legacy full 1.46 ms average / 2.93 ms worst,
legacy metadata-only 0.09 ms / 0.17 ms, v2 0.48 ms / 0.85 ms. The longest
uninterrupted block is one shot's parse, and the loop awaits file IO between
shots.

## Fixtures

`test/fixtures/de1app/canonical_simulated.shot` is
`de1plus/simulations/simulated_1.shot` from `decentespresso/de1app`, reduced to
its first 30 samples per series with the `settings` and `machine` blocks pruned
to the keys the import reads. It keeps the canonical key order the writer
produces (arrays, `settings`, `machine`, `app_version`, then `profile` last) and
its profile intact: six steps whose first one, `Fill`, is configured for 25 s
but exits on `pressure over 1.5` at 3.778 s, which is what makes it the
regression case for frame reconstruction.

`test/fixtures/de1app/legacy_with_profile.shot` is hand-written and keeps the
opposite order, with `profile` ahead of `settings`, to hold the generic Tcl pass
to its brace depth rather than to key order.

## Known ceilings

- No benchmark has been run on an Android or iOS target; the figures above are
  host figures. If a device shows long frames, the parse loop is the thing to
  batch into a worker isolate, and the metadata-only path has already removed
  most of the per-shot cost for paired shots.
- `TclShotParser` recovers the embedded profile with a JSON-string-aware brace
  scan, so braces and escaped quotes inside string values are safe. `TclParser`
  itself still counts braces structurally (honouring Tcl's escaped braces). A
  profile note holding a brace that is unbalanced *as Tcl* would mis-nest the
  generic pass, which only affects keys written after the `profile` block;
  de1app's writer emits `profile` last.
- `targetYield` still prefers `settings target_drink_weight` over the recovered
  profile's `target_weight`.

## Out of scope

Post-conversion DYE edits that overwrite a value the v2 file already has are
not recovered; gap-fill only adds what v2 lacks.
