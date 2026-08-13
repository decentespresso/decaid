# Plan: Bengle feature completion (feat/bengle-feature-completion)

One replacement PR superseding historical Decaid PRs #462, #463, #464, #465,
#467, #468 (umbrella tracker: #469). Every feature is re-derived from the
current Bengle firmware, never from the historical PRs.

## Source of truth (recorded 2026-02-14)

| Repo | Ref | SHA |
|------|-----|-----|
| decentespresso/decaid | `main` | `bc56025ee4e454c9910dd876897ef674bea535a9` |
| tadelv/Bengle (`rheasman/Bengle`) | `master` (default branch) | `2377c7e0e48e9ee2c43cf02ad2f82028252f56e8` |

Bengle firmware snapshot: `BengleMainCPUFirmware` at that SHA. If either HEAD
moves materially during this work, re-check the affected firmware behavior.

## Firmware audit (verified against the snapshot)

### Scale calibration — `src/Classes/System.cpp` `startScaleCalStep()` /
`updateScaleCalProcedure()` / `getScaleCalStatePackedU32()`,
`src/Classes/CLoadCellCal.hpp`

| MMR | addr | perms | semantics |
|-----|------|-------|-----------|
| `ScaleCalCmd` | 0x00803880 | W | 0=abort, 1=precision zero (settle 10 s + avg 5 s), 2=isolated-cell gain latch (auto-detect cell, settle 10 s + avg 5 s), 3=quick tare, 4/5 retired (rejected). Non-zero commands ignored while the cal machine is busy or while API state is Espresso. |
| `ScaleCalState` | 0x00803884 | R | Packed u32: `Step[31:24]` (0 Idle, 1 Zeroing, 2 CalLatch, 4 Taring, 5 Complete, 6 Error), `Cell[23:20]` (0 none, 1 A, 2 B), `SubState[19:16]` (0 settling, 1 averaging, 2 done, 3 error), `SecondsRemaining[15:8]`, `CalStatus[7:0]` (0 Ok, 1 Incomplete, 2 NoZero, 3 NotSettled, 4 BadWeight, 5 BadDelta, 6 IllConditioned, 7 OutOfRange, 8 NotIsolated, 0xFF none/in-progress). |
| `ScaleCalWeight` | 0x00803888 | RW | Known cal weight, wire value = grams × 10. Firmware model is a float in grams (min 1.0, max 10000.0, default 200.0); `startCalPoint(float weightGrams)` consumes the float, no truncation. |
| `ScaleTare` | 0x0080388C | W | Quick tare (already wired in Decaid as `BengleScaleMmr.scaleTare`). |

Stale-terminal race: `ScaleCalProc.step` latches `Complete`/`Error` until the
next command. The client accepts a command only when the polled step leaves
the pre-command terminal value (firmware sets the in-progress step
synchronously in the write handler for accepted commands; busy/Espresso
rejections leave the old terminal value). No historical constants needed.

### LED strips — `src/Classes/Data/APIView.cpp` `F_LEDStripColor` /
`F_LEDStoreColor` / `applyLEDsForGivenState` / `sendLEDColors` /
`syncSwitchColorsFromStrip`

| MMR | addr | perms | semantics |
|-----|------|-------|-----------|
| `FrontLEDColor` | 0x00803890 | RWD | Live front colour 0x00RRGGBB. Write pushes to strip immediately; PERM_RWD so the value is persisted — but the firmware overwrites it on every sleep/wake transition from the palette. |
| `RearLEDColor` | 0x00803894 | RWD | Live rear colour, same behavior. |
| `FrontLEDAwake` | 0x00803898 | RWD | Persisted palette; applied by FW on wake and immediately if machine is currently awake. |
| `RearLEDAwake` | 0x0080389C | RWD | ditto |
| `FrontLEDSleep` | 0x008038A0 | RWD | Persisted palette; applied on sleep / immediately if currently asleep. |
| `RearLEDSleep` | 0x008038A4 | RWD | ditto |

