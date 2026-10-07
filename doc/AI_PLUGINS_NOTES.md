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

The snapshot itself is taken host-side, in `PersistenceController.persistShot`: a shot whose
context links a `grinderId` gets `grinderBurrs` resolved from that grinder record at the
moment the shot is stored. It is a **refresh, not a fill-in**, because a context can arrive
carrying someone else's snapshot: Repeat (`history_feature`) loads a recorded workflow back
into the active one, so a shot pulled after swapping burrs or picking a different grinder
would otherwise inherit and keep the old value. Resolving every time means the stored shot
always describes the grinder as it was when that shot was pulled; the shot the value came
from is untouched, since only the record being stored is rewritten. A missing grinder, empty
burrs, or a failed lookup clears the field rather than leaving an unverifiable claim, which
simply means no fold on upload. A context with no `grinderId` is left alone — there is no
grinder to resolve against, and the value may be a client's own.
`WorkflowContext.grinderBurrs` rides in `workflowJson`, so this needs no schema change; the
denormalized `shot_records` columns are query helpers and do not carry it.

`combineModelAndBurrs` skips the fold when every whitespace/punctuation-split token of
`burrs` is already a token of the model text (word-boundary match, not substring — a
substring check treats "EK43" as already containing burr "4", or "Kinu M47" as already
containing burr "M", and wrongly drops the real burr).

Because Visualizer then echoes the combined string back on every back-synced shot,
`shouldSkipBackSyncedGrinderModel` in `runBackSync` guards against it overwriting the local
shot's plain `grinderModel`. The guard is **normalized equality** with the string this
plugin uploaded (`normalizeGrinderModelText`: trimmed, lower-cased, inner whitespace
collapsed — deliberately not literal equality, so a round trip that changes only case or
spacing is still recognised as our own echo), kept per Visualizer id in
`state.uploadedGrinderModels` next to `state.shotMap` and persisted with it. Only a value
equal to ours that way is treated as an echo, so editing "EG1 (Core)" to "EG1 (Lab Sweet)"
on Visualizer still applies locally; an earlier shape-based guard ("the base model plus any
` (...)` suffix") silently swallowed such an edit. The `storageRead` reply for this map
layers under whatever the session has already recorded, because that read can land after an
upload has remembered its string.

For a mapping with no recorded upload string — restored from an older install, or
rediscovered by `refreshLocalShotMap` from a shot's stamped `visualizerId` — the guard falls
back to recomputing the upload string from the local shot's own context (one `fetchShot`, no
grinder lookup) and compares it the same way, accepting the plain model too for shots
uploaded before the fold existed. When even that is unavailable (the local shot cannot be
read) the remote value is applied like every other back-synced field, rather than being
dropped on a guess: suppressing a real edit is the failure users notice, and the paths above
already cover our own echoes.

An applied remote edit makes the remote text the owner of that field, so back-sync sends
`grinderBurrs: null` with it and drops the recorded upload string for that shot. Both
matter. Keeping the snapshot would re-append the burrs the next time the shot is uploaded
("EG1 (Lab Sweet) (Core)"); keeping the upload string would make the guard suppress a later
revert back to the value we had uploaded, which is a genuine edit. After the edit, the
fallback recompute describes the shot as it now stands, and a re-upload records a fresh
string. The host clears the field through the ordinary `PUT /api/v1/shots/<id>` deep merge,
which stores an explicit `null`. Only a remote value that names a model counts as an edit
here: an absent or empty `grinder_model` is the generic "remote has no value" case that
`mapRemoteToLocal` already nulls, and it leaves the burrs snapshot and the recorded upload
string alone.
