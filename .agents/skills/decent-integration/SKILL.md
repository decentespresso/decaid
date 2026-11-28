---
name: decent-integration
description: Prepare a dependency-aware G5 merge-batch analysis for related Decaid PRs, including live SHAs, semantic overlaps, disposable combined verification and rechecks as main advances; recommend ready, hold or human validation without merging.
---

# Decaid integration review

Implement G5 of [Decaid Agent Workflow](../../../doc/AGENT_WORKFLOW.md). That document is authoritative for gates, risk, evidence and the **single merge-batch report template in section 5**. `AGENTS.md` governs engineering and physical-device safety; `CONTRIBUTING.md` and the existing PR template govern contribution policy. This procedure is advisory, not merge authorization or a new CI requirement.

Use this skill for 3+ related PRs, overlapping changes or L3 integration assessment. Use `decent-review` for each PR's G4 review, `decent-dev` for local checks and `decent-app` for reproducible running-app scenarios. Missing G4 proof is a hold, not something integration testing silently fixes.

## 1. Collect a live, reproducible batch fingerprint

Start with PR numbers, not assumed ordering. Record repository, UTC collection time, tools/environment and every failed or inaccessible query. Save sanitized raw results and actual diffs in a durable evidence directory; do not publish credentials, customer data or private evidence. A command listed here is not evidence it ran.

Example read-only collection (replace `795` for each candidate):

```sh
git fetch origin main
git rev-parse origin/main
gh pr view 795 --repo decentespresso/decaid --json number,url,title,state,isDraft,baseRefName,baseRefOid,headRefName,headRefOid,body,files,closingIssuesReferences,reviewDecision,reviews,statusCheckRollup,mergeable,mergeStateStatus
gh api --paginate repos/decentespresso/decaid/pulls/795/files
gh api --paginate repos/decentespresso/decaid/pulls/795/reviews
gh api --paginate repos/decentespresso/decaid/issues/795/comments
gh pr diff 795 --repo decentespresso/decaid
gh api graphql -f query='query($endCursor:String){repository(owner:"decentespresso",name:"decaid"){pullRequest(number:795){reviewThreads(first:100,after:$endCursor){nodes{isResolved isOutdated path line comments(first:100){nodes{url body author{login}} pageInfo{hasNextPage endCursor}}} pageInfo{hasNextPage endCursor}}}}}' --paginate
```

Paginate REST lists and GraphQL connections. If a thread has more than 100 comments, retrieve its remaining comments by thread node ID before declaring its findings closed. Summary `files`/`reviews` fields can truncate: use complete API lists. Read relevant linked issue bodies **and comments**, explicit dependencies in PR bodies/discussions, prior review findings and evidence artifacts. `closingIssuesReferences` omits non-closing links such as `Related`; inspect those too. Record missing specifications as unknown, not inferred acceptance.

Fetch PR code into a private local namespace, never a contributor branch. For example:

```sh
git fetch origin refs/pull/795/head:refs/integration/1205/pr-795
git rev-parse refs/integration/1205/pr-795
git merge-base origin/main refs/integration/1205/pr-795
git diff --name-status origin/main...refs/integration/1205/pr-795
git diff origin/main...refs/integration/1205/pr-795
```

Use an unused namespace for each batch. Compare fetched SHA to live `headRefOid`; re-query after collection to detect races. Pin the full current-main, PR-base, PR-head and merge-base SHAs in the report and use those immutable SHAs in subsequent commands. A historical opening base is not today's integration base. Inspect intervening `main` changes to relevant paths since the merge base.

For each head, inspect check runs **and commit statuses** (paginate REST endpoints as necessary), not just a historical green badge:

```sh
gh api --paginate repos/decentespresso/decaid/commits/HEAD_SHA/check-runs
gh api --paginate repos/decentespresso/decaid/commits/HEAD_SHA/statuses
```

Record links and passing/failing/pending/missing states, review submissions and unresolved/outdated threads. An outdated thread is not necessarily resolved. Keep **author-tested SHA**, **reviewer-reviewed SHA** and **combined integration SHA** separate. Locate earlier tested SHAs in the body, comments and artifacts; if unknown, say unknown. Explain any scoped reuse of older evidence; neither approval nor test results automatically transfer to a newer head.

## 2. Build a directed plan, not a sorted PR list

- Map requirements -> changed files -> shared contracts/callers -> tests and scenarios. Inspect actual diffs and relevant unchanged code, not only titles or file names.
- Add directed edges `prerequisite -> dependent` for explicit dependencies and demonstrated semantic requirements. Label each edge explicit, inferred (with mechanism/path evidence), or uncertain. Shared files alone do not prove dependency. Explain what breaks without the prerequisite.
- Check API/schema/client compatibility, auth, plugin and skin updates, BLE/machine control, persistence/migration order, onboarding, shared state and feature flags. Name unaffected contracts when useful; avoid a blanket compatibility claim from shallow inspection.
- Separate textual conflicts from semantic conflicts (for example, cleanly merging producer and consumer changes that disagree on units or absent values). GitHub `MERGEABLE` is not a G5 verdict.
- Topologically order supported edges; for independent PRs explain the proposed tie-break. Cycles, contradictory requirements and uncertain edges require maintainer clarification or a hold, not an invented order. A provisional test order may differ from a merge recommendation.
- For each PR assign the highest affected risk, G4/CI/evidence state, blocked-on relationships and exact hold reasons. Draft/closed PRs, unresolved blockers, missing current-head CI and absent human/hardware proof cannot become ready by appearing in a batch.

