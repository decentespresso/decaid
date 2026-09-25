# AI Plugins Notes

Read this for behavior specific to a bundled plugin's own logic (not the plugin host
API/permissions — that's `doc/Plugins.md`).

## Visualizer: grinder burrs folded into `grinder_model`

`assets/plugins/visualizer.reaplugin/plugin.js`. Visualizer's Decent JSON parser only reads
`grinder_model` / `grinder_setting` from `app.data.settings` — there is no separate field
for a grinder's burrs (decentespresso/dye2#9: a grinder named "EG1" with burrs "Core"
uploaded as plain "EG1"). So on upload, `resolveUploadGrinderModel` looks the grinder up
(`GET /api/v1/grinders/<id>`) and, when it has a `burrs` value, folds it into `grinder_model`
via `combineModelAndBurrs` as `"<model> (<burrs>)"` — using the model **recorded on the
shot** (`context.grinderModel`), not the grinder record's current model, so a grinder rename
after the fact doesn't rewrite old shots' history. `combineModelAndBurrs` skips the fold when
every whitespace/punctuation-split token of `burrs` is already a token of the model text
(word-boundary match, not substring — a substring check treats "EK43" as already containing
burr "4", or "Kinu M47" as already containing burr "M", and wrongly drops the real burr).
Lookup failure, a missing `grinderId`, or no `burrs` set on the grinder all fall back to the
plain recorded model.

Because Visualizer then echoes that combined string back on every back-synced shot,
`shouldSkipBackSyncedGrinderModel` / `isBaseModelRoundTrip` in `runBackSync` guard against it
overwriting the local shot's plain `grinderModel`. This is deliberately a **fuzzy,
network-free pattern match** on the local shot's own recorded base model — remote equals the
base model, or the base model plus any `" (...)"` suffix — rather than a recomputed exact
upload string. Recomputing exactly (fetching the grinder again and re-running
`combineModelAndBurrs`) fails **open**: if the grinder was since deleted, its burrs edited,
or the lookup times out, the recomputed value silently stops matching and the remote value
overwrites the local one anyway. The pattern match instead only needs the local shot's own
context (one `fetchShot`, no grinder lookup at all), and if even that fails, the field is
left untouched rather than risking an overwrite — fail **closed**, matching the rest of
back-sync's "only touch what we're sure about" posture (see `mapRemoteToLocal`'s comment).
