# Guarded plugin machine actions

This scenario checks the stage1 REST contract for a plugin controlling the
primary scale. It uses the simulated device so no hardware is required.

## Preconditions

- Start Decaid with `scripts/sb-dev.sh start --platform linux --connect-machine MockDe1 --connect-scale MockScale` and wait for the REST server.
- Confirm `GET /api/v1/machine/state` reports a connected machine in `idle`.
- Confirm `GET /api/v1/scale/connections` returns an object with a `primary`
  property. The property is either `null` or an object containing string
  `deviceId`, `connectionId`, and `selectionId`.

Save the machine `deviceId` and `connectionGeneration`, and the three primary
identity fields from the two responses.

## Guarded start

Send the saved values to the espresso route:

```sh
curl -i -X PUT http://localhost:8080/api/v1/machine/state/espresso \
  -H 'content-type: application/json' \
  --data '{"guarded":true,"expectedMachineId":"de1-simulated","expectedMachineGeneration":1,"expectedState":"idle","requireInactiveGhc":true,"sourceScale":{"role":"primary","deviceId":"scale-simulated","connectionId":"<connectionId>","selectionId":"<selectionId>"}}'
```

Expect `200` and then an `espresso` machine state. A full gateway must reject
the same start with `409` and must not write to the machine.

## Guarded stop and stale inputs

With the machine in `espresso`, send the analogous guarded request to
`/machine/state/idle`, with `expectedState: "espresso"` and
`requireInactiveGhc: false`. Expect `200`; the request bypasses the queued
write path. A source or machine identity from before reconnect, replacement,
or runtime restart must return `409` and leave the machine unchanged.

Also verify:

- guarded requests with `sourceScale.role: "brewing", "dosing", or
  "auxiliary"` return `400`;
- a machine in `sleeping`, an active GHC, or a missing machine returns `409`;
- malformed nonempty JSON and a non-boolean `guarded` key return `400` without
  a machine write;
- bodyless requests, ordinary legacy JSON, JSON `null`, and
  `{"guarded":false}` retain the legacy route behavior;
- each accepted idle stop prevents an older queued guarded start from running
  afterward.

## Postconditions

Restore the simulated machine to `idle` and leave the gateway in its original
mode. Confirm the primary projection is still internally consistent after any
reconnect or hot reload.