## 3. Exercise a disposable combination where safe

For L3 or overlaps, attempt a fresh **isolated local integration worktree** when the executor, space and required inputs are available. Check branch/worktree ownership and existing dirt first. Never use the primary checkout, rewrite contributor branches, push, bypass protection, merge remotely or operate hardware. Local synthetic merge commits are only test artifacts. Preserve conflict logs; do not guess product semantics to resolve conflicts.

Example sequence, replacing all uppercase placeholders with recorded values and choosing a new disposable path/branch:

```sh
git worktree add -b integration/BATCH DISPOSABLE_PATH MAIN_SHA
git -C DISPOSABLE_PATH merge --no-ff --no-edit PR_FIRST_HEAD_SHA
git -C DISPOSABLE_PATH merge --no-ff --no-edit PR_SECOND_HEAD_SHA
git -C DISPOSABLE_PATH merge --no-ff --no-edit PR_THIRD_HEAD_SHA
git -C DISPOSABLE_PATH rev-parse HEAD HEAD^{tree}
git -C DISPOSABLE_PATH status --short
```

Run sequentially and stop on the first failure. Record each intermediate commit and final commit/tree fingerprint plus exact commands, outputs and exit codes. On a conflict, save `git status --short`, `git diff --name-only --diff-filter=U` and conflict hunks before `git merge --abort`. Mark the full combination **not tested**; a partial combination is not the final head. Do not run tests on unresolved files. Try an alternative order only when the dependency analysis justifies it; never hide a conflict by silently dropping changes.

Select focused tests from the actual affected surfaces and repository test guidance; document preconditions and expected results **before** execution. Check, as applicable:

- Each PR alone, combined producer/consumer behavior and unchanged legacy clients.
- Missing/malformed values, unsupported capability/firmware, disconnect/reconnect, cancellation, auth denial, rollback and migration from the previous production schema with representative data.
- Running-app API/stream success and error paths against the combined build, using persistent WebSocket clients; simulated flags/device identity and request/response traces must be recorded. Use `decent-app` procedures, not a screenshot as protocol proof.
- Updated plugin/skin compatibility and onboarding on affected platforms; distinguish simulator limits from physical machine behavior.

Follow the repository's real code gates for the combined **code** candidate, including scoped formatting, analysis and full tests where required. Missing ignored build inputs or stale bundles are setup problems to diagnose, not automatic baseline regressions. A docs-only skill change does not itself require unrelated Flutter gates.

If a conflict, missing executor, unavailable platform or unsafe setup prevents execution, give the concrete blocker, label each unrun check **not tested**, and supply exact runnable commands for the recorded SHAs with environment prerequisites. Never claim static review proves runtime compatibility. Name the authorized human/platform/hardware follow-up and residual risk; no device operation without explicit authorization. Do not remove a worktree until its evidence is retained, and never force-remove unrelated dirt.

## 4. Hand off and refresh after each real merge

Fill **only** the canonical section 5 G5 template in `doc/AGENT_WORKFLOW.md`; write its Layer 1
decision brief first and link longer sanitized evidence rather than duplicating a competing template
here. Apply the shared <=150-word, <=3-blocker plain technical writing contract. Include exactly one
primary Next action with one named owner and one prioritized action, or explicit
**None — no action required**; rank 1 must repeat that owner/action, while every other queue row is
subsequent or dependent. A table that only summarizes statuses is a **Status overview**, not a
ranked queue. Include the compact ranked per-PR view before the full seven-column Layer 2 matrix.
State `ready`, `hold`, or `needs human validation` and, when applicable, `0 of <N> ready`. Keep
current-head CI, exact author/reviewer/combined SHAs, conflicts, G4/evidence gaps, negative paths,
hardware limits and `unknown` facts visible in Layer 1 when they affect the decision; retain complete
proof in a closed Layer 2 `<details>` block or durable technical report link. These are
recommendations, not merge authorization. Record exceptions/waivers with the specific item,
authorized maintainer, rationale and residual risk; agents cannot waive hard gates. Maintainer
authorization remains separate and pending until actually given.

After each real merge or changed PR head:

1. Fetch newest `main`, pin its SHA, record what landed since the prior fingerprint and re-query remaining PR heads, CI, reviews and unresolved threads.
2. Compare changed contracts, diffs and merge bases with the prior graph. Recompute edges/order and invalidate evidence affected by the new base/head; scope any older evidence retained to demonstrably unchanged paths.
3. Rebuild a fresh disposable combination from updated `main`. Re-run impacted focused and combined scenarios plus required gates, record the exact final integration SHA/tree and independent delta review where needed. Do not rebase, retarget or amend contributor branches: retarget the **analysis** only.
4. Publish an updated report identifying superseded evidence and outstanding holds. If `main` advances again before authorization, repeat. Never carry a prior batch recommendation forward without this check.

For the Deliverable A pilot, analyze at least three actual named PRs using live metadata. Record review start/finish, missing-proof returns, extra rounds, false positives, maintainer follow-up and observed post-merge regressions; unavailable metrics are **not measured**, not zero. No measured time savings were established in Phase 2. Evidence-field validation and ruleset recommendations are separate Deliverables B/C; this skill changes neither CI nor branch rules.
