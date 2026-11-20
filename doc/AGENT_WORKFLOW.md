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
- **Exit:** reviewed SHA recorded; each acceptance criterion graded verified, weak, not tested, or
  blocked; blocking findings carry impact, file/line, and a reproduction or failure mode; regression
  and compatibility concerns are raised; verdict is **approve recommendation**, **changes
  required**, or **needs human validation**.
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

### Decision status vocabulary

Use these exact lower-case status terms in Layer 1 and Layer 2. They describe evidence or a
recommendation; they never authorize a merge.

- **ready** — the available evidence supports the stated recommendation; maintainer authorization is still pending.
- **hold** — a blocker, unresolved review, dependency, conflict, or missing required evidence prevents the recommendation.
- **needs human validation** — an authorized maintainer, platform, security, or hardware decision or observation is required.
- **not tested** — the named check or scenario was not run or observed.
- **failed** — the named check or scenario ran and did not meet its expected result.
- **unknown** — the source does not establish the fact, or the evidence cannot be accessed.

Use **ready for review** for an inspectable G3 handoff, or **blocked** when a known blocker prevents
review. Use G4's verdict terms **approve recommendation**, **changes required**, and **needs human
validation**; state the corresponding `ready`, `hold`, or `needs human validation` status in the
decision brief. `green` CI and GitHub mergeability are
facts to report, not authorization or proof of semantic compatibility.

### Shared report-writing contract

This contract applies to every G3 handoff, G4 first or delta review, and G5 batch report. Write
Layer 1 first in plain, active technical English. Keep it to about 150 words or fewer, with at most
three primary blockers and one prioritized named actor and action. Use this order: decision and
recommendation authority, why, next action, confidence and critical limits, then a durable details
link. Keep risk-critical security, hardware, privacy, rollback and compatibility limits visible even
when they require an exception. Use explicit conditions and consistent status terms. Preserve exact
engineering terminology, diagnostics, SHA values, API paths and negative paths. This style is
inspired by ASD-STE100; it is not formal compliance. Do not use filler, empty headings, repeated
summaries or unsupported timing claims. A compact per-PR queue may add actions after the one global
next action; it must not obscure the first decision.

The approximately 150-word Layer 1 budget includes the compact ranked view or queue; Layer 2 is
unlimited. Layer 2 retains complete proof and is not shortened by the Layer 1 limit. Link raw logs
rather than duplicating them, but retain exact collection/start/finish facts, sources, fingerprints,
checks and results, exit codes, failures, negative and rollback paths, environment, waivers,
unmeasured metrics and runnable follow-up commands where applicable.

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
long output instead of pasting it. Write Layer 1 first. Keep complete proof in Layer 2 below the
brief, in a durable comment, or in a linked artifact.

### Canonical G3 handoff template

Use this one template for every G3 handoff. Apply the shared report-writing contract above. A
risk-critical security, hardware, privacy, or rollback limit stays visible even when this makes the
brief longer.

```markdown
## G3 decision brief — <PR / change>
- **Decision:** **<ready for review / blocked>** — recommendation only; not approval or merge authorization.
- **Why:** <up to three highest-impact confirmed failures, missing proof, or important uncertainty; label each status>
- **Next action:** <one named actor> — <one concrete action>
- **Confidence / limits:** reviewed/tested SHA(s); OS/platform and simulated or physical environment; current-head CI; critical `not tested`, `failed`, `unknown`, security, or hardware limits.
- **Details:** <durable link to Layer 2 evidence, acceptance matrix, commands, artifacts and exact CI/SHA links>

### G3 technical evidence
- Scope and risk: <linked issue; L0–L3 and rationale>
- Acceptance matrix: <one row per criterion; use `verified`, `not tested`, or `blocked` with observed proof or gap>
- Verification fingerprint: <exact tested SHA, OS/platform, flags, simulated/physical status, target-platform coverage>
- Checks: <exact commands, results, exit codes and links; separate baseline failures>
- Behavioral evidence: <precondition, action, observed result, progress/error/rollback paths where relevant>
- Known gaps: <untested areas, environmental limits, assumptions, regressions, human/hardware requests>
- Impact: <security, compatibility, API/spec, migration, documentation and deployment>
```

Layer 2 retains every acceptance row, exact SHA, command/result, CI state, environment, negative
path, artifact, waiver, and untested area needed for independent reproduction. `ready for review`
describes a handoff state, not product acceptance.

### Acceptance matrix

Copy this table into the PR body (the template already contains it) and fill every row:

```markdown
| Issue acceptance criterion | Status (verified / not tested / blocked) | Test, scenario or artifact |
| --- | --- | --- |
| <criterion, from the issue> | verified | `flutter test test/path/to_test.dart` — 3 passed; or scenario + artifact link |
| <criterion, from the issue> | not tested | needs physical Android run; logged for maintainer |
```

Rules that keep the matrix honest:

- `verified` requires an observed result, not intention. Quote the command/result or link the capture.
- Missing evidence is never silently passing: use `not tested` or `blocked` and name what is needed.
- A maintainer may accept residual risk in writing and record it on the row; an agent may not.

### Verified SHA and stale evidence

Record the **exact head SHA** the evidence applies to. When the PR changes:

- Re-run checks and scenarios affected by the new commits and record the new SHA.
- Scope reused evidence to an unaffected path; never reuse an old timestamp or SHA as new proof.

## 4. Reviewer and re-review handoff

An independent reviewer starts from the accepted issue, the relevant code and architecture, and the
test contract, then inspects the changed behavior and its proof — not the implementing agent's
summary. The **requirements** for the review are the reviewed head SHA, risk and criteria assessment,
blocking findings, regression/compatibility concerns, human or device validation gaps, dependencies,
and one G4 verdict. Use the canonical template below; `decent-review` supplies the procedure and
points here rather than repeating a report template. The author-facing PR evidence matrix in section
3 is distinct from this independent reviewer assessment.

