# MockDe1 raw machine channel

Preconditions: Flutter, Python 3, and `websocat` are available; bundled assets
are populated as described in `CONTRIBUTING.md`. Use simulated devices only.

```bash
export SB_RUNTIME_DIR=/tmp/decaid-mock-raw
scripts/sb-dev.sh start --platform macos --connect-machine MockDe1
scripts/sb-dev.sh status
curl -sf http://localhost:8080/api/v1/machine/state
```

Keep the WebSocket client's stdin open until every response arrives. Do not use
`websocat -n`: stdin EOF can close the socket before delivering the request.

```bash
python3 - <<'PY'
import json
import select
import subprocess
import urllib.request

with urllib.request.urlopen('http://localhost:8080/api/v1/devices') as response:
    devices = json.load(response)
machines = [d for d in devices if d['type'] == 'machine' and d['state'] == 'connected']
assert len(machines) == 1 and machines[0]['id'] == 'MockDe1', machines

client = subprocess.Popen(
    ['websocat', '-t', 'ws://localhost:8080/ws/v1/machine/raw'],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
)
try:
    for operation, uuid, payload, expected in [
        ('write', 'A010', '00401ebaff000400', '00401EBAFF000400'),
        ('write', 'A00F', '00401EBAFF000401', '00401EBAFF000401'),
        ('read', 'A001', '', ''),
    ]:
        client.stdin.write(json.dumps(dict(type='request', operation=operation,
                                          characteristicUUID=uuid, payload=payload)) + '\n')
        client.stdin.flush()
        assert select.select([client.stdout], [], [], 5)[0], 'raw response timed out'
        response = json.loads(client.stdout.readline())
        assert response == dict(type='response', operation=operation,
                                characteristicUUID=uuid, payload=expected), response
        print(json.dumps(response))
finally:
    client.terminate()
    client.wait(timeout=5)
PY
```

Expected: three response frames, two distinct uppercase write receipts and an
empty default read. The mock records writes in `rawWrites`; unit tests can set
`rawReadResponses[uuid]` to bytes or `null` for an absent characteristic. Unknown
UUIDs and absent characteristics emit no frame, matching `UnifiedDe1`; they do
not produce an invented error response. Raw writes do not change machine logic.

```bash
scripts/sb-dev.sh reload
# Run the Python block again, then inspect logs and stop.
scripts/sb-dev.sh logs -n 30 --filter error
scripts/sb-dev.sh stop
```

Postconditions: all three responses matched before and after reload, and the
simulated app session is stopped.
