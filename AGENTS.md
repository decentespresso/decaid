# Agent Instructions

For unfamiliar or multi-subsystem tasks, read `doc/AI_REPO_MAP.md` first. For known files or exact symbols, open them directly. Read domain-specific docs only when the task needs them.

## Workflow

### Starting Work

Default to the current branch and leave changes local. Never push, merge, or create a PR unless explicitly asked.

Ask about branch/worktree strategy only when the current state is unsafe or the task depends on it.

**`main` has branch protection.** Pushing directly bypasses protections — always use PRs.

**Worktree gotcha:** Worktree branches track `origin/main` — pushing will push directly to `main`. Create a PR:
```bash
git push -u origin HEAD:feature/my-branch-name
gh pr create --base main
```

### Planning

For non-trivial features or fixes, write a plan in `doc/plans/`. Seek approval for destructive operations, ambiguous choices, or broad architectural changes.

**Skip planning for:** typo fixes, single-line changes, or tasks with very specific instructions.

### During Implementation

- Plan with the user before complex or risky operations.
- Test-first: write tests before implementation.
- Preserve existing user changes. Do not revert unrelated work.
- Match existing code style. Do not refactor adjacent code unless the task demands it.
- Update `assets/api/rest_v1.yml` or `assets/api/websocket_v1.yml` in the same commit as endpoint changes.
- Use `rg` (ripgrep) for targeted code search before opening large files: `rg -n "symbolName" lib/`. When `rg` is not installed, fall back to `grep -rn`. Use this for finding constants, command handlers, UI labels, and protocol definitions — one `rg` call replaces reading entire files.
- Use `rtk` (https://github.com/rtk-ai/rtk) for verbose test, build, and git output when already configured for the active client.

### Verification

After every meaningful code change:
1. Run `dart format lib test`.
2. Run relevant tests + `flutter analyze`. Fix immediately if anything fails.
3. Run full `flutter test` before committing and before claiming done.
4. Evidence before assertions — show test output, not just "tests pass."

For API/spec changes, smoke-test via `scripts/sb-dev.sh` + `curl`/`websocat`. See `.agents/skills/decent-app/verification.md`.

### Pre-Commit / Pre-PR Checklist

**Before opening a PR, merging locally, or considering work done:**
0. **Fill out the PR template** at `.github/pull_request_template.md` — sections marked required are hard gates. See `CONTRIBUTING.md`.
1. **Archive design docs** from `doc/plans/` to `doc/plans/archive/<meaningful-subfolder-name>/`. Design docs are worth keeping (the *why*). Implementation plans (step-by-step task lists) are not — delete them.
2. **Check doc updates:** `doc/Api.md` if endpoints changed, `doc/Skins.md` if skin behavior changed, `doc/Plugins.md` if events changed, `doc/Profiles.md` if profile handling changed, `doc/DeviceManagement.md` if device flows changed.

All three steps are required, not optional.

## Hard Rules

- Never import 3rd-party BLE libraries (e.g. `universal_ble`) outside `lib/src/services/ble/`.
- All BLE operations use 128-bit UUID format.
- Scale write paths must catch `DeviceNotConnectedException` at the lowest-level write helper.
- Keep Flutter build and run flows non-interactive. Prefer `--dart-define=simulate=1` for smoke tests.
- Use prefixed imports for domain models that share names with Drift-generated code: `import '...shot_record.dart' as domain;` or `hide Workflow` on the database import.
- No emojis in comments or documentation.

## Code Style

- Do not add explanatory comments to new or substantially rewritten code; use clear names and small functions. Preserve existing comments and required notices.
- Put cross-device rationale and debugging history in the matching
  `doc/AI_*_NOTES.md` file. Put device-specific hardware and firmware
  constraints in `doc/device-notes/`.
- Prefer immutability when practical.
- Constructor dependency injection — no service locators.
- Stream subscriptions always cancelled in `dispose()`.

## Vocabulary

Use existing project terminology. Match the naming in `doc/` and the AI_* files. Examples: "ConnectionManager phases" not "connection lifecycle states", "transport abstraction" not "BLE wrapper", "simulated devices" not "mock hardware mode".

If your output contradicts documented architecture or conventions, surface it explicitly rather than silently overriding.

## Tracking

GitHub Issues on `decentespresso/decaid` is the canonical issue tracker. Use `gh issue` commands for triage, labeling, and closing.

**Triage labels** (used on `decentespresso/decaid`):

| Label | Meaning |
|-------|---------|
| `needs-triage` | Maintainer needs to evaluate this issue |
| `needs-info` | Waiting on reporter for more information |
| `ready-for-agent` | Fully specified, ready for an AFK agent |
| `ready-for-human` | Requires human implementation |
| `wontfix` | Will not be actioned |

## Deep References

- Fast file routing: `doc/AI_REPO_MAP.md`.
- BLE footguns, transport threading, connection lifecycle: `doc/AI_BLE_NOTES.md`.
- Device-specific hardware, protocols, and firmware behavior: `doc/device-notes/`.
- Build, flash, simulate, platform quirks: `doc/AI_BUILD_NOTES.md`.
- REST/WS API contracts and compat: `doc/AI_API_NOTES.md`.
- Drift DB schema, migrations, SharedPreferences: `doc/AI_STORAGE_NOTES.md`.
- Debugging patterns and BLE errors: `doc/AI_DEBUG_NOTES.md`.
- Test tiers, widget patterns, mock helpers: `doc/AI_TESTING_NOTES.md`.
- Full project docs: `doc/Api.md`, `doc/Skins.md`, `doc/Plugins.md`, `doc/Profiles.md`, `doc/DeviceManagement.md`, `doc/RELEASE.md`.
- Contributing: `CONTRIBUTING.md`.
- Dev-loop skill: `.agents/skills/decent-app/SKILL.md`.
- API specs: `assets/api/rest_v1.yml`, `assets/api/websocket_v1.yml`.
- Archived design docs: `doc/plans/archive/` (the *why* behind shipped features).
- Knowledge graph: `code-review-graph` MCP tools. Use `rg` or direct file reads for exact names, paths, and one-hop lookups. Use the graph for multi-hop impact analysis, callers-of-callers, affected flows, architectural exploration, and test reachability.

## Naming Reference

| Layer | Value |
|-------|-------|
| User-facing name | **Decaid** |
| Dart package name | `reaprime` |
| Plugin file extension | `.reaplugin` |
| Bundle ID | `net.tadel.reaprime` |
| Database name | `streamline_bridge` |
| GitHub repo | `decentespresso/decaid` |

**Decaid** combines "decade" and "Decent aide." The name marks ten years since the original `de1app` repository's first commit on May 14, 2016. Preserve `Decent.app` and ReaPrime where they are historical or internal identifiers.

## Don't

- Don't push directly to `main`. Use PRs.
- Don't import BLE libraries outside the transport layer.
- Don't create new Drift tables without a schema version bump + migration.
- Don't add API endpoints without updating the OpenAPI/AsyncAPI spec in the same commit.
- Don't add new global state without a clear ownership boundary.
- Don't `--amend` or force-push on `main`.
- Don't create `CONTEXT.md` or `doc/adr/` — `AGENTS.md` + `doc/` are the equivalents.
