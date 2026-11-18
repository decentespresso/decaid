# Decaid Agent Workflow

How Decaid work is specified, implemented, verified, independently reviewed, and prepared for
integration. The purpose is to make a PR's correctness *inspectable* from the PR itself, instead of
relying on a summary that costs a maintainer another manual reproduction.

**Status: Phase 1 advisory pilot.** This document adds no CI requirement, changes no GitHub
protection, and authorizes no agent to approve or merge anything. Its supplemental PR-template
fields are advisory while piloted; every existing hard gate stays required. Phase 2 (#1204) adds
independent-review execution, Phase 3 (#1205) considers enforcement.

## Authority and existing rules

- [`AGENTS.md`](../AGENTS.md) is authoritative for code, architecture, local verification, tests,
  plans, branch safety, and physical-device access.
- [`CONTRIBUTING.md`](../CONTRIBUTING.md) and
  [`.github/pull_request_template.md`](../.github/pull_request_template.md) remain authoritative for
  contributor acceptance and PR submission. External contributions still need an accepted open issue
  and the Contributor Responsibility acknowledgement.
- [`doc/AI_TESTING_NOTES.md`](AI_TESTING_NOTES.md) defines test tiers and helpers.
  [`decent-dev`](../.agents/skills/decent-dev/SKILL.md) is the local development loop;
  [`decent-app` verification](../.agents/skills/decent-app/verification.md) covers running-app
  REST/WebSocket procedures.
- Where documents appear to conflict, do not silently take the easier requirement. Follow the
  existing hard gate and flag the discrepancy for maintainers.
- Agents cannot decide product, UX, or security risk. Human review and merge authorization remain
  necessary under repository policy.

## 1. Work and handoff gates

Five gates in order. They describe the **state of evidence**, not a new label scheme: the existing
triage labels (`needs-triage`, `needs-info`, `needs-refinement`, `ready-for-agent`,
`ready-for-human`, `wontfix`) stay as they are.

### G1 — Specified

- **Owner:** maintainer refining the issue.
- **Entry:** a problem or proposal exists; an umbrella/tracker issue may exist.
- **Exit:** an accepted issue carries `ready-for-agent` or `ready-for-human` and states the user
  problem, affected behavior, scope, compatibility and constraints, observable acceptance criteria,
  and a proposed risk level with verification scenarios. A tracker issue is not by itself an
  implementation issue.
- **Non-goals:** no implementation, no code design review, no evidence gathering, no approval to
  merge anything.

### G2 — Implemented

- **Owner:** implementing agent or contributor.
- **Entry:** accepted implementation issue.
- **Exit:** code, tests, and any required spec/doc updates are complete; the
  [`AGENTS.md` verification gate](../AGENTS.md#verification) is green; the change is self-reviewed
  against issue scope and relevant architecture; a PR references the accepted issue and starts
  filling the evidence handoff.
- **Non-goals:** claiming end-user behavior from unit tests alone, expanding scope beyond the
  accepted issue, declaring the change correct or low-risk.

### G3 — Agent verified

- **Owner:** implementing agent or contributor.
- **Entry:** PR with implementation and focused tests.
- **Exit:** acceptance matrix filled, exact verified head SHA recorded, commands and results quoted,
  environment labeled simulated or physical, artifacts linked, negative paths exercised where the
  risk warrants, and every untested area declared.
- **Non-goals:** approving its own work, judging product risk, substituting prose for output,
  waiving existing hard gates.

### G4 — Independently reviewed

- **Owner:** reviewer who did not implement the change.
- **Entry:** evidence complete enough to inspect, recorded against a SHA.
- **Exit:** reviewed SHA recorded; each acceptance criterion graded verified, weak, or not tested;
  blocking findings carry impact, file/line, and a reproduction or failure mode; regression and
  compatibility concerns are raised; recommendation is **approve**, **request changes**, or **needs
  human validation**.
- **Non-goals:** reimplementing the change, replacing reading with a full local test run, approving
  on a maintainer's behalf, merging.

### G5 — Integration/merge ready

- **Owner:** integration reviewer plus the maintainer who authorizes the merge.
- **Entry:** no unresolved G4 blockers; CI green at the current head; dependencies and merge order
  identified.
- **Exit:** combined-candidate behavior checked where risk warrants, shared-contract and migration
  impact recorded, unverified or waived risks listed explicitly, maintainer authorization recorded.
- **Non-goals:** bypassing branch protection, bot-approved merges, treating green CI as product
  acceptance, silently absorbing another PR's untested changes.

During the Phase 1 pilot, G4 and G5 are documented expectations, not automated checks. A draft PR may
have labeled evidence gaps; mark a PR ready for review only when its available evidence is
inspectable.

## 2. Risk levels and required proof

Classify by **affected behavior**, taking the highest level that applies, including indirect effects
and dependencies. A three-line patch can be L3. Record one or two sentences explaining the level.

| Level | Examples | Minimum evidence beyond existing hard gates |
| --- | --- | --- |
| **L0 — Nonbehavioral** | Documentation, comments, copy or typo edits with no logic change | Diff inspected, links and applicable checks run. No screenshot or recording required unless text placement is the subject. |
| **L1 — Isolated logic** | Parser, calculation, model, contained bug fix | Focused tests, with a regression case for bug fixes; state inputs, expected versus actual, and relevant edges. Existing changed-file formatting, analysis, and full-suite requirements still apply. |
| **L2 — User-visible or system behavior** | Skins, UI, onboarding, settings, API workflow, multi-component flow | L1 evidence plus a running-app or API scenario: starting conditions, steps, observed results, and the negative/error path. For *visual* behavior, captures must demonstrate the journey including intermediate progress and error states; for API-only behavior, request/response or stream traces are the appropriate artifact. |
| **L3 — Critical or integration-sensitive** | Authentication/authorization, updates and installers, machine control, BLE/device lifecycle, persisted data and migrations, high-impact compatibility | L2-caliber behavioral evidence where applicable, plus security, failure, rollback and compatibility checks, explicit independent review and integration assessment, and a human/hardware/platform validation plan where simulation cannot establish correctness. Many L3 changes are not visual, so recordings are conditional on the feature. |

**Escalate** when the PR crosses subsystem boundaries, touches shared state or public contracts,
changes a security assumption, or raises a backward-compatibility question. Escalating means
recording the higher level and adding the evidence it implies; it is not a request for permission to
skip evidence.

A maintainer may waive one *specific supplemental evidence item* with an explicit rationale and
residual risk, recorded in the PR. Nobody may use this document to waive an existing hard gate.

### Simulated, physical, and not tested

- Label every result **simulated**, **physical**, or **not exercised**, with OS, platform, app build
  or commit, and meaningful setup flags. Simulate mode (`simulate=1`, simulated devices) is not
  evidence of real hardware behavior.
- A desktop or widget test does not validate Android permissions, APK installation, or iOS OS-prompt
  behavior. Name the platform you did not exercise.
- Never connect to, control, flash, or write to a physical machine without explicit operator
  authorization; state which device was used. A capture of a simulated state must never be presented
  as a physical-device test.
- If an environment is unavailable, say what was tested and put the missing verification in the PR
  for a maintainer to plan or accept.

## 3. PR evidence handoff

The PR body is the **index** to evidence, not a log dump. Use the sections in
[`.github/pull_request_template.md`](../.github/pull_request_template.md) and keep them short; link
long output instead of pasting it.

Required handoff content:

1. **Scope and risk** — linked issue, one-line summary, L0–L3 level with rationale.
2. **Acceptance matrix** — one row per issue criterion; an assertion without an observed or automated
   result is not verified.
3. **Verification fingerprint** — exact commit SHA tested (not a branch name), OS/platform,
   simulated versus physical, build flags, and whether the evidence covers all target platforms.
4. **Checks** — exact commands and results, plus run links; separate pre-existing baseline failures
   from newly introduced ones.
5. **Behavioral evidence** — precondition, action, observed result, including progress, error, and
   rollback states where relevant. For visual behavior the artifacts must show the intermediate
   states the claim depends on; a single final screenshot is usually not enough.
6. **Known gaps** — unexercised areas, environmental limits, unverified assumptions, suspected
   regressions, and specific requests for human or hardware validation.
7. **Impact** — security, compatibility, public API/spec, migration, documentation, deployment.

### Acceptance matrix

Copy this table into the PR body (the template already contains it) and fill every row:

```markdown
| Issue acceptance criterion | Status (verified / not tested / blocked) | Test, scenario or artifact |
| --- | --- | --- |
| <criterion, from the issue> | verified | `flutter test test/path/to_test.dart` — 3 passed; or scenario + artifact link |
| <criterion, from the issue> | not tested | needs physical Android run; logged for maintainer |
```

Rules that keep the matrix honest:

- `verified` requires the result, not the intention. Quote the command and its outcome, or link the
  capture that shows it.
- Missing evidence is never silently passing: use `not tested` or `blocked` and say what is needed.
- A maintainer may accept residual risk in writing and record it on the row; an agent may not.

### Verified SHA and stale evidence

Record the **exact head SHA** the evidence applies to. When the PR changes:

- Re-run the checks and scenarios the new commits affect and record the new SHA.
- If reused evidence is still valid, scope it explicitly to the unaffected code path and say so.
- Never reuse an old timestamp or SHA to imply tests ran against the new head.

## 4. Reviewer and re-review handoff

An independent reviewer starts from the accepted issue, the relevant code and architecture, and the
test contract, then inspects the changed behavior and its proof — not the implementing agent's
summary. Report:

- PR and **reviewed head SHA**; risk level and whether it should be escalated.
- Which criteria are verified, which have weak evidence, which remain not tested.
- Blocking findings with impact and file/line plus a concrete reproduction or failure mode;
  nonblocking suggestions kept separate.
- Cross-feature regression and compatibility concerns, required human/device checks, dependencies.
- One recommendation: approve, request changes, or needs human validation.

After a new push, compare the reviewed SHA with the new head, inspect the delta, and confirm prior
findings are closed. Re-review unchanged code only when new evidence or nearby changes invalidate the
earlier assumptions. An earlier approval never covers a newer head. Phase 2 (#1204) formalizes the
review procedure and pilots it.

## 5. Integration and merge readiness

For related PRs, assess merge order, changed shared interfaces, simultaneous assumptions,
migrations, feature flags, and how earlier merges affect later evidence. For integration-sensitive
work, exercise the combined candidate in a disposable branch or worktree and record the combined
commit(s) and scenarios. Check CI and review-thread status, then present a hold or merge
recommendation. Do not merge, bypass protection, or use physical hardware without explicit
authorization. Phase 3 (#1205) formalizes this and evaluates narrowly scoped, non-brittle CI checks.

## 6. Artifact privacy and retention

- Never publish secrets, credentials, tokens, personal or customer data, production logs, or
  protected recordings. Redact or replace anything sensitive before uploading, and never commit
  recordings or raw dumps into a public repository.
- Do not attach artifacts from private or protected sources without the owner's clearance; link them
  with appropriate access instead.
- Use durable, reviewer-accessible locations with retention that outlives the review. CI artifacts
  expire; if the proof would expire, keep a short sanitized summary and the key numbers in the PR
  body.
- Describe what a capture demonstrates — platform, scenario, trigger, and the claim it supports — so
  a reviewer can judge it without guessing.
- Do not manufacture, stage, or embellish evidence. If a capture is unavailable, mark the criterion
  not tested or supply a different valid proof.

## 7. Worked examples

### L3: skin or app update journey

Issue criterion: a user who taps an update notification reaches the updater, sees download progress,
and can tell success from failure.

| Criterion | Evidence the PR should reference |
| --- | --- |
| Notification appears when an update is available | Automated assertion, or a running-app capture with version/build and setup shown |
| The notification leads to the correct updater flow | Short recording or ordered before/after captures showing the actual navigation |
| Download progress updates without hiding errors | Recording or ordered captures of an intermediate progress state, plus the regression assertions |
| Success and failure behave correctly | Positive path plus an induced failure, or an explicit `not tested` limitation |
| Android install-permission flow succeeds | Authorized physical Android run with platform details; a simulated desktop flow does not prove it |

Also declare what is not covered — iOS, fresh install, interrupted network, physical device — and
why. Link artifacts with no credentials or production data.

### L0: documentation-only correction

Issue criterion: a documented command or term is accurate. Evidence is the diff, a link or command
check, and the applicable CI results. Enter `N/A - nonvisual` for captures. No screen recording is
required, and demanding one would be busywork.

## 8. Pilot and evolution

Phase 1 introduces this policy and the expanded PR handoff as an **advisory** requirement, and the
updated template must be used on the Phase 1 PR **and at least one subsequent runtime-visible PR**
before the process is declared stable. Phase 2 (#1204) pilots independent review on L1–L3 PRs and
records maintainer effort and missed findings. Phase 3 (#1205) adds the integration procedure and
evaluates mechanically checkable, non-brittle rules. Evidence self-reporting never becomes an
automatic correctness or approval verdict.

Success means fewer maintainer minutes and fewer repeat review rounds per merged PR without more
post-merge regressions. Track exceptions; if a required evidence item turns into busywork that does
not change decisions, tighten the requirement.

Parent tracker: #1202. Phase 1 issue: #1203.
