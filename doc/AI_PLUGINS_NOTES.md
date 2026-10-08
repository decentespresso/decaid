# AI Plugins Notes

Read this for behavior specific to a bundled plugin's own logic (not the plugin host
API/permissions — that's `doc/Plugins.md`).

## Visualizer: grinder burrs folded into `grinder_model`

`assets/plugins/visualizer.reaplugin/plugin.js`. Visualizer's Decent JSON parser reads only
`grinder_model` / `grinder_setting` from `app.data.settings` and has no field for a grinder's
burrs (decentespresso/dye2#9), so `uploadGrinderModel` folds them in as `"<model> (<burrs>)"`
via `combineModelAndBurrs`. Invariants to preserve when changing this:

- **Upload from the shot, not from the grinder record.** Both halves come from
  `context.grinderModel` and `context.grinderBurrs`. An upload is often a replay of old
  history (a manual re-upload, a re-upload after fixing credentials) while the grinder record
  is live metadata, so a lookup would let a later rename or burr swap rewrite what earlier
  shots claim. A shot with no `grinderBurrs` uploads the plain model.
- **Resolve the snapshot on every store, not only when absent.**
  `PersistenceController.persistShot` reads the linked grinder whenever the context has a
  `grinderId`, because Repeat (`history_feature`) loads a recorded workflow back into the
  active one and a fill-in-if-absent would let a new shot inherit another shot's burrs. A
  missing grinder, empty burrs or a failed lookup clears the field instead of keeping an
  unverifiable claim; a context with no `grinderId` is left alone. `WorkflowContext.grinderBurrs`
  rides in `workflowJson`, so no schema change is involved.
- **Match burr tokens on word boundaries.** `combineModelAndBurrs` skips the fold only when
  every whitespace/punctuation-split token of `burrs` is already a token of the model text. A
  substring check reads "EK43" as already containing burr "4", or "Kinu M47" as containing
  "M", and drops the real burr.
- **Suppress only our own echo, by normalized equality.** Visualizer echoes the combined
  string back on every back-synced shot, so `shouldSkipBackSyncedGrinderModel` compares the
  remote value against the string this plugin uploaded, kept per Visualizer id in
  `state.uploadedGrinderModels`. `normalizeGrinderModelText` trims, lower-cases and collapses
  inner whitespace, so a round trip differing only in case or spacing still counts as ours;
  anything else is a real edit and has to apply. With no recorded upload string (an older
  install, or a mapping rediscovered by `refreshLocalShotMap`) the guard recomputes from the
  local shot's own context and compares the same way; with nothing to compare against, apply
  the remote value rather than dropping it on a guess.
- **A remote model edit takes ownership of the field.** When back-sync applies one it sends
  `grinderBurrs: null` with it and calls `forgetUploadedGrinderModel`: keeping the snapshot
  would re-append the burrs on the next upload, and keeping the upload string would make the
  guard suppress a later revert to that value. Only a remote value that names a model counts
  as an edit — an absent or empty `grinder_model` is the generic null-ing `mapRemoteToLocal`
  already does, and leaves both alone.
- **Keep the `storageRead` layering.** The reply for `uploadedGrinderModels` layers under
  whatever the session has already recorded, because that read can land after an upload has
  remembered its string.
