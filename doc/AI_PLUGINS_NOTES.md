# AI Plugins Notes

Read this for behavior specific to a bundled plugin's own logic (not the plugin host
API/permissions — that's `doc/Plugins.md`).

## Visualizer: grinder burrs folded into `grinder_model`

`assets/plugins/visualizer.reaplugin/plugin.js`. Visualizer's Decent JSON parser only reads
`grinder_model` / `grinder_setting` from `app.data.settings` — there is no separate field
for a grinder's burrs (decentespresso/dye2#9: a grinder named "EG1" with burrs "Core"
uploaded as plain "EG1"). So on upload, `uploadGrinderModel` folds the burrs into
`grinder_model` via `combineModelAndBurrs` as `"<model> (<burrs>)"`.

Both halves of that string come from the shot's own recorded context
(`context.grinderModel`, `context.grinderBurrs`) and never from a lookup of the current
grinder record. An upload is often a replay of old history — a manual re-upload, a
re-upload after a credential fix — and the grinder record is live metadata: renaming "EG1"
or swapping its burrs from "Core" to "SSP HU" would otherwise rewrite what every earlier
shot claims it was pulled with. Shots recorded before `grinderBurrs` existed have no
snapshot, so they upload the plain model rather than borrowing today's burrs.

The snapshot itself is taken host-side, in `PersistenceController.persistShot`: storing a
shot whose context has a `grinderId` but no `grinderBurrs` fills the field in from the
grinder record once, at the moment the shot is stored. A missing grinder, empty burrs, or a
storage error leaves the field absent, which simply means no fold on upload.
`WorkflowContext.grinderBurrs` rides in `workflowJson`, so this needs no schema change; the
denormalized `shot_records` columns are query helpers and do not carry it.

`combineModelAndBurrs` skips the fold when every whitespace/punctuation-split token of
`burrs` is already a token of the model text (word-boundary match, not substring — a
substring check treats "EK43" as already containing burr "4", or "Kinu M47" as already
containing burr "M", and wrongly drops the real burr).

Because Visualizer then echoes the combined string back on every back-synced shot,
`shouldSkipBackSyncedGrinderModel` in `runBackSync` guards against it overwriting the local
shot's plain `grinderModel`. The guard is an **exact** match against the string this plugin
uploaded, kept per Visualizer id in `state.uploadedGrinderModels` next to `state.shotMap`
and persisted with it. Only that exact value is treated as our own echo, so editing
"EG1 (Core)" to "EG1 (Lab Sweet)" on Visualizer still applies locally; an earlier
shape-based guard ("the base model plus any ` (...)` suffix") silently swallowed such an
edit.

For a mapping with no recorded upload string — restored from an older install, or
rediscovered by `refreshLocalShotMap` from a shot's stamped `visualizerId` — the guard falls
back to recomputing the upload string from the local shot's own context (one `fetchShot`, no
grinder lookup) and still compares exactly, accepting the plain model too for shots uploaded
before the fold existed. When even that is unavailable (the local shot cannot be read) the
remote value is applied like every other back-synced field, rather than being dropped on a
guess: suppressing a real edit is the failure users notice, and the exact-match paths above
already cover our own echoes.
