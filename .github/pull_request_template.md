## Summary

Describe the problem and fix in 2–5 bullets:

> **Naming:** The display name is **Decaid**. The Dart package, bundle ID, database, and plugin extension retain legacy identifiers for compatibility — see the naming table in [`CLAUDE.md`](CLAUDE.md).

- Problem:
- Why it matters:
- What changed:
- What did NOT change (scope boundary):

## Change Type (select all)

- [ ] Bug fix
- [ ] Feature
- [ ] Refactor required for the fix
- [ ] Docs
- [ ] Security hardening
- [ ] Chore / infra
- [ ] Plugin (DYE2 or bundled skin)

## Scope (select all touched areas)

- [ ] BLE transport / device comms
- [ ] REST API / handlers
- [ ] WebSocket API
- [ ] Machine state / shot logic
- [ ] Scale / weight / flow
- [ ] Profiles / beans / grinders / workflows
- [ ] WebUI skins
- [ ] Plugins / JS runtime
- [ ] UI / Flutter widgets
- [ ] Storage / Drift database
- [ ] CI / build / infra
- [ ] Docs / specs

## Linked Issue (required for external contributions)

External PRs must reference an **open issue accepted for implementation** with either the `ready-for-agent` or `ready-for-human` label. If a proposal went through a Discussion or Project first, link the concrete accepted implementation issue here.

Use at least one:

- Fixes #
- Closes #
- Resolves #
- Related #

Maintainer and automated repository-maintenance PRs may write `N/A`.

## Contributor Responsibility (required)

AI-assisted development is allowed. The person submitting the PR remains responsible for the submitted work.

- [ ] I have reviewed and understand all changes in this PR and take responsibility for their correctness, security, behavior, licensing, and provenance, including any AI-assisted or AI-generated work. <!-- contributor-responsibility -->

## Root Cause (if bug fix)

For bugs: explain why this happened, not just what changed. Otherwise write `N/A`.

- Root cause:
- Missing detection or guardrail:
- Contributing context (if known):

## Regression Test Plan (if bug fix or refactor)

For bugs and refactors: name the smallest reliable test that should catch this. Otherwise write `N/A`.

- Coverage level that should have caught this:
  - [ ] Unit test
  - [ ] Integration test (mock transport edge)
  - [ ] End-to-end test (`simulate=1` + curl/websocat)
  - [ ] Existing coverage already sufficient
- Target test or file:
- Scenario the test should lock in:
- If no new test added, why not:

## Documentation Obligations (required)

These are **not optional**. Stale specs mislead clients and agents.

- [ ] API spec updated: `assets/api/rest_v1.yml` or `assets/api/websocket_v1.yml` (if REST/WebSocket changed)
- [ ] API docs updated: `doc/Api.md` (if user-facing endpoint changed)
- [ ] Plugin docs updated: `doc/Plugins.md` (if events/API changed)
- [ ] Skin docs updated: `doc/Skins.md` (if skin behavior changed)
- [ ] Profile docs updated: `doc/Profiles.md` (if profile handling changed)
- [ ] Device docs updated: `doc/DeviceManagement.md` (if device flows changed)
- [ ] N/A — no docs affected

## Security Impact (required)

This app runs a local web server (port 8080) and connects to BLE/USB hardware.

- New or changed REST endpoints? (`Yes/No`)
- New or changed WebSocket topics? (`Yes/No`)
- New or changed network calls? (`Yes/No`)
- BLE/USB surface changed? (`Yes/No`)
- File system access changed? (`Yes/No`)
- Plugin sandbox boundary changed? (`Yes/No`)
- If any `Yes`, explain risk and mitigation:

## User-Visible Changes

List user-visible changes (including defaults, config, behavior). If none, write `None`.

## Verification

### Local gates (run before pushing)

- [ ] `dart format lib test` — no remaining changes
- [ ] `flutter analyze` — clean (no new warnings)
- [ ] `flutter test` — all pass
- [ ] `./scripts/fetch_dye2_plugin.sh` — DYE2 plugin installed into `assets/plugins/dye2.reaplugin/`

### Manual verification (if applicable)

- OS / platform tested:
- Simulated devices? (`simulate=1`): `Yes/No`
- Real hardware? (DE1/Bengle/scale): `Yes/No`
- What you personally verified and how:
- Edge cases checked:
- What you did **not** verify:

### Evidence

Attach at least one:

- [ ] Test output (failing before + passing after)
- [ ] Log snippets
- [ ] Screenshot / recording (UI changes)
- [ ] curl / websocat output (API changes)

## Compatibility & Migration

- Backward compatible? (`Yes/No`)
- Config / env changes needed? (`Yes/No`)
- Database migration needed? (`Yes/No`)
- If any `No` or `Yes`, explain exact steps:

## Risks & Mitigations

List only real risks for this PR. If none, write `None`.

- Risk:
  - Mitigation:
