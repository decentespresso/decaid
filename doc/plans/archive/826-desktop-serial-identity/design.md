# 826 — Desktop serial identity resolution

Issue: https://github.com/decentespresso/decaid/issues/826

## Problem

On macOS a single CH340-backed DE1 is exposed through paired `/dev/cu.*` and
`/dev/tty.*` nodes. Both aliases can enter the same scan before either is
registered, so the machine shows up twice. A second path to the same symptom:
`_DesktopSerialPort._computeId()` re-reads USB metadata after enumeration and
falls back to `serial-<basename>` when those reads fail, while the scan that
admitted the port used `usb-{vid}-{pid}-{serial}`. Scan dedup, quick-connect,
`Device.deviceId` and the API inventory can therefore disagree.

`serial-cu.*` must not become the canonical ID — it is unstable across port
renumbering. `usb-*` (introduced in #75, interface-aware form `...-ifNN` for
Bengle) stays canonical; `serial-<basename>` is compatibility-only.

## Design

1. **One identity resolution per enumerated port.**
   `SerialPortMetadata` (in `serial_reconcile.dart`) carries the path, name,
   transport, product name, VID/PID/serial/interface and the canonical ID
   resolved once:
   `computeUsbStableId(...) ?? 'serial-<basename>'`.
   `computeUsbStableId()` semantics are unchanged, so Android and Bengle IDs
   keep their meaning.

2. **Deduplicate candidates before probing.**
   Pure `dedupeSerialCandidates(List<SerialPortMetadata>)`:
   - key by canonical USB ID; two ports with the same ID collapse within the
     current scan (not only against previously tracked IDs);
   - macOS `/dev/cu.X` + `/dev/tty.X` are one endpoint: when USB metadata is
     absent the pair still collapses on the stripped alias suffix, and `/dev/cu.X`
     is preferred for the probe;
   - distinct interface numbers stay distinct (the `-ifNN` suffix is part of
     the canonical ID), preserving Bengle machine/tap identities.

3. **Pass the resolved ID into the transport.**
   `_DesktopSerialPort` takes the canonical ID from the candidate instead of
   calling `_computeId()`. Scan dedup, `_portPathToDeviceId`, `Device.deviceId`,
   remembered identity and API inventory all see the same value.

4. **Quick-connect uses the same resolver.**
   Enumerate -> `SerialPortMetadata` -> dedupe -> match
   `remembered.id` against `{canonicalId} ∪ desktopSerialLegacyIds(path)`.
   A legacy `serial-*` alias locates the port, but the live device exposes the
   canonical `usb-*` ID.

5. **Migrate a legacy remembered/preferred ID after a successful connect.**
   `RememberedDevicesController.replaceAliasOnConnect(aliasId, canonicalId)`
   removes the alias key, keeps an existing canonical record, otherwise re-keys
   the alias record, persists once and rolls the registry back on persistence
   failure. `ConnectionManager` writes `preferredMachineId` only after that
   succeeds; a migration failure is logged and leaves the connection up.

`buildAvailabilityDeviceList()` gets no name- or implementation-based fuzzy
dedup; two genuinely distinct machines may share metadata. Migration happens
only after serial enumeration or quick-connect positively matched the port.

## Acceptance

- Reporter's CH340 DE1 on macOS appears once and connects through `/dev/cu.*`.
- Public/persisted identity is one canonical `usb-*`; `serial-cu.*` is never a
  second device.
- Repeated scans do not reintroduce the alias.
- Legacy remembered/preferred IDs self-migrate after a successful quick-connect.
- Linux/Windows/Android stable identity unchanged; Bengle base/interface
  identities remain distinct.
