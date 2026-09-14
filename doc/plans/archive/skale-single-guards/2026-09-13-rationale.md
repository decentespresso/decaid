# Primary-scale guarded actions

The primary scale gets a small, opt-in machine control contract. The
connection projection carries the scale's public device identity plus opaque
connection and selection tokens. Native scales derive their connection identity
from the runtime, primary role, and controller generation; plugin scales provide
their session identity through the typed protocol-device getter. A reconnect,
replacement, or runtime restart therefore invalidates a previous plugin
request without changing the existing unguarded routes.

The guarded route permits exactly idle-to-espresso starts and
espresso-to-idle stops. Starts require a captured machine identity and
generation, an idle snapshot, inactive GHC, matching primary source, and a
non-full gateway. Those checks run again when a queued write is about to run.
Stops use the direct machine request path and advance a cancellation epoch, so
an older queued guarded start cannot execute after an accepted stop. The
hardware request itself remains asynchronous.

Malformed nonempty JSON and non-boolean `guarded` values return 400 before the
legacy write path. Bodyless requests, ordinary legacy JSON, JSON `null`, and
`guarded: false` preserve compatibility. Non-primary source roles return 400;
the projection and machine-action contract remain primary-only.
