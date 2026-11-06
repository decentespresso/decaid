# #1081 hot-water editor consistency

## Decisions and scope

Preserve HotWaterData.defaults().flow = 10 and widen the native hot-water flow editor from 1–8 to 1–10 ml/s. These are editor preferences, not API validity or verified physical limits. No API request validation, machine-write encoding, defaults, imports or migrations will change.

Represent saved hot-water values outside each control's recommended range honestly: retain the exact value, show an explicit out-of-editor-range state, and do not present a clamped thumb as its value. Allow unrelated edits and Apply without replacing preserved values. Work on a copy so opening/editing/cancelling does not mutate the supplied settings.

No blocking product choice remains. The larger hardware-validity audit is not part of this fix; document the evidenced encodings and recommendations without turning them into API minimum/maximum constraints. Inventory the other workflow numeric fields in focused repository documentation and the local PR-template artifact (publication is forbidden).

## Evidence inspected before implementation

- hot_water_form.dart currently has flow 1–8, temperature 50–95, volume 0–250 and duration 0–60; it aliases input settings.
- workflow.dart defaults hot-water flow to 10; JSON parsing has no range validation.
- rest_v1.yml SteamSettings, HotWaterData and RinseData do not impose numeric bounds.
- De1Controller delegates values to setHotWaterFlow/updateShotSettings; no machine-write change is needed.
- Authoritative decentespresso/de1app HEAD inspected at d83a7f46341c98c1367bb828b36d282e9214308c: binary.tcl ShotSettings unsigned char fields and U8P0 conversion, de1_comms.tcl scaled hot-water/flush MMR writes, machine.tcl editor/settings defaults. Source files fetched read-only to /tmp/1081-de1app-*.tcl. Wire capacity is not proof of physical validity or public API validation.

## Validation strategy

Focused widget tests cover the default and both pointer-selected boundaries, exact preservation outside editor ranges, precision and cancellation isolation. Schema tests distinguish recommendations from API constraints. Parent validation uses repository format, analyze and full Flutter tests; independent read-only review follows.

## Non-goals

No global workflow validator refactor, firmware calibration change, silent import migration, or per-machine profile normalization. No hardware access. No push, issue edits, or PR creation/update. No changed API contract is planned, so simulated API smoke testing is only needed if implementation changes that contract.