- There is NO independent `frontSwitch` MMR. The HV front switch palette is
  derived from the FRONT strip palette (`syncSwitchColorsFromStrip`), with
  black substituted by product defaults (`kSwitchDefaultAwake=0xFFF0C8`,
  `kSwitchDefaultAsleep=0x555043`).
- Live registers are persisted but clobbered by state changes — they are a
  snapshot, not a config surface. Historical "non-persistent preview" wording
  is wrong; live-register preview endpoints are NOT useful and are dropped.
- Palette writes are write-through and persisted. There is no commit latch
  and no rollback.

### Cup warmer / mat — `src/Classes/System.cpp` `controlMatTemp()` (loop)

| MMR | addr | perms | semantics |
|-----|------|-------|-----------|
| `CupWarmerMode` | 0x008038AC | RW | 0/1 manual enable. NOT persisted; boots to 0. Manual mat drive additionally requires machine Idle and `MatSetPoint > 0`. |
| `MatCurrentTemp` | 0x008038CC | R | wire = °C × 10; raw 0 = no valid reading. |
| `MatPreheatEnable` | 0x008038D0 | RWD | 0/1, persisted. Schedule drives the mat. |
| `MatPreheatLeadMin` | 0x008038D4 | RWD | 0..120, persisted, default 30. |
| `MatPreheatActive` | 0x008038D8 | R | 1 = schedule (not manual mode) is currently driving the mat. |

- Preheat runs `MatPreheatLeadMin` before a wake window opens until the window
  closes, while the machine stays ASLEEP (24 V rail live in Sleep; boilers
  cold). Requires schedule enabled + valid clock + `MatSetPoint > 0`.
- `MatSetPoint` (0x00803874, RWD, persisted) is already implemented in Decaid
  (#605); not touched except for the new enable/temperature split.
- `MatHeaterDrivePct`, `MatTempFault`, `V24CurrentBudget`: no Decaid consumer;
  NOT exposed.

### Schedule + inactivity — `src/Classes/System.hpp` (clock/schedule),
`src/StateMachines/ShotMachine.cpp` `checkSchedule()` /
`checkInactivitySleep()`, `src/Classes/Data/APIView.cpp` `F_SetClock` /
`F_ScheduleEntry` / `F_ScheduleControl`

| MMR | addr | perms | semantics |
|-----|------|-------|-----------|
| `InactivitySleepTimeout` | 0x008038BC | RWD | Minutes, 0=disabled, max 240, default 60, persisted. Acts only when NO tablet is connected (tablet owns sleep); if expired when the tablet drops, sleeps within a tick. |
| `SetLocalTimeOfWeek` | 0x008038C0 | RW | Local time as seconds since Sunday 00:00:00. Sets the software wall-clock (RAM-only, no RTC; invalid until first sync, lost on power cut). |
| `ScheduleEntry` | 0x008038C4 | RW | One window, packed `(dow<<22)|(startMin<<11)|endMin`. dow 0=Sunday..6=Saturday, start inclusive, end exclusive, `start>=end` or `end>1440` or `dow>6` rejected, max 32 entries. Appended to a RAM-only table. |
| `ScheduleControl` | 0x008038C8 | RW | 0 = clear table + disable; 1 = enable. |
| `ScheduleStatus` | — | — | DOES NOT EXIST in current firmware. Not invented. |

- No `ScheduleStatus` MMR. Firmware "sleep_at = max(window_end,
  last_activity + timeout)"; a scheduled wake does NOT re-arm the idle clock
  (`SuppressNextWarmIdleRearm`), so an unattended window ends at close.
- `currentAwakeWindowKey()` returns NOT_READY (-1) while disabled/mid-rewrite/
  no clock and preserves `LastWokenWindowKey` across a table rewrite, so
  clearing+reloading the table never causes a spurious wake for a window the
  machine already woke for (manual mid-window sleep stays honored). Rewrites
  while awake are edge-neutral. Re-push on every connect is the firmware's
  expected contract.
