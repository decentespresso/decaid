# Workflow numeric limits

This inventory separates three different contracts:

1. **Recommended control ranges** are UI preferences: what a slider or a skin
   offers. They make a control useful; they are not machine or REST validity
   constraints. The native forms under `lib/src/home_feature/forms/` are
   currently not wired to any screen (the host `HomeScreen` was removed when the
   launcher replaced it), so today the consumer skin is the user-facing editor.
2. **On-wire capacity** is the representable range of a firmware field. A field
   fitting in an unsigned byte does not prove that every value is safe or valid
   for every machine.
3. **Conditional semantics** can give a value a special meaning. In particular,
   steam temperatures below the enabled cutoff disable steam rather than naming
   a lower enabled temperature.

The REST workflow schemas therefore intentionally do not add guessed
`minimum`/`maximum` values. They continue to round-trip finite numeric workflow
values, and nothing in Decaid clamps or rewrites a preserved value to fit a
control's preference range.

## SteamSettings

The model defaults are defined by [`SteamSettings.defaults()`](https://github.com/decentespresso/decaid/blob/5684ecb82a6a7f60c49c396130b4a8b51de5d609/lib/src/models/data/workflow.dart#L263-L270).
The ranges in this table are recommended native editor ranges from
[`SteamForm`](https://github.com/decentespresso/decaid/blob/5684ecb82a6a7f60c49c396130b4a8b51de5d609/lib/src/home_feature/forms/steam_form.dart#L62-L120),
not physical bounds.

| Field | Model default | Recommended control range | Evidence and semantics |
| --- | ---: | ---: | --- |
| `targetTemperature` | 150 °C | 135–170 °C | Decaid enables steam at `>= 135` °C and writes `0` when disabled ([controller cutoff](https://github.com/decentespresso/decaid/blob/5684ecb82a6a7f60c49c396130b4a8b51de5d609/lib/src/controllers/de1_controller.dart#L468-L495)). The authoritative DE1 app packs this as unsigned `char`, so the wire capacity is 0–255 ([`binary.tcl`](https://github.com/decentespresso/de1app/blob/d83a7f46341c98c1367bb828b36d282e9214308c/de1plus/binary.tcl#L190-L205), [`binary.tcl` field spec](https://github.com/decentespresso/de1app/blob/d83a7f46341c98c1367bb828b36d282e9214308c/de1plus/binary.tcl#L449-L456)). The API description documents enabled DE1/Bengle ranges and the `0`/cutoff semantics; those are not declared as schema bounds. |
| `duration` | 50 s | 0–120 s | `TargetSteamLength` is an unsigned byte on the packed DE1 description, giving a representable 0–255 capacity ([`binary.tcl`](https://github.com/decentespresso/de1app/blob/d83a7f46341c98c1367bb828b36d282e9214308c/de1plus/binary.tcl#L198-L204), [field spec](https://github.com/decentespresso/de1app/blob/d83a7f46341c98c1367bb828b36d282e9214308c/de1plus/binary.tcl#L449-L456)). The byte capacity is not asserted as an API validity range. **Conditional semantics:** `0` is not a literal zero-second steam; the authoritative app substitutes `255` for a zero setting before packing, because zero would stop steam immediately ([`binary.tcl`](https://github.com/decentespresso/de1app/blob/d83a7f46341c98c1367bb828b36d282e9214308c/de1plus/binary.tcl#L197-L203)). Decaid writes the value through unchanged ([`unified_de1.dart`](https://github.com/decentespresso/decaid/blob/3568e4c0fa71e8d64bf3170b29d77e7c09846257/lib/src/models/device/impl/de1/unified_de1/unified_de1.dart#L762)), so a Decaid-side `0` reaches the machine as `0`; see the PR discussion for that open difference. |
| `flow` | 0.8 ml/s | 0.4–2.5 ml/s | The native range is the [`SteamForm` flow slider](https://github.com/decentespresso/decaid/blob/5684ecb82a6a7f60c49c396130b4a8b51de5d609/lib/src/home_feature/forms/steam_form.dart#L106-L120). Decaid's target-steam-flow MMR metadata uses `readScale: 0.01` and `writeScale: 100.0` ([MMR metadata](https://github.com/decentespresso/decaid/blob/5684ecb82a6a7f60c49c396130b4a8b51de5d609/lib/src/models/device/impl/de1/de1.models.dart#L276-L283)). The authoritative app writes the separate steam-flow register and does not establish a public physical maximum ([`de1_comms.tcl`](https://github.com/decentespresso/de1app/blob/d83a7f46341c98c1367bb828b36d282e9214308c/de1plus/de1_comms.tcl#L1582-L1587)). No physical maximum is inferred here. |
| `stopAtTemperature` | 0 °C | Not exposed by native editor | The API prose defines `0` as disabled and documents a 0–80 °C application/probe target. It is scaffolding today and does not affect ordinary machine behavior; this is a conditional feature contract, not a blanket machine temperature bound. |

## HotWaterData

| Field | Model default | Recommended control range | Evidence and semantics |
| --- | ---: | ---: | --- |
| `targetTemperature` | 75 °C | 50–95 °C | The packed DE1 hot-water temperature is an unsigned byte, so its wire capacity is 0–255 ([`binary.tcl`](https://github.com/decentespresso/de1app/blob/d83a7f46341c98c1367bb828b36d282e9214308c/de1plus/binary.tcl#L205-L217), [field spec](https://github.com/decentespresso/de1app/blob/d83a7f46341c98c1367bb828b36d282e9214308c/de1plus/binary.tcl#L449-L456)). This does not establish an API-valid or safe physical range. |
| `volume` | 50 ml | 0–250 ml | The packed DE1 hot-water volume is an unsigned byte (0–255 capacity). The authoritative app deliberately substitutes 250 when its scale-based stop feature is active, showing that this field also has conditional behavior ([`binary.tcl`](https://github.com/decentespresso/de1app/blob/d83a7f46341c98c1367bb828b36d282e9214308c/de1plus/binary.tcl#L207-L217)). No REST bound is inferred. |
| `duration` | 30 s | 0–60 s | The packed DE1 hot-water duration is an unsigned byte (0–255 capacity) ([`binary.tcl`](https://github.com/decentespresso/de1app/blob/d83a7f46341c98c1367bb828b36d282e9214308c/de1plus/binary.tcl#L214-L217), [field spec](https://github.com/decentespresso/de1app/blob/d83a7f46341c98c1367bb828b36d282e9214308c/de1plus/binary.tcl#L449-L456)). The editor range is a recommendation only. |
| `flow` | 10 ml/s | 1–10 ml/s; the orphaned native form still offers 1–8 ml/s | The DE1 app writes hot-water flow to MMR `0x0080384C` after multiplying by 10 ([`de1_comms.tcl`](https://github.com/decentespresso/de1app/blob/d83a7f46341c98c1367bb828b36d282e9214308c/de1plus/de1_comms.tcl#L1349-L1354)); Decaid records that MMR as a 0.1-scaled value ([MMR metadata](https://github.com/decentespresso/decaid/blob/5684ecb82a6a7f60c49c396130b4a8b51de5d609/lib/src/models/device/impl/de1/de1.models.dart#L334-L348)). This scale and register width do not prove a physical maximum or API validity bound. |

## RinseData

The model fields and defaults are in [`RinseData`](https://github.com/decentespresso/decaid/blob/5684ecb82a6a7f60c49c396130b4a8b51de5d609/lib/src/models/data/workflow.dart#L366-L403). The ranges below are recommended native editor ranges from [`RinseForm`](https://github.com/decentespresso/decaid/blob/5684ecb82a6a7f60c49c396130b4a8b51de5d609/lib/src/home_feature/forms/rinse_form.dart#L36-L91), not physical bounds.

| Field | Model default | Recommended control range | Evidence and semantics |
| --- | ---: | ---: | --- |
| `targetTemperature` | 90 °C | 5–95 °C | The native editor range is the [`RinseForm` temperature slider](https://github.com/decentespresso/decaid/blob/5684ecb82a6a7f60c49c396130b4a8b51de5d609/lib/src/home_feature/forms/rinse_form.dart#L36-L54). Decaid writes flush temperature through a 0.1-scaled four-byte MMR. No authoritative API or physical bound was verified. |
| `duration` | 10 s | 0–60 s | The native editor range is the [`RinseForm` duration slider](https://github.com/decentespresso/decaid/blob/5684ecb82a6a7f60c49c396130b4a8b51de5d609/lib/src/home_feature/forms/rinse_form.dart#L57-L75). Decaid writes flush timeout through a 0.1-scaled four-byte MMR. No authoritative API or physical bound was verified. |
| `flow` | 6 ml/s | 1–8 ml/s | The native editor range is the [`RinseForm` flow slider](https://github.com/decentespresso/decaid/blob/5684ecb82a6a7f60c49c396130b4a8b51de5d609/lib/src/home_feature/forms/rinse_form.dart#L78-L91). Decaid writes flush flow through a 0.1-scaled four-byte MMR. The DE1 app uses the same x10 conversion for flush flow ([`de1_comms.tcl`](https://github.com/decentespresso/de1app/blob/d83a7f46341c98c1367bb828b36d282e9214308c/de1plus/de1_comms.tcl#L1368-L1372)); no physical maximum is inferred. |

No blanket request-time rejection is added for these fields. A future API
constraint should be based on an explicitly verified validity contract rather
than an editor slider, a default, or an integer encoding capacity.
