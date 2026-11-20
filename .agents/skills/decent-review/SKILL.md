---
name: decent-review
description: Independently review Decaid pull requests for requirement fit, implementation correctness, risk and verification evidence; use for initial reviews, post-push delta reviews, and deciding whether a change needs human or hardware validation.
---

# Decaid independent PR review

Review the **actual change and its proof**, not the implementing agent's narrative. The goal is a decision-ready, concise handoff that reduces maintainer reproduction work without accepting unverified behavior.

This skill implements G4 (independent review) of [Decaid Agent Workflow](../../../doc/AGENT_WORKFLOW.md), currently in an advisory pilot (#1204). The workflow document is canonical for risk levels, verification requirements, authority, safety and evidence retention. `AGENTS.md` remains canonical for engineering rules and device access. Do not weaken either.

## When to use

- Reviewing a new PR, a PR that has been updated after feedback, or an implementation presented as ready.
- Checking a PR against its linked issue, including whether regression tests and screenshots/recordings genuinely substantiate the claimed behavior.
- Preparing a reviewed-SHA handoff for a maintainer or integration reviewer.

For writing/fixing code, use `decent-dev`. For running-app REST/WebSocket checks, use `decent-app`. For multi-PR merge sequencing and combined verification, follow [`decent-integration`](../decent-integration/SKILL.md) and the canonical G5 report in `doc/AGENT_WORKFLOW.md`.

## Independent reviewer rules

1. **Be independent:** the implementing agent must not be its sole reviewer. If you are the implementer, disclose that and request an independent review.
2. **Use GitHub as source of truth:** get the current base/head SHA, issue, diff, reviews, unresolved threads and CI before conclusions. Conversation claims and PR prose are hypotheses.
3. **Record an exact SHA:** a verdict applies to the reviewed head only. Distinguish the SHA in the PR's test evidence from the head you actually reviewed.
4. **Do not invent proof:** if a test, hardware run, screenshot, recording or artifact cannot be accessed or performed, mark the relevant criterion weak/not tested and explain the effect.
5. **Keep authority separate:** a recommendation is not product acceptance or merge authorization. Do not merge, bypass protections, operate physical devices, or publish a formal approval on the maintainer's behalf. If explicitly authorized to post a GitHub review, publish the grounded findings and use the requested review action; never self-approve.
6. **Be proportional:** no video for purely nonvisual L0/L1 changes. For UI journeys require relevant intermediate states; for REST/WS changes prefer traces against the actual contract. Simulators do not prove real-hardware behavior.
7. **Protect evidence:** do not publish customer data, tokens, proprietary recordings, secrets or production logs in a public PR. Report private evidence as unavailable when you lack safe authorized access.

## First review procedure

### 1. Establish the review fingerprint

- Fetch PR metadata, base/head refs, changed files and complete diff; record **head SHA** and current merge base.
- Read the linked issue **body and relevant comments**, including acceptance criteria, approved scope, parent/dependencies, and the issue's accepted state. Maintainer/internal maintenance exceptions are described in `CONTRIBUTING.md`.
- Read any earlier reviews, outstanding inline threads and subsequent commits. Confirm current CI on the head: **passing, failing, pending or missing**; a green run for an earlier head is stale.
- Read targeted architecture/test references: `doc/AI_REPO_MAP.md` for unfamiliar areas, `doc/AI_TESTING_NOTES.md`, and subsystem-specific notes/specifications. Use targeted code search instead of indiscriminately reading the repository.
- If the issue is absent, broad, or contradictory, flag the specification gap rather than choosing the implementation's behavior as the requirement.

### 2. Challenge the risk tier and acceptance claims

Classify by **highest affected behavior** using `doc/AGENT_WORKFLOW.md`, not line count or the author's suggested tier. Treat changed authentication, updater/install, BLE/machine control, device lifecycle, persistence migration and major compatibility as potentially L3.

Construct a criterion-by-criterion map using the canonical G4 assessment in [`doc/AGENT_WORKFLOW.md` section 4](../../../doc/AGENT_WORKFLOW.md#canonical-g4-firstdelta-review-template). Independently establish the expected observable behavior from the issue before assessing the proof; include that expectation in the evidence/gap cell when it matters.

| Issue acceptance criterion | Reviewer status | Evidence inspected / remaining gap |
| --- | --- | --- |
| Actual criterion from issue | verified / weak / not tested / blocked | Expected behavior; exact test, scenario, artifact and verified SHA, or the missing proof |

The author's **PR evidence matrix** in `.github/pull_request_template.md` allows `verified / not tested / blocked`. The independent review adds `weak` for *partial or indirect evidence that does not justify the author's verified claim*; this is a reviewer assessment, not a request to change the PR template. `verified` requires credible inspected evidence within its stated environment; `not tested` means no usable verification; `blocked` means a known failure or unresolved blocker. Do not silently relabel a limitation as verified.

### 3. Inspect implementation and regression surfaces

- Trace input -> validation -> state transition -> side effects -> output, including cancellation, failure, reconnection, concurrent requests, disposal and retry where applicable.
- Check that the change actually addresses the reported user scenario, not only the added tests. Look for newly unhandled paths and conflicting assumptions with existing callers, persisted state, API/spec, plugin/skin contracts and other PRs.
- For bug fixes, ask whether a regression test **fails on the buggy behavior** and passes after the fix. Do not mistake mock assertions for end-to-end proof.
- For security/auth changes, inspect identity boundaries, permission origin, token exposure, denial paths and backwards compatibility. For machine/BLE changes, inspect safety, lifecycle, transport boundaries and stale callbacks. For storage changes, inspect old-schema migration and data preservation.
- Read relevant unchanged code as needed for confidence; state the limits of any shallow review.

### 4. Validate the claimed evidence

- Cross-check test names/results and CI links against the exact tested SHA. Note tests that did **not** run, skipped checks, platform-specific baseline failures and unstated environment assumptions.
- For L2/L3 runtime behavior: inspect preconditions, user or API actions, intermediate progress, success/error paths, and observed outcome. Check screenshots/recordings actually show the claim, with platform/build and simulator-vs-physical context.
- For physical-device and OS-specific claims, distinguish actual authorized runs from simulation and platform-independent tests. A desktop run cannot validate an Android permission prompt.
- Before running local tests or reporting a baseline failure, check `AGENTS.md` → **Worktrees and local verification**: fresh worktrees lack untracked bundled skins/plugins, and copied plugin bundles may be stale. Restore the documented local build inputs and distinguish workspace setup failures from PR regressions. Report any baseline failures with the exact comparison environment and commit; do not waive genuine failures simply because they also occurred in a stale checkout.
- Run focused tests, static checks or running-app smoke tests **only when tools and safe environments are available**; record commands/results. A review can be useful without rerunning the entire suite, but must say exactly what it did and did not independently execute.
- Where the proof is insufficient, describe the minimum specific additional test/artifact needed. Do not request a blanket full-screen recording if a targeted deterministic test or API trace would suffice.

### 5. Record findings and a decision-ready verdict

Prioritize correctness, safety, data loss and regression risk. For each blocking finding give severity
(`P0`/`P1`/`P2`), precise file and line where possible, cause, consequence, and a reproduction or
failure mode. Separate confirmed problems from risks needing validation; keep style observations
nonblocking.

Use the **canonical G4 template in `doc/AGENT_WORKFLOW.md` section 4**. Write its Layer 1 decision
brief first: recommendation status, up to three primary blockers, one named actor/action, exact
reviewed/tested SHA and current-head CI, critical limits, and a durable Layer 2 link. Keep the full
criterion matrix, `verified`/`weak`/`not tested`/`blocked` assessment, findings, negative paths,
independent commands, hardware/security limits and resolved/remaining evidence in Layer 2. Do not
create a competing report template in this skill.

A report with an approve recommendation and an unresolved risk must name who must accept it. Green
CI and GitHub mergeability do not approve product behavior; a recommendation never authorizes merge.

## Delta review after a new push

1. Retrieve the **previous reviewed SHA** from the earlier recorded review and the **new PR head SHA**. If either is unknown, explain the resulting limitation and broaden the review.
2. Compare those two SHAs (not merely the PR's current diff against `main`). List added/modified code, tests, docs, evidence and any changed dependencies.
3. For each earlier blocking finding, identify the exact resolution and verify the affected paths and tests. Leave unresolved threads/findings open.
4. Check whether the acceptance-criteria matrix, test fingerprint and artifact coverage are still valid for the new head. Any reused older evidence must be scoped explicitly to unaffected behavior.
5. Reassess CI **at the new head** and changes to the base or neighboring PRs. Expand to a **full review** if the new changes alter scope, architecture, security assumptions, contracts, relevant call paths, risk tier, or invalidate the original proof.
6. Write a short delta report: `old reviewed SHA -> new head SHA`, findings resolved/remaining, new findings, CI/evidence gaps, and an updated verdict. Do not copy the earlier recommendation unchanged.

A previous GitHub approval is not proof of correctness for later commits, even if repository protection does not automatically dismiss it.

## Publication and integration handoff

- If asked for feedback in chat, provide a copyable report. If explicitly asked to post on GitHub, post one review summary and targeted line comments for actionable findings; avoid noisy duplicate review threads.
- Do not claim a PR has been approved unless a **real, authorized** GitHub review was submitted successfully. When a maintainer asks for an approval, distinguish your technical recommendation from their merge decision.
- If multiple related PRs change shared contracts, or a high-risk PR depends on an older `main`, identify a **G5 integration check** instead of treating per-PR review as sufficient.
- Do not close the implementing issue or merge a PR as a side effect of a review.

## Phase 2 pilot feedback (#1204)

For each selected **L1**, **L2**, and **L3** pilot, record PR and reviewed SHA, implementation author, evidence inspected, confirmed findings, false positives, missing proof, whether a maintainer had to reproduce behavior, and **measured** reviewer/maintainer follow-up time if available (otherwise `not measured`). Exercise at least one delta review. Recommend to #1205 only fields that can be checked mechanically; do not equate checked fields with correct behavior.
