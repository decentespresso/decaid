# Manual skin fixtures

`switch-test-a` and `switch-test-b` are two tiny skins for exercising the
embedded `window.decentApp.switchSkin(skinId)` hook by hand. They are not
bundled with the app and are not used by automated tests.

Each page shows its skin id, its origin and port, whether the hook and the host
flag are present, and buttons for: switch to the other skin, switch to itself,
switch to a missing id, two switch calls in one tick, and exit to dashboard.
Every call logs the value `switchSkin` returned.

Steps, including install, the A -> B -> A round trip, the rejection cases and
the failure-to-serve rollback, are in
`.agents/skills/decent-app/scenarios/skin-switch-embedded.md`.
