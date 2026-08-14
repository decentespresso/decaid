# AI Bengle Notes

Domain knowledge for the Bengle machine implementation
(`lib/src/models/device/impl/bengle/`,
`lib/src/models/device/impl/de1/unified_de1/*_capability.dart`,
`lib/src/models/device/{bengle_interface,scale_calibration,cup_warmer}.dart`,
`lib/src/models/firmware_wake_window.dart`,
`lib/src/controllers/presence_controller.dart` Bengle sync,
`lib/src/services/webserver/de1handler.dart` Bengle endpoints).

All Bengle MMR knowledge below was verified against
`BengleMainCPUFirmware` at tadelv/Bengle master `2377c7e0`
(`src/Classes/Data/MMR.def` rows 39-61 and the consuming C++:
`System.cpp`/`System.hpp`, `APIView.cpp`, `ShotMachine.cpp`,
`CLoadCellCal.hpp`).

## Supported firmware surface (single-surface contract)

Decaid supports exactly ONE Bengle firmware surface: the current one (MMR
rows 39+): scale calibration, LED palette, cup-warmer mode/current
temperature, preheat, inactivity timeout, wake scheduling. No intermediate
combination of those features is supported. Older Bengle firmware is
outdated/unsupported — the machine is firmware-incompatible, never a Bengle
with a reduced capability set. The probe is a compatibility check, not
feature detection: successful probe = full current surface available;
unsuccessful = outdated firmware.

- **Probe**: one read of `ScaleCalWeight` (row 41) per connection, 2
  attempts x 2 s. Any response (even zero) proves the register exists ->
  current surface; a timeout on every attempt -> outdated.
- **Why no build gate**: `CPUFirmwareBuild` is stamped into the image at
  flash time (makeheaderedbinfile.py reads it back from offset 0xD0), so no
  reliable build-to-feature mapping exists.
- **Why the read discriminates**: firmware without rows 39+ flushes reads of
  those addresses with NO response.
- **Why the bounded retry**: a dropped BLE response is
  protocol-indistinguishable from old-firmware silence, so one timeout must
  not latch the whole surface unsupported for the connection; worst case
  +2 s on genuinely outdated firmware at connect. Latched per connection,
  never repeated by polled endpoints.
- **API contract**: the capability list is all-or-nothing (full 7-item set
  or empty); every Bengle endpoint 404s on outdated firmware;
  `/machine/info` reports `extra.bengleFirmwareSurface` = `current` |
  `outdated` so callers can distinguish outdated firmware from a plain DE1
  (both advertise no capabilities).

## MMR surface map (rows 39+)

| Row | Register | Address | Kind | Notes |
|-----|----------|---------|------|-------|
| 39 | ScaleCalCmd | 0x00803880 | int32 0..5 | calibration command |
| 40 | ScaleCalState | 0x00803884 | int32 | packed state u32 |
| 41 | ScaleCalWeight | 0x00803888 | float | 0.1 g units |
| 45 | FrontLEDAwake | 0x00803898 | int32 | 0x00RRGGBB, persisted |
| 46 | RearLEDAwake | 0x0080389C | int32 | persisted |
| 47 | FrontLEDSleep | 0x008038A0 | int32 | persisted |
| 48 | RearLEDSleep | 0x008038A4 | int32 | persisted |
| 50 | CupWarmerMode | 0x008038AC | int32 0..1 | RAM-only, boots to 0 |
| 54 | InactivitySleepTimeout | 0x008038BC | int32 0..240 | persisted, minutes |
| 55 | SetLocalTimeOfWeek | 0x008038C0 | int32 0..604800 | RAM-only clock |
| 56 | ScheduleEntry | 0x008038C4 | int32 | packed window, RAM-only |
| 57 | ScheduleControl | 0x008038C8 | int32 0..255 | 0 clear+disable, 1 enable |
| 58 | MatCurrentTemp | 0x008038CC | float | deg C x 10; 0 = no valid reading |
| 59 | MatPreheatEnable | 0x008038D0 | int32 0..1 | persisted |
| 60 | MatPreheatLeadMin | 0x008038D4 | int32 0..120 | persisted |
| 61 | MatPreheatActive | 0x008038D8 | int32 0..1 | read-only |

## Scale calibration (rows 39-41)

- Engine is order-free: platform removed, a known mass placed directly on
  either load cell, `latch` run once per cell; the firmware auto-detects the
  loaded cell and the second distinct-cell latch solves and persists the
  calibration.
- Commands are staged asynchronously; a non-zero command is ignored while
  the cal machine is busy or a shot is in progress. Acceptance is therefore
  observed: the polled step leaving its previous value (abort always lands
  on Idle and is never rejected).
- ScaleCalState packing: step bits 31-24, cell bits 23-20 (0 none, 1 A,
  2 B), sub-state bits 19-16, seconds remaining bits 15-8, status bits 7-0
  (0xFF = none/in-progress; mirrors C_LoadCellCal::E_CalStatus).
- Wire value 3 was the old explicit point-2 step, never emitted by current
  firmware; unknown values decode as idle. Commands 4/5 (explicit
  left/right latches) are retired.
- Quick tare (3) is deliberately not exposed: Decaid already has the
  integrated-scale tare path (ScaleTare 0x0080388C).
- weightGrams is required for latch, clamped 1..10000 g; the firmware
  stores it as a float, so fractional grams are preserved.
- Client submissions are serialized so concurrent submissions cannot
  interleave their acceptance reads.

## LED palette (rows 45-48)

- The four palette registers are persisted (PERM_RWD); writes are
  write-through and the firmware applies the colour immediately when the
  machine is currently in the matching state and on every sleep/wake
  transition (APIView.cpp F_LEDStoreColor / applyLEDsForGivenState /
  sendLEDColors).
- There is no independent frontSwitch register: the HV switch palette is
  derived from the FRONT strip palette; a black strip colour falls back to
  product defaults (kSwitchDefaultAwake 0xFFF0C8 / kSwitchDefaultAsleep
  0x555043 in APIView.cpp — keep in sync) so an "LEDs off" strip never
  blanks a lit switch.
- The live FrontLEDColor/RearLEDColor registers are persisted snapshots
  overwritten on every state change; not a configuration surface.
- The firmware stores 8 bits per RGB channel, so the app quantizes
  (`& 0xFF00`) before writing and publishes exactly the quantized
  representation that was written.
- Hydration happens once per connection; a failed hydration (or a partial
  multi-register write failure) leaves the state unknown (null), never
  fabricated black. commit is a compatibility no-op; reset re-reads the
  palette (truthful reload, not a rollback — the firmware cannot undo a
  persisted write) and returns null on failure even if an older cached
  state exists.

## Cup warmer (rows 50, 58-61)

- Manual mode requires CupWarmerMode=1 AND machine Idle AND
  MatSetPoint > 0 (System.cpp controlMatTemp). CupWarmerMode is RAM-only
  and boots to 0 on every power cycle — deliberately NOT persisted, so the
  heater can never reactivate unattended after a power cut. The app never
  re-enables it on reconnect.
- MatCurrentTemp is deg C x 10 on the wire; raw 0 means no valid reading
  (NTC out of band), surfaced as null.
- Backwards-compatible PUT contract: a temperature-only cupWarmer request
  also enables manual heating (the original endpoint behavior); an explicit
  `enabled` field never passes through an intermediate enable write
  (explicit false disables without destroying the persisted setpoint, which
  scheduled pre-warm needs).
- Preheat runs the mat from MatPreheatLeadMin before a scheduled wake
  window until it closes, with the machine still ASLEEP (only the 24 V rail
  runs), as long as the schedule is enabled, the clock is valid and
  MatSetPoint > 0. MatPreheatEnable/MatPreheatLeadMin are persisted;
  MatPreheatActive is 1 only when the schedule (not manual mode) drives the
  mat. Write order is direction-aware: lead first when enabling (scheduled
  heating must never start with a stale persisted lead between the two
  writes), disable first when disabling (never leave heating enabled while
  the lead is being updated).

## Wake schedule + presence sync (rows 54-57)

- InactivitySleepTimeout: persisted; the firmware sleeps only when NO
  tablet is connected (while a tablet is connected the tablet owns sleep).
  Decaid's `sleepTimeoutMinutes` maps 1:1 (0 -> 0). Pushed on connect and
  on setting change, never continuously.
- SetLocalTimeOfWeek expects LOCAL time as seconds since Sunday 00:00:00,
  computed from calendar fields so a DST transition cannot skew the value
  at push time. The clock and table are RAM-only (no RTC): re-pushed on
  every connect. DST/timezone change during a long-lived connection is
  picked up at the next connect or settings change; unattended wake/preheat
  can shift by an hour if the tablet drops before that.
- ScheduleEntry packing: `(dow << 22) | (startMin << 11) | endMin`; dow is
  0=Sunday..6=Saturday, startMin inclusive (0..1439), endMin exclusive
  (1..1440); the firmware rejects startMin >= endMin, so midnight-crossing
  windows are split into two entries app-side; 32-entry cap
  (MAX_AWAKE_WINDOWS).
- Rewrite sequence: ScheduleControl=0 (clear + disable) -> clock ->
  entries -> ScheduleControl=1 (enable only when entries exist). The old
  table is disabled BEFORE the clock moves, so a clock correction can never
  land inside a window from the table being replaced; currentAwakeWindowKey
  reports NOT_READY mid-rewrite and preserves LastWokenWindowKey, so a
  manual mid-window sleep is never re-woken by the re-push (ShotMachine.cpp
  checkSchedule).
- Translation rules (app WakeSchedule -> firmware windows):
  - disabled schedules are dropped;
  - `keepAwakeFor=N` -> window [start, start+N);
  - no `keepAwakeFor` -> [start, start+240) (the longest unattended awake
    stretch the firmware can represent; product decision 2026-02-14);
  - an empty `daysOfWeek` means every day (matches WakeSchedule.matchesTime);
  - Dart weekday (Mon=1..Sun=7) -> firmware dow (`weekday % 7`);
  - windows crossing midnight split into [start, 1440) on day D and
    [0, end) on day D+1; durations beyond a day keep splitting;
  - result truncated to 32 entries.
- Presence sync (`presence_controller.dart`): pushes are serialized and
  coalescing — every trigger bumps a generation, a single drain applies the
  newest desired state, and the pushed cache commits only after a complete
  successful transaction. A failed push is retried automatically up to 3
  attempts with 2 s backoff; a newer generation arriving during the backoff
  supersedes the failed attempt (the stale state is never pushed on its
  own); after the bound the state stays dirty until the next trigger
  (settings change or reconnect). A mid-flight machine replacement must not
  mark the new machine synchronized, so the cache commits only when the
  device is still the one pushed to.
- Master toggle (userPresenceEnabled): when off, firmware must not own any
  timeout or wake table, so it receives timeout 0 and a cleared, disabled
  table (the wake table runs without the tablet).