After a new push, compare the reviewed SHA with the new head, inspect the delta, and confirm prior
findings are closed. Re-review unchanged code only when new evidence or nearby changes invalidate the
earlier assumptions. An earlier approval never covers a newer head. The
[`decent-review` skill](../.agents/skills/decent-review/SKILL.md) gives the operational first-review,
delta-review, reporting and pilot procedures for Phase 2 (#1204). Its reviewer recommendations do
not constitute maintainer product acceptance or an automatic merge gate.

### Canonical G4 first/delta review template

Use this one variant-aware template for both a first review and a post-push delta review. Apply the
shared report-writing contract above. A delta must state the old reviewed SHA and new head in Layer 1,
which prior findings closed or remain, what evidence is reused and why, and current-head CI. A first
review must state its exact reviewed SHA and distinguish unknown CI or unavailable fixed-head proof.

```markdown
## G4 <first review / delta review> — PR #<number>
- **Decision:** **<ready / hold / needs human validation>** — **<approve recommendation / changes required / needs human validation>**; recommendation only, never merge authorization.
- **Why:** <up to three highest-impact findings; distinguish `failed`, `not tested`, `unknown`, confirmed resolution, and nonblocking gaps>
- **Next action:** <one named actor> — <one concrete action>
- **Confidence / limits:** <first: reviewed SHA; delta: old reviewed SHA -> new head>; tested evidence SHA(s); current-head CI; environment; critical negative-path, security, hardware, or platform limits.
- **Details:** <durable link to Layer 2 criterion matrix, findings, commands, artifacts, CI and SHA links>

### G4 technical evidence
- Review variant and fingerprint: <first reviewed SHA, or old reviewed SHA -> new head; base and current-head CI>
- Issue/scope, dependencies and L0–L3 risk rationale
- Prior findings: <first: none; delta: each closed or remaining finding and proof>
- Reused evidence: <exact unaffected path, source SHA and reason; never imply new execution>
- Acceptance matrix: <criterion | `verified`, `weak`, `not tested`, or `blocked` | expected behavior, exact proof/SHA, or gap>
- Blocking findings: <severity, file/line, impact, cause, reproduction/failure mode, or none>
- Nonblocking findings and remaining validation: <exact human/platform/hardware action, or none>
- Integration concerns and compatibility/regression assessment
- Independent execution: <reviewer commands/results, separated from author evidence>
- Verdict: **approve recommendation**, **changes required**, or **needs human validation**
```

Layer 2 retains the full criterion matrix, exact reviewed/tested SHA distinction, current-head CI,
negative paths, file/line findings, reproduction, hardware/security limits, independent execution,
and unresolved or resolved findings. After a push, compare old reviewed SHA to new head and write a
delta brief; do not copy an earlier verdict unchanged. An earlier approval never covers a newer head.
The reviewer's recommendation is not product acceptance or an automatic merge gate.

## 5. Integration and merge readiness

Use [`decent-integration`](../.agents/skills/decent-integration/SKILL.md) for the operational G5
procedure: collect live metadata for named PRs, inspect actual diffs and shared contracts, build a
directed dependency/order plan, exercise a disposable local combination where feasible, and refresh
the analysis as `main` advances. This section remains authoritative for the **single merge-batch
report template**. G4 review and current-head CI remain prerequisites, not substitutes for combined
behavioral evidence. GitHub mergeability does not establish semantic compatibility.

Record author-tested, reviewer-reviewed and combined integration SHAs separately. For L3 or
overlapping changes, attempt isolated combined verification; if execution is unavailable or conflicts
block assembly, label it **not tested**, give the concrete blocker and exact runnable follow-up
commands. Simulation does not prove physical-machine behavior. No unattended merge, protection
bypass, contributor-branch rewrite, push or physical-device operation is authorized by this process.
Maintainers retain merge authorization. Phase 3 Deliverable A is advisory; evidence-field validation
and ruleset recommendations belong to separate Deliverables B/C of #1205.

### Merge-batch report

```markdown
## G5 decision brief — <batch / PR numbers>
- **Decision:** **<ready / hold / needs human validation>** — recommendation only; never merge authorization. If none can proceed, say `0 of <N> ready`.
- **Why:** <up to three ranked blockers; name conflict, G4/evidence, dependency, failed check, or unknown explicitly>
- **Next action:** <one named actor> — <one concrete first action, prioritizing the first dependency/blocker>
- **Confidence / limits:** current main and current-head CI; author-tested, reviewer-reviewed, and combined SHAs; critical `not tested`, `failed`, `unknown`, security, hardware, or platform limits.
- **Details:** <durable link to Layer 2 merge-batch evidence and exact source, CI, SHA and artifact links>

### Ranked per-PR view
| Rank | PR | Status | Single reason | Next action |
| --- | --- | --- | --- | --- |
| <1..N> | <PR / head SHA> | <ready / hold / needs human validation> | <one confirmed reason or unknown> | <queued actor/action; global first action remains above> |

### G5 technical evidence
- Collected at, analysis start/finish, repository, current main and previous analysis main
- Environment/tools and live sources: metadata, complete diffs, issues/comments, CI, reviews/threads, artifact links; identify inaccessible sources

| PR / head SHA / base SHA / merge-base SHA | Risk and rationale | G4, current-head CI and unresolved findings | Author-tested / reviewer-reviewed SHAs; scoped older evidence | Prerequisite / blocked-on | Suggested sequence and rationale | Recommendation: ready / hold / needs human validation; exact reason |
| --- | --- | --- | --- | --- | --- | --- |
| <PR fingerprint> | <L0–L3> | <status and links; unknowns> | <distinct author/reviewer/combined SHAs, or unknown; combined SHA/tree separately> | <explicit/inferred edges and mechanism> | <order or undecided> | <recommendation, not authorization> |

- Dependency graph: <directed edges, mechanism evidence, uncertain edges/cycles and required decisions>; shared-file overlap is not dependency proof
- Shared contracts / overlaps: <files and semantic risks; API/schema/client, auth, plugin/skin updates, BLE/machine, persistence/migrations, onboarding; textual conflicts separately>
- Checks per PR and combined: <preconditions, exact commands/scenarios, expected and actual results, exit codes, negative/error/rollback paths, evidence links; not-tested labels>
- Disposable combination: <path/branch, pinned inputs and order, intermediate/final commit and tree SHAs, clean/conflicted state; or concrete blocker plus exact runnable commands>
- Human/platform/hardware validation: <owner/action, simulator limitations, residual risks; authorization pending or recorded>
- Changes since earlier verification: <landed changes and impacted contracts/tests; invalidated versus explicitly reused evidence>
- Refresh after each merge: <fetch/pin new main, re-query remaining heads/CI/threads, rebuild graph and combination, rerun affected checks and delta review; superseded report link>
- Exceptions/waivers: <specific item, authorized maintainer, rationale and residual risk, or none; no hard-gate waivers>
- Maintainer merge authorization: <pending or actual recorded authorization; never inferred from this recommendation>
- Pilot retrospective: <reviewer burden, maintainer follow-up minutes, extra rounds, missing-proof returns, false positives, observed post-merge regressions and follow-up window; not measured where unavailable>
- Deferred gates: <what remains advisory and what further evidence/approval is needed; no CI/ruleset change under Deliverable A>
```

The Layer 1 brief is the default reading path. The candidate table, graph, conflicts, fingerprints,
receipts, negative paths, waivers and retrospective remain in Layer 2 for independent verification.
Shared-file overlap is evidence, not an automatic blocker. GitHub mergeability and green CI never
replace G4, combined evidence, human validation, or maintainer authorization.

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

See [`doc/AGENT_REPORT_EXAMPLES.md`](AGENT_REPORT_EXAMPLES.md) for source-backed historical G3/G4/G5
before/after examples and the comprehension exercise record. Those examples illustrate the canonical
formats; they are not additional templates or authority.

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
