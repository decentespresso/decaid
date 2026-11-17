# #1081 hot-water editor consistency

This note records the original plan, what shipped, and what was abandoned. The plan below was written
before the reachability check described in "Delivered" and no longer describes the change on its own.

## Delivered

Specification and documentation only:

- `doc/workflow-numeric-limits.md` — inventory of the `SteamSettings`, `HotWaterData` and `RinseData`
  numeric fields with model defaults, recommended control ranges, and separate on-wire capacity
  citations into `decentespresso/de1app`.
- `assets/api/rest_v1.yml` — `HotWaterData.flow` states the 1–10 ml/s recommendation and says it is not
  an API validity constraint. No `minimum`/`maximum` is declared.
- `doc/Api.md`, `doc/Profiles.md` — the same statement at API and profile level.
- `test/api/workflow_numeric_schema_test.dart` — asserts those three schemas declare no guessed bounds.

No production code changed. `lib/src/home_feature/forms/hot_water_form.dart` has zero diff.

## Abandoned: the native widget work

The original plan (below) widened the native hot-water form's flow slider from 1–8 to 1–10 ml/s and
rewrote its out-of-range handling so a preserved value is shown as out of range rather than clamped.
A 234-line widget test accompanied it.

That work was dropped after checking reachability: `HotWaterForm`, `SteamForm`, `RinseForm` and
`WaterLevelsForm` have no construction site anywhere in `lib/`. `ead69de5 refactor: remove HomeScreen
widget (replaced by LauncherView)` deleted `lib/src/home_feature/home_feature.dart` and its tiles,
orphaning `lib/src/home_feature/forms/`. Only the `*Settings` value classes remain live, through
`De1Controller`. The user-facing editor is the WebView skin.

Consequence: acceptance criteria 1 and 2 of #1081, which describe "the native hot-water form", are not
addressed by the shipped change.

## Open product decision

#1115 decides whether the orphaned forms are deleted, revived as a real settings screen, or documented
as retained-but-unwired. If they are revived, #1081's criteria 1 and 2 apply to that work, including
the model default of 10 ml/s against the current 1–8 slider and the requirement to preserve
out-of-range persisted values without silent clamping. Until then, no code change is blocked here;
what remains is a product choice about whether Decaid's native UI should duplicate the skin's
workflow editors.

## Original plan (superseded, kept for the record)

Preserve `HotWaterData.defaults().flow = 10` and widen the native hot-water flow editor from 1–8 to
1–10 ml/s. These are editor preferences, not API validity or verified physical limits. No API request
validation, machine-write encoding, defaults, imports or migrations will change.

Represent saved hot-water values outside each control's recommended range honestly: retain the exact
value, show an explicit out-of-editor-range state, and do not present a clamped thumb as its value.
Allow unrelated edits and Apply without replacing preserved values. Work on a copy so
opening/editing/cancelling does not mutate the supplied settings.

Document the evidenced encodings and recommendations without turning them into API
`minimum`/`maximum` constraints, and inventory the other workflow numeric fields in focused repository
documentation.

### Evidence inspected before that plan

- `hot_water_form.dart` carried flow 1–8, temperature 50–95, volume 0–250 and duration 0–60, and
  aliased the supplied settings.
- `workflow.dart` defaults hot-water flow to 10; JSON parsing has no range validation.
- `rest_v1.yml` `SteamSettings`, `HotWaterData` and `RinseData` imposed no numeric bounds.
- `De1Controller` delegates to `setHotWaterFlow`/`updateShotSettings`; no machine-write change was
  needed.
- Authoritative `decentespresso/de1app` inspected at `d83a7f46341c98c1367bb828b36d282e9214308c`:
  `binary.tcl` unsigned `char` fields, scaled hot-water and flush MMR writes in `de1_comms.tcl`, and
  editor defaults in `machine.tcl`. A zero steam timeout is substituted with `255` before packing.

## Non-goals

No global workflow validator refactor, firmware calibration change, silent import migration, or
per-machine profile normalization. No hardware access. No push, issue edits, or PR creation/update from
the lane.
