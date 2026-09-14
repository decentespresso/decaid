# Bengle LED strip (firmware palette)

Exercises the real firmware LED palette surface on a `MockBengle`: hydrated
read, write-through PUT, live preview, compatibility commit, truthful reset.
Palette writes are persisted by the firmware immediately; there is no commit
latch and no rollback. `frontSwitch` is derived from the front strip (no
independent switch register) and ignored on write.

The firmware keeps SHOWING a colour apart from DECIDING one. The four palette
registers are stored; the two live registers light the strip at once and are
recomputed from the stored pair at the next sleep or wake. Preview writes only
the live pair, which is the only way to show an asleep colour to someone
editing it on an awake machine.

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
    "frontStrip": {"sleeping": "0000FF000000", "awake": "FF0080000000"},
    "backStrip":  {"sleeping": "000000000000", "awake": "FFFFFFFFFFFF"},
    "frontSwitch":{"sleeping": "FFFF00000000", "awake": "000000000000"}
  }' | jq
```

Expect status 200 with the stored canonical palette as the body, not an
acknowledgement:

```json
{
  "frontStrip":  {"sleeping": "0000FF000000", "awake": "FF0080000000"},
  "backStrip":   {"sleeping": "000000000000", "awake": "FF00FF00FF00"},
  "frontSwitch": {"sleeping": "0000FF000000", "awake": "FF0080000000"}
}
```

The palette registers are persisted by the firmware on write. The wire
stores 8 bits per channel, so non-byte-aligned 16-bit values in the request
are quantized (low bytes dropped) — `backStrip.awake` came in as
`FFFFFFFFFFFF` and is stored as `FF00FF00FF00`. `frontSwitch` in the
request is ignored: the echoed one is derived from the stored front strip,
which is why the sent `{"sleeping": "FFFF00000000", "awake":
"000000000000"}` does not appear.

### 4. Read back

```bash
curl -s http://localhost:8080/api/v1/machine/ledStrip | jq
```

Expect the response to be byte-identical to the 200 body returned in
step 3 (not to the body sent in the PUT): `frontStrip`/`backStrip`
quantized, `frontSwitch` derived from the front strip.

### 5. Preview shows a colour without storing it

```bash
curl -s -X POST http://localhost:8080/api/v1/machine/ledStrip/preview \
  -H 'Content-Type: application/json' \
  -d '{"frontStrip": "FFFF00000000", "backStrip": "0000FFFF0000"}'
```

Expect 202. Then read the palette back:

```bash
curl -s http://localhost:8080/api/v1/machine/ledStrip | jq
```

Expect the state from step 3, UNCHANGED. A preview is not a decision: it moves
the live registers only, so the stored palette a later GET reports does not move.

Either key may be omitted; a body naming neither is a 400:

```bash
curl -s -X POST http://localhost:8080/api/v1/machine/ledStrip/preview \
  -H 'Content-Type: application/json' -d '{}' | jq
```

Expect `{"error": "name at least one of frontStrip or backStrip"}` with status 400.

### 6. A repeated preview frame is accepted and idempotent

Send the same body twice:

```bash
for i in 1 2; do
  curl -s -o /dev/null -w '%{http_code}\n' -X POST \
    http://localhost:8080/api/v1/machine/ledStrip/preview \
    -H 'Content-Type: application/json' \
    -d '{"frontStrip": "FFFF00000000"}'
done
```

Both answer 202, and the strip is unchanged by the second. On a real machine the
second sends no MMR write at all, because the live register already holds that
colour — a colour picker sends a frame per render, and a resting finger would
otherwise keep the write path busy. That the write is skipped is not visible over
HTTP; it is pinned at the unit tier by
`test/unit/models/device/impl/de1/unified_de1/led_strip_capability_test.dart`
("a preview frame that repeats the shown colour writes nothing"), because
`MockBengle` reaches no MMR to count.

### 7. Clearing a preview returns the stored palette to the strip

```bash
curl -s -X POST http://localhost:8080/api/v1/machine/ledStrip/preview/clear \
  -H 'Content-Type: application/json' -d '{}'
```

Expect 202. The strips go back to the stored palette for the state the machine
is IN — not to the awake bank. A preview left uncleared stands until the next
sleep or wake transition recomputes the live registers.

### 8. Commit is a compatibility no-op

```bash
curl -s -X POST http://localhost:8080/api/v1/machine/ledStrip/commit \
  -H 'Content-Type: application/json' \
  -d '{}'
```

Expect 202. Nothing changes: palette writes were already persisted.

### 9. Reset is a truthful reload, not a rollback

```bash
curl -s -X POST http://localhost:8080/api/v1/machine/ledStrip/reset \
  -H 'Content-Type: application/json' \
  -d '{}' | jq
```

Expect the state from step 3 — the firmware cannot undo a persisted write,
and Decaid never pretends otherwise.

### 10. A black front strip yields the default switch palette

```bash
curl -s -X PUT http://localhost:8080/api/v1/machine/ledStrip \
  -H 'Content-Type: application/json' \
  -d '{
    "frontStrip": {"sleeping": "000000000000", "awake": "000000000000"},
    "backStrip":  {"sleeping": "000000000000", "awake": "FF00FF00FF00"},
    "frontSwitch":{"sleeping": "000000000000", "awake": "000000000000"}
  }' | jq
```

```json
{
  "frontStrip":  {"sleeping": "000000000000", "awake": "000000000000"},
  "backStrip":   {"sleeping": "000000000000", "awake": "FF00FF00FF00"},
  "frontSwitch": {"sleeping": "550050004300", "awake": "FF00F000C800"}
}
```

An "LEDs off" strip never blanks a lit switch: the firmware substitutes the
product defaults, and the 200 body reports them.

### 11. Plain DE1 returns 404

If you connect a plain DE1 or MockDe1 (no `simulate=1`), every endpoint
returns 404:

```bash
curl -s http://localhost:8080/api/v1/machine/ledStrip | jq
curl -s -X PUT http://localhost:8080/api/v1/machine/ledStrip -H 'Content-Type: application/json' -d '{}' | jq
curl -s -X POST http://localhost:8080/api/v1/machine/ledStrip/preview -H 'Content-Type: application/json' -d '{"frontStrip": "FFFF00000000"}' | jq
curl -s -X POST http://localhost:8080/api/v1/machine/ledStrip/preview/clear -H 'Content-Type: application/json' -d '{}' | jq
curl -s -X POST http://localhost:8080/api/v1/machine/ledStrip/commit -H 'Content-Type: application/json' -d '{}' | jq
curl -s -X POST http://localhost:8080/api/v1/machine/ledStrip/reset -H 'Content-Type: application/json' -d '{}' | jq
```

All six return `{"error": "ledStrip not supported"}` with status 404.