- `InactivitySleepTimeout=0` = disabled in firmware, matching Decaid's
  `sleepTimeoutMinutes` range 0..240. NO forced 60-minute substitution is
  carried over from #467. Persisted register — safety consequence called out
  in the PR description.

### Capability gate

No reliable build→feature mapping exists in the Bengle repo: `CPUFirmwareBuild`
comes from `AppSlot.Version` stamped into the image at flash time
(`makeheaderedbinfile.py` reads it back from offset 0xD0), not derivable from
source. Rows 0–38 of MMR.def are the old shipped map; rows 39+ are the new
surface.

Old firmware behavior for unknown MMR addresses (verified in APIView.cpp
`findRange`/`read`/`write`): reads are flushed with NO response (the request
queue entry is dropped), writes are silently skipped with a warning.

=> Use the plan's fallback: **one-probe-per-connection feature detection**.
Probe = single read of `ScaleCalWeight` (0x00803888) at connect, shared
in-flight, latched per connection. New firmware responds (default wire value
2000; can be 0 only if a user forced it via raw MMR — our API never writes 0,
minimum 1 g). Old firmware never responds → `MmrTimeoutException` →
"unsupported" latched for the connection; REST surfaces return 404 with a
"requires newer firmware" message. One bounded probe, no timeout storms.

## Design decisions (derived, documented)

1. **Schedule translation** (documented in `wake_schedule_sync`):
   - Enabled schedule with `keepAwakeFor=N` → window `[start, start+N)`.
   - Enabled schedule without `keepAwakeFor` → window
     `[start, start + 240)` — 240 min is the firmware's maximum
     `InactivitySleepTimeout` value, i.e. the longest awake stretch the
     firmware can represent. Product decision (confirmed 2026-02-14): a
     schedule without an explicit keep-awake means "wake for the day", so
     the firmware keeps the machine awake the maximum supported time.
     Midnight crossing still splits app-side.
   - Midnight-crossing windows are split app-side into `[start, 1440)` on day
     D + `[0, end)` on day D+1 (firmware rejects `start >= end`).
   - Dart weekday (Mon=1..Sun=7) → firmware dow (`weekday % 7`).
   - Push clock + table on every connect (RAM-only, firmware contract) and on
     schedule/sleep-timeout setting changes. Rewrite = control 0 → entries →
     control 1; control 0 alone when no schedules (clears stale table).
   - DST/timezone changes: clock is re-pushed on connect and on schedule
     changes; between pushes the firmware clock free-runs at the last pushed
     offset (documented limitation).
2. **LED JSON**: keep `frontStrip`/`backStrip`/`frontSwitch` shape.
   `frontStrip`/`backStrip` map 1:1 to the four palette registers.
   `frontSwitch` is DERIVED from the front strip palette exactly like the
   firmware derives it (black → product defaults) and is ignored on write —
   there is no independent hardware control. GET hydrates from firmware on
   connect; on hydration failure the API returns 503 "unavailable" rather
   than fabricated black. `PUT` is write-through; `POST /commit` is a
   documented compatibility no-op (202); `POST /reset` re-reads from firmware
   (truthful "reload", no rollback).
3. **Cup warmer API**: `GET /cupWarmer` gains `enabled` (CupWarmerMode) and
   `currentTemperature` (nullable; null when raw 0). `PUT {temperature}`
   keeps meaning "set target AND enable manual heating" (back-compat);
   `PUT {enabled}` alone toggles manual heating without touching the
   setpoint; both allowed together. No auto-re-enable on connect (mode is
   RAM-only and Decaid stores no cup-warmer state).
4. **Preheat API**: new `GET/PUT /cupWarmer/preheat` (`enabled`,
   `leadMinutes` 0..120, `active` read-only). Firmware-persisted; Decaid
   stores nothing and does not reassert on connect. No app-side timer.
