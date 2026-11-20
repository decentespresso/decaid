# App log upload: warm-up times, 7-day window, onboarding opt-in

## Why

The website Compare page lists warm-up times per model, and the published
numbers disagree with bench tests. Decent wants real-world warm-up times tagged
with machine model and heater voltage. The support log upload already sends the
serial, model, firmware, and heater voltage setting, so it is the cheapest
channel: add warm-up lines to the log instead of building a new plugin and
endpoint.

## Decisions

- **Warm-up lines.** `WarmupLogger` watches the connected machine's snapshots
  and shot settings and writes fixed-format INFO lines, so the server can parse
  them from the uploaded log text:
  - `Warmup start: from=<sleep|connect>, group=<C>, steam=<C>`
  - `Warmup espresso ready: <s>s (group <C> -> <target>)`
  - `Warmup steam ready: <s>s (steam <C> -> 135C)`
  - `Warmup steam final: <s>s (steam <C> -> <target>)`
- **Steam ready is 135C.** de1app refuses steam below 120C and warns between
  120C and 135C (`de1plus/de1_de1.tcl` `Steam` state handler); Decaid treats a
  135C target as the steam-enabled floor. Steam lines are skipped when the steam
  target is below 135C (steam off).
- **Session start.** Leaving `sleeping` starts a `from=sleep` session. The first
  snapshot after connect starts a `from=connect` session when the group is below
  target. Going back to sleep drops the session. Each milestone logs once per
  session.
- **7-day window.** Opting in records `appLogUpload.enabledAt`. Once 7 days have
  passed, the service turns sharing off (consent `denied`, cursor cleared) and
  shows "Sharing ended after 7 days". Users opt in again to share another
  window. A consent granted before this change has no timestamp; the window
  starts at the first check after upgrade.
- **Onboarding opt-in.** The "Link Your Decent Account" step shows the sharing
  switch, off by default. It is applied only when sign-in succeeds. The Account
  page keeps its switch so users can stop early or check status.
- **Copy.** One shared description string for both switches. The wording is
  provisional pending product review.
