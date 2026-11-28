# Contributing to Decaid

Thanks for contributing. This guide tells you what's required to land a PR — items marked **(required)** are hard gates, not suggestions.

> **Naming note:** The display name is **Decaid**. The Dart package, bundle ID, database, and plugin extension retain legacy identifiers for compatibility. See the naming table in [`CLAUDE.md`](CLAUDE.md) before renaming anything.

## Quick Reference

| What | Where |
|------|-------|
| Architecture & conventions | [`CLAUDE.md`](CLAUDE.md) |
| PR template | [`.github/pull_request_template.md`](.github/pull_request_template.md) |
| Agent workflow: gates, risk levels, PR evidence | [`doc/AGENT_WORKFLOW.md`](doc/AGENT_WORKFLOW.md) |
| API specs (authoritative) | `assets/api/rest_v1.yml`, `assets/api/websocket_v1.yml` |
| API docs | [`doc/Api.md`](doc/Api.md) |
| Dev-loop scripts | `scripts/sb-dev.sh` (macOS/Linux) |
| CI checks | [`.github/workflows/pr-checks.yml`](.github/workflows/pr-checks.yml) |
| Agent guidance (Cursor, Copilot, etc.) | [`AGENTS.md`](AGENTS.md) |

## Before You Start

- **Open an issue before implementation.** External contributors must do this for every proposed PR, including small fixes. This lets maintainers consider scope, alternatives, compatibility, and whether the change belongs in Decaid before implementation work starts.
- **Wait for acceptance.** Start implementation only after a maintainer marks the issue `ready-for-agent` or `ready-for-human`.
- If a proposal needs broader design discussion, maintainers may move it to a GitHub Discussion or Project and later create or reopen concrete issues for implementation. A PR still needs an accepted implementation issue.
- Repository maintainers and automated repository-maintenance PRs may bypass the issue-first requirement when creating an issue would add no useful planning context.
- **Read [`CLAUDE.md`](CLAUDE.md)** — it covers architecture, conventions, test patterns, and gotchas. Agents and humans both need it.

## Local Setup

