# Issue #674: legacy DE1 account identity resolution

Issue: https://github.com/decentespresso/decaid/issues/674

## Goal

Resolve missing or incorrect legacy DE1 serial/model values from the linked Decent account without changing MMR values on the machine. Keep Bengle out of this flow and preserve normal machine operation whenever account data or user input is unavailable.

## Design constraints

- Keep raw MMR reads in `UnifiedDe1`; account and dialog logic stay in the application/controller layer.
- The support API becomes authoritative only after one registered machine is confidently selected.
- Persist account data through the existing `CredentialStore`; do not add a database table or dependency.
- Keep one current linked-account cache plus account-qualified device mappings. Explicit logout or successful account replacement clears that account's cache/mappings. A rejected session leaves persisted recovery data intact but it must not be used while auth is definitively invalid.
- Treat `deviceId` as opaque. Mapping identity is `(normalized account email, transportType.name, exact deviceId)`.
- Unknown SKU formats remain unknown. They may supply authoritative serial data after an exact serial match, but are not candidates for serial-0 auto/manual selection because they cannot safely be distinguished from out-of-scope hardware.
- Never write inferred `SerialN`, `v13Model`, or `Model` values to the machine.
- Preserve the existing serial-mismatch email behavior for a real nonzero serial not registered to the linked account, but run it only after identity resolution finishes.
- Resolution runs only for legacy DE1 hardware (`UnifiedDe1` with a raw model value below 128). Bengle hardware, which can surface through `UnifiedDe1` in degraded DE1-compatible mode with model values >= 128, is excluded at the controller entry point before any account lookup or prompt.

## Shipped behavior

- `DecentMachineModel` maps firmware values 0..7 plus Bengle >= 128; one conversion serves both raw MMR values and API SKU parsing. Explicit SKU tokens are parsed anchored at a token boundary, so unknown variants sharing a known prefix stay unknown.
- `RegisteredDecentMachine` records (serial, raw SKU, recognized model) replace serial-only parsing; `parseSerialNumbers` remains a serial-only projection.
- `DecentAccountService` loads the linked account's cached machines and mappings from the credential store at startup, validates stored credentials, and refreshes the machine list in the background (`withskus=1`). Caches and mappings are bound to the normalized account; logout/replacement clears them; a definitively rejected session retains persisted data but never exposes it.
- `LegacyDe1IdentityResolver` is a pure resolver: exact nonzero serial match, persisted account+transport+deviceId mapping, single known legacy candidate, unique raw-model hint, then ambiguous manual selection. Bengle and unknown-SKU records are never serial-0 candidates.
- `De1StateManager` integrates the flow for `UnifiedDe1` only, awaits the shared refresh, guards every identity apply with a connection-generation check, and runs before serial-ownership verification. Missing/rejected account shows a non-blocking link prompt; cancel leaves the machine usable. Manual choices persist and are reused on reconnect.
- `UnifiedDe1.applyEffectiveIdentity` overrides only serial/model on `MachineInfo`; raw identity stays available via `rawMachineInfo`/`rawModelValue`. No MMR writes.

See `doc/DeviceManagement.md` (post-connect identity flow and exclusions) and `doc/AI_BLE_NOTES.md` (rationale) for the durable record.
