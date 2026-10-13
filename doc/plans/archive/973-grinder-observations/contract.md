# Grinder observations contract (#973)

## Contract rationale

Commands and observations are independent. Add domain `GrinderObservation { setting, rpm }`, a default-empty `GrinderDevice.observations`, and optional string `observedSetting` / nonnegative integer `observedRpm` snapshot projections. Preserve string settings and all existing v1 setting/RPM behavior. Native and simulated implementations use the same domain model; no vendor protocol enters core.

Plugin driver manifests accept an optional unique array `observations` only for grinders, containing `setting` and/or `rpm`. Parse and serialize it with the domain enum rather than a duplicate plugin enum. Both network registration and BLE binding pass immutable declarations into PluginGrinder. Publication validates presence, declaration and exact types at the existing host boundary before any mutation. Null is invalid; omission is unavailable. Each accepted snapshot is newly constructed, so omitted observed fields never carry forward.

REST grinder info exposes nonempty `observations`; empty declarations are omitted to preserve existing info responses. REST state and WebSocket snapshots serialize the optional projections. Existing capability/handler matching and control descriptors remain command-only. No observation descriptor surface is added: there is no reviewed requirement for interpretation metadata in this slice, and existing control machinery is intentionally unchanged. Observations neither synthesize controls nor permit publishInfo control overrides without the command capability.

Keep PluginProtocolDevice session checks and BLE registry/binding generation fencing ahead of validation. Keep controller generation fencing and selection clearing. Add controller-level command capability checks to reject unsupported native/fake as well as plugin operations before device invocation; plugin checks remain defense in depth.

No blocking product question: names, types, independent declarations, omission semantics and lifecycle ownership are fixed by #973. #974 is a separate proposal and supplies no implementation scope.

## Verification mapping (acceptance criteria in issue order)

1. Manifest round-trip and network/BLE read-only runtime registration; read-only fake declaration.
2. Declared observedSetting accepted, string preserved in snapshot and REST/WS.
3. Declared observedRpm accepted, including zero.
4. Undeclared observations rejected by adapter and real JS host boundary.
5. Empty command capabilities and absent controls despite observations.
6. Controller and plugin setting/RPM calls rejected; invocation/write counters unchanged.
7. Existing writable grinder suites and v1 exact payload tests remain green.
8. Publish with observations then state-only: adapter, controller, REST and WS no longer contain observed values.
9. Table-driven manifest and publication boundary cases: unsupported/duplicate/wrong-type observation declarations, null/number/object settings, negative/fractional/string/null RPM, malformed payloads and unknown keys.
10. Disconnected, old-session and disposed adapter plus real runtime unload/replacement rejected without updating selected snapshot.
11. Two instances, switching, reconnect and delayed retained context publication with no hardware; existing controller race suites retained.
12. Manifest and runtime info reject observation-only writable descriptors; REST controls remain absent.
13. REST/WS schema assertions and consistent plugin/API documentation.

## Deliberately unchanged

No shot persistence/provenance, recommendations, vendor protocols, automatic control, E64-specific branch, stale GrinderState, v1 setting/RPM redefinition, observation metadata as writable controls, inventory metadata, database schema or preference changes.