Requirements: the Flutter SDK pinned in `.github/workflows/pr-checks.yml` (restated in [README prerequisites](README.md#prerequisites) along with the Dart SDK constraint), the [GitHub CLI](https://cli.github.com) (`gh`, authenticated — used to fetch the DYE2 bundled plugin), `jq` (validates the fetched plugin's manifest).

```bash
flutter pub get
./scripts/fetch_dye2_plugin.sh   # installs assets/plugins/dye2.reaplugin/ from the latest decentespresso/dye2 release (DYE2_VERSION=vX.Y.Z pins one)

# Run with simulated hardware (no DE1 / scale required):
flutter run --dart-define=simulate=1
```

See [`CLAUDE.md`](CLAUDE.md) for the full command reference.

## Branching & PRs

- Branch from `main`. Push to your fork, open a PR against `decentespresso/decaid:main`.
- One feature or fix per PR. No bundling unrelated changes.
- External contributions must reference an **open, accepted issue** using `Fixes #123`, `Closes #123`, `Resolves #123`, or `Related #123`. The issue must carry either the `ready-for-agent` or `ready-for-human` label when the PR is opened.
- Do not finish an implementation first and then open an issue only to satisfy the PR gate. The issue-first process exists so the proposed change can be considered before code review becomes necessary.
- A maintainer will review. Expect a few rounds of feedback.
- **Do not push directly to `main`** — branch protection is active, and even with push access, direct pushes bypass reviews and CI.

## Guardrails (required)

These are hard gates. PRs that skip them will be returned.

### 1. Accepted Issue

For external contributions, the PR must reference at least one open issue in this repository that a maintainer has accepted with `ready-for-agent` or `ready-for-human`.

CI validates this before running the expensive test/build jobs. Repository maintainers and automated repository-maintenance PRs are exempt from this gate.

### 2. Tests

**New behavior needs a test.** Bug fixes need a regression test.

| Tier | Location | When required |
|------|----------|---------------|
| Unit | `test/` | New logic, models, handlers, DAOs |
| Integration | `test/` (mock transport edge) | Multi-component flows |
| End-to-end | `.agents/skills/decent-app/scenarios/` | API surface changes |

Web server handlers have a strong unit-test convention — see `test/services/webserver/de1handler_cup_warmer_test.dart` for the pattern.

### 3. Spec & Docs (required)

**Every API change must update the spec in the same PR.** The spec is authoritative — stale spec = stale agent knowledge.

| Change | Update this |
|--------|-------------|
| REST endpoint added/changed | `assets/api/rest_v1.yml` + `doc/Api.md` |
| WebSocket topic added/changed | `assets/api/websocket_v1.yml` + `doc/Api.md` |
| Plugin event/API changed | `doc/Plugins.md` |
| Skin behavior changed | `doc/Skins.md` |
| Profile handling changed | `doc/Profiles.md` |
| Device discovery/connection changed | `doc/DeviceManagement.md` |

### 4. Local Gates (required)

Run these before pushing. Same checks that CI runs:

```bash
flutter analyze                          # must be clean — no new warnings
flutter test                             # all must pass
./scripts/fetch_dye2_plugin.sh           # assets/plugins/dye2.reaplugin/ must exist
```

`dart format` is **enforced** in CI on the Dart files your PR changed, using the SDK pinned in `.github/workflows/pr-checks.yml`. Use the merge-base-plus-untracked Dart formatting command in [`AGENTS.md` → Verification, step 1](AGENTS.md#verification) so in-progress edits and committed branch changes are covered without reformatting untouched files. A local SDK that differs from the pinned one reflows code CI would leave alone, so check out the pinned version (see [README prerequisites](README.md#prerequisites)) instead of matching your local formatter.

### 5. Architecture Boundaries (required)

- **No 3rd-party BLE imports** outside `lib/src/services/ble/`. Wrap library-specific types at the transport boundary.
- **Constructor dependency injection** — no service locators.
- **Single Responsibility** — each controller/service has one job.
- See [`CLAUDE.md` → Conventions & Gotchas](CLAUDE.md) for the full list.

### 6. PR Template (required)

Fill out the PR template. Sections marked `(required)` must be completed. The template lives at [`.github/pull_request_template.md`](.github/pull_request_template.md).

## Verification Evidence (Phase 1 advisory pilot)

[`doc/AGENT_WORKFLOW.md`](doc/AGENT_WORKFLOW.md) is the canonical description of the gates, risk levels, and evidence handoff that the PR template's newest fields ask for. It applies to humans and agents alike.

- State the highest affected-behavior risk level (L0–L3) and why, map each acceptance criterion to a test or observed behavior, and record the exact verified commit SHA, environment, linked artifacts, and known gaps.
- Captures demonstrate a **journey** for user-visible L2/L3 changes — including the intermediate progress and error states the claim depends on — not a single final screenshot. L0/L1 and non-visual changes need no screenshot or recording; API and WebSocket changes are better shown by request/response or stream traces.
- Label results as simulated, physical, or not exercised. Simulated devices and desktop runs do not prove physical-device behavior, and untested areas must be declared rather than omitted.
- Evidence must not contain secrets, credentials, user data, production logs, or protected recordings; link durable, access-controlled artifacts instead of committing captures.

These supplemental fields are advisory during Phase 1, and a PR is still reviewable with declared gaps. The accepted-issue policy, test and spec requirements, local gates, and the Contributor Responsibility acknowledgement remain required exactly as written above. Narrow CI enforcement, if any, is a Phase 3 (#1205) question.

## Code Style

- `dart format` is the source of truth. Format your changes.
- `flutter analyze` must be clean. Don't merge with new warnings.
- Follow existing patterns in the file you're editing — don't introduce a different style.
- Commits: Conventional Commits (`feat:`, `fix:`, `chore:`, `docs:`, `refactor:`, `test:`). Subject ≤72 chars. Explain the *why* in the body.

## Commit Messages

```
feat: add cup warmer temperature control endpoint

Added GET/PUT /api/v1/de1/cup_warmer with temperature range
validation (0–80°C). Updates rest_v1.yml spec and Api.md.
```

## AI-Assisted Contributions

AI-assisted development is allowed. Contributors may use tools such as Claude, Codex, ChatGPT, GitHub Copilot, or other coding agents and language models.

AI assistance does not transfer responsibility for a contribution. By submitting a PR, you acknowledge that:

- you have reviewed and understand the changes you are submitting, including AI-assisted or AI-generated changes;
- you take responsibility for their correctness, security, behavior, licensing, and provenance; and
- you are able to explain and maintain the submitted changes through review.

Do not submit generated changes that you have not personally reviewed and validated.

## License & Sign-Off

By submitting a PR you agree your contribution is licensed under the same terms as the repository and that you have the right to contribute it. No CLA required.

## Questions

Open an issue or start a discussion. For agent-specific guidance, see [`AGENTS.md`](AGENTS.md) and [`CLAUDE.md`](CLAUDE.md).
