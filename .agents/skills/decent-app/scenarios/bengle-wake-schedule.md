# Scenario: Bengle firmware wake-schedule sync

Verifies that `PresenceController` mirrors the app's sleep timeout and wake
schedules into the Bengle firmware on connect and on setting change
(`InactivitySleepTimeout` 0x38BC persisted; local wall-clock + wake table
0x38C0-0x38C8 RAM-only). The MockBengle records what was pushed; the wire
sequence (clock, control 0, entries, control 1) is covered by byte-exact
unit tests (`test/models/device/bengle_wake_schedule_test.dart`).

No REST endpoint exists for this surface — the push is automatic. This
scenario verifies it through the mock's recorded state.

## Preconditions

```bash
scripts/sb-dev.sh start --connect-machine MockBengle --connect-scale MockScale
```

## Steps

### 1. Capability discovery

```bash
curl -sf http://localhost:8080/api/v1/machine/capabilities | jq -e '.capabilities | index("wakeSchedule") != null'
```

Exit 0 → `wakeSchedule` present.

### 2. Connect pushes the app defaults

On connect (or when schedules/sleep timeout change), the app pushes:

- the app's `sleepTimeoutMinutes` (default 30) 1:1 to the firmware
  (0..240, 0 = disabled — the app never substitutes a 60-minute floor);
- the local wall-clock as seconds since Sunday 00:00:00 local;
- one wake window per enabled schedule: `keepAwakeFor=N` -> `[start,
  start+N)`, otherwise `[start, start+240)` (firmware maximum); Dart
  weekday (Mon=1..Sun=7) -> firmware dow (`weekday % 7`, 0=Sunday);
  midnight-crossing windows split into two entries; empty schedules push
  `ScheduleControl=0` (clear + disable).

### 3. Reconnect re-pushes

Restart the app (`scripts/sb-dev.sh stop && scripts/sb-dev.sh start ...`)
or reconnect the machine: the clock and table are RAM-only in the firmware,
so every connect re-pushes them even when the app values did not change.

### 4. Plain DE1 gets no pushes

Connect a plain MockDe1: the firmware surface is Bengle-only; no MMR writes
for these registers occur (no clock/table/timeout writes). Byte-exact proof
lives in the unit tests; stock DE1 behavior is unchanged.

## Postconditions

```bash
scripts/sb-dev.sh stop
```