5. **Scale calibration API**: new `GET /scaleCalibration` (full packed-state
   decode) and `PUT /scaleCalibration` with `command` ∈
   {`abort`,`zero`,`latch`} + `weightGrams` for `latch`. Tare stays on the
   existing integrated-scale path; commands 4/5 not exposed. `weightGrams`
   float, min 1 g, max 10000 g, no whole-gram restriction (firmware is
   float). Single-flight is firmware-side; the client observes acceptance by
   the step leaving its terminal value.
6. **Inactivity timeout**: app `sleepTimeoutMinutes` (0..240, 0=disabled)
   pushed 1:1 to `InactivitySleepTimeout` on connect and on setting change.
   No 60-minute floor. Safety consequence (persisted register) documented in
   the PR.
7. **Capabilities list** gains `scaleCalibration`, `preheat`, `wakeSchedule`;
   `cupWarmer`/`ledStrip`/`integratedScale`/`stopAtWeight` unchanged. All
   gated on `BengleInterface` + firmware probe; stock DE1 untouched.

## Implementation order (one branch, one PR, logical commits)

1. Firmware audit + `BengleMmr`/`BengleSteamMmr` extensions, probe
   (`BengleFirmwareProbe`), capability list + REST 404s. (This plan.)
2. Scale calibration (interface + impl + tests + handler + spec).
3. LED strip real implementation (hydration, write-through, derived switch,
   truthful commit/reset).
4. Cup warmer mode + current temperature.
5. Scheduled pre-warm.
6. Firmware wake-schedule sync + inactivity timeout push (PresenceController
   extension + translation unit tests).
7. API/docs/scenarios finalization: `assets/api/rest_v1.yml`,
   `doc/Api.md`, `doc/DeviceManagement.md`, decent-app scenarios, PR with
   historical-disposition section.

## Verification

- Byte-exact FakeBleTransport tests: addresses, packed payloads, write
  sequences (control 0 → entries → 1).
- Scaling/range tests: weight ×10, mat temp ×10 nullable, timeout 0..240,
  lead 0..120, RGB 16-bit → 0x00RRGGBB.
- State-machine tests: cal acceptance/rejection, stale-terminal guard,
  busy/Espresso rejection, hydration failure.
- Schedule translation tests: weekday mapping, midnight split, keepAwakeFor
  vs sleep-timeout fallback, disabled-timeout skip, 32-entry cap.
- Plain-DE1 negative tests: no Bengle MMR writes.
- `dart format lib test`; focused tests per workstream; `flutter analyze`;
  full `flutter test`; sb-dev smoke tests (curl/websocat) per decent-app
  scenario updates.
- Hardware: real Bengle smoke tests (cal zero+latch A/B, LED palettes,
  manual warmer, mat temp, firmware schedule wake with tablet absent,
  scheduled pre-warm) — only if hardware is available; stated explicitly
  otherwise.

## Historical disposition (for the PR description)

- #461 → superseded by #601 (A013 telemetry, weight, GFlow, milk probe,
  TargetMilkTemp, steam stop, EndOfShotWeight, ScaleTare). No work here.
- #462 → superseded by #601 + #604 (SAW, tare, protected scaled writes).
  Zero new implementation code.
- #463 → superseded by this PR's current-firmware calibration. Dropped:
  left/right explicit cell commands, whole-gram restriction, historical
  terminal constants.
- #464 → superseded by this PR's LED implementation. Dropped: live-preview
  endpoints (live registers are persisted but clobbered by state changes —
  not a config surface), fake frontSwitch control (derived, not independent).
- #465 → TargetMilkTemp via #601 + MatSetPoint via #605 + this PR's manual
  mode/temperature work.
- #466 → superseded by #486 (Bengle v2 profile upload).
- #467 → superseded by this PR's schedule sync. Removed: `ScheduleStatus`
  invention, forced 60-minute floor, arbitrary 30-minute wake window.
- #468 → superseded by this PR's pre-warm. Removed: contract v2, additive
  pin, two-firmware-source contract model, `assets/api/bengle_hw_v1.yml`.
- #469 remains the historical umbrella tracker; no edits.
