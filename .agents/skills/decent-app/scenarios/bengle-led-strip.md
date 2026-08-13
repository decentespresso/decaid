# Bengle LED strip (firmware palette)

Exercises the real firmware LED palette surface on a `MockBengle`: hydrated
read, write-through PUT, compatibility commit, truthful reset. Palette
writes are persisted by the firmware immediately; there is no commit latch
and no rollback. `frontSwitch` is derived from the front strip (no
independent switch register) and ignored on write.

## Preconditions

- A running Decent instance with `simulate=1,scale` (MockBengle auto-discovered)
- `curl` and `jq` available

## Procedure

### 1. Verify capability

```bash
curl -s http://localhost:8080/api/v1/machine/capabilities | jq
```

Expect `ledStrip` in the `capabilities` array.

### 2. Read the hydrated palette

```bash
curl -s http://localhost:8080/api/v1/machine/ledStrip | jq
```

MockBengle hydrates a deterministic non-black palette at connect, e.g.
`frontStrip.awake: "FF00F0008000"`. The response is never fabricated
black: a machine whose hydration failed answers 503.

### 3. Write a config (write-through)

```bash
curl -s -X PUT http://localhost:8080/api/v1/machine/ledStrip \
  -H 'Content-Type: application/json' \
  -d '{
    "frontStrip": {"sleeping": "0000FFFF0000", "awake": "FFFF80000000"},
    "backStrip":  {"sleeping": "000000000000", "awake": "FFFFFFFFFFFF"},
    "frontSwitch":{"sleeping": "FFFF00000000", "awake": "000000000000"}
  }' | jq
```

Expect `{"status": "accepted"}` (status 200). The palette registers are
persisted by the firmware on write; `frontSwitch` in the body is ignored.

### 4. Read back

```bash
curl -s http://localhost:8080/api/v1/machine/ledStrip | jq
```

Expect `frontStrip`/`backStrip` to match step 3; `frontSwitch` echoes the
front strip (derived).

### 5. Commit is a compatibility no-op

```bash
curl -s -X POST http://localhost:8080/api/v1/machine/ledStrip/commit \
  -H 'Content-Type: application/json' \
  -d '{}'
```

Expect 202. Nothing changes: palette writes were already persisted.

### 6. Reset is a truthful reload, not a rollback

```bash
curl -s -X POST http://localhost:8080/api/v1/machine/ledStrip/reset \
  -H 'Content-Type: application/json' \
  -d '{}' | jq
```

Expect the state from step 3 — the firmware cannot undo a persisted write,
and Decaid never pretends otherwise.

### 7. Plain DE1 returns 404

If you connect a plain DE1 or MockDe1 (no `simulate=1`), all four endpoints
return 404:

```bash
curl -s http://localhost:8080/api/v1/machine/ledStrip | jq
curl -s -X PUT http://localhost:8080/api/v1/machine/ledStrip -H 'Content-Type: application/json' -d '{}' | jq
curl -s -X POST http://localhost:8080/api/v1/machine/ledStrip/commit -H 'Content-Type: application/json' -d '{}' | jq
curl -s -X POST http://localhost:8080/api/v1/machine/ledStrip/reset -H 'Content-Type: application/json' -d '{}' | jq
```

All four return `{"error": "ledStrip not supported"}` with status 404.
