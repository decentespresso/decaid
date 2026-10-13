# Read-only Grinder observations

## Preconditions

Use a disposable development app in simulate mode, with no selected grinder and
no installed plugin named `issue973.smoke`. Start from this worktree with
`scripts/sb-dev.sh start --platform macos` (or `linux`). Requires jq and websocat.
The source API installs a temporary plugin in app storage; remove it afterwards.

## Fixture

```bash
mkdir -p /tmp/grinder-observations
cat > /tmp/grinder-observations/plugin.js <<'JS'
function createPlugin(host) {
  let context;
  return {
    id: 'issue973.smoke',
    async onLoad() {
      await host.devices.register(
        {driverId: 'grinder', instanceId: 'one', name: 'Read-only observation smoke'},
        {
          async connect(session) {
            context = session;
            await session.publish({state: 'idle', observedSetting: 'espresso/A', observedRpm: 900});
          },
          disconnect() {}
        }
      );
    },
    async __httpRequestHandler(request) {
      try {
        await context.publish(request.body);
        return {status: 200, body: JSON.stringify({accepted: true})};
      } catch (error) {
        return {status: 400, body: JSON.stringify({code: error.code})};
      }
    }
  };
}
JS
cat > /tmp/grinder-observations/manifest.json <<'JSON'
{"id":"issue973.smoke","name":"Observation smoke","author":"test","description":"Temporary read-only grinder","version":"1.0.0","apiVersion":1,"permissions":["api"],"drivers":[{"id":"grinder","type":"grinder","observations":["setting","rpm"]}],"settings":{},"api":[{"id":"publish","type":"http","data":{}}]}
JSON
jq -n --slurpfile manifest /tmp/grinder-observations/manifest.json \
  --rawfile plugin /tmp/grinder-observations/plugin.js \
  '{manifest:$manifest[0],plugin:$plugin}' > /tmp/grinder-observations/source.json
curl -sf -X PUT http://localhost:8080/api/v1/plugins/issue973.smoke/source \
  -H 'Content-Type: application/json' --data-binary @/tmp/grinder-observations/source.json
curl -sf -X POST http://localhost:8080/api/v1/plugins/issue973.smoke/enable
curl -sf -X PUT http://localhost:8080/api/v1/devices/connect \
  -H 'Content-Type: application/json' -d '{"deviceId":"plugin:issue973.smoke:grinder:one"}'
```

## Verify

```bash
curl -sf http://localhost:8080/api/v1/grinder/info | jq .
curl -sf http://localhost:8080/api/v1/grinder/state | jq .
websocat --no-async-stdio -n -U -t --max-messages-rev 1 \
  ws://localhost:8080/ws/v1/grinder/snapshot | jq .
for body in '{"setting":"12"}' '{"rpm":900}'; do
  resource=$(echo "$body" | jq -r 'keys[0]')
  curl -s -X PUT "http://localhost:8080/api/v1/grinder/$resource" \
    -H 'Content-Type: application/json' -d "$body" | jq .
done
curl -s -X POST http://localhost:8080/api/v1/plugins/issue973.smoke/publish \
  -H 'Content-Type: application/json' -d '{"state":"idle","observedRpm":-1}' | jq .
curl -sf -X POST http://localhost:8080/api/v1/plugins/issue973.smoke/publish \
  -H 'Content-Type: application/json' -d '{"state":"idle"}' | jq .
curl -sf http://localhost:8080/api/v1/grinder/state | jq .
websocat --no-async-stdio -n -U -t --max-messages-rev 1 \
  ws://localhost:8080/ws/v1/grinder/snapshot | jq .
```

Expected: info has `capabilities: []`, `observations: ["setting", "rpm"]` and
no controls. REST and WebSocket initially contain `observedSetting: "espresso/A"`
and `observedRpm: 900`, with no v1 setting/RPM. Both command calls return
`unsupported_operation`; negative observed RPM returns `invalid_argument`.
After the state-only publication, both REST and WebSocket omit observed fields.

## Cleanup

```bash
curl -sf -X DELETE http://localhost:8080/api/v1/plugins/issue973.smoke
scripts/sb-dev.sh stop
```

The fixture is removed and no grinder session remains selected. No physical
hardware or shot persistence is involved.
