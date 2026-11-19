# Canonical skin selection with legacy-origin preservation

Approved scope: fix PR #1209 in its existing lane. Leave legacy folders untouched.

## Problem

Skin discovery currently lets the last directory with a manifest ID win. A legacy Streamline directory can therefore hide a newer canonical `streamline.js` directory. Selecting the canonical directory alone changes the default path-derived serving identity and can hide browser storage behind a different port.

## Decision

Prefer a directory whose basename equals the manifest ID when duplicate IDs exist. Keep a runtime record of all valid directories for each ID. Publish the selected skins and their legacy paths together only after discovery completes: a partial registry could otherwise allocate a new port before discovering its legacy assignment. A legacy-only installation remains discoverable; neither scanning nor selection deletes, copies or renames its files.

Use constructor-independent service wiring already used for skin identity: supply WebUIService a callback for same-ID legacy paths. Before allocating a new canonical-path port, reuse a saved legacy-path assignment and persist it under the canonical path. An existing canonical assignment always wins. If several legacy paths have assignments, consider them in the former discovery preference order (last discovered first), never borrow another skin's assignment, and retain unrelated mappings. Preserve the assignment when its port is busy and use the existing temporary-port fallback. Failed persistence retains the migrated in-memory assignment and retries safely after restart from the unchanged saved legacy mapping.

This changes a SharedPreferences map's path key, not a Drift schema. The same scheme, host and port continue to serve the current files, so browser storage remains available without copying browser profiles.

## Verification

Test public install/discovery behavior in both filesystem enumeration orders, legacy-only fallback and preserved legacy files. Test serving current HTML on the saved legacy port, persisted restart, existing canonical assignments, unrelated ports, busy ports and failed persistence. Keep fixtures self-contained. Run focused tests, formatter, analyze and full Flutter tests. Use the authorised development tablet only if a safe synthetic legacy fixture and browser-storage sentinel can be isolated; no espresso-machine commands.

## Non-goals

No legacy-folder deletion, skin-ID rename, browser-storage copying, new preferences key, endpoints, dependency or release/update policy change. Direct modifications to skin files retain normal update overwrite semantics.
