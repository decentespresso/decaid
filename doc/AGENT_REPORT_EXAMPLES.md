# Decision-first report examples

These examples use public historical records. They show presentation only; they do not change the
review, testing, safety, privacy, contributor-responsibility, or merge-authority rules. The source
record remains the audit evidence. Historical status is labelled historical. The four opening reports
are rewritten historical conversions; Pass 3 retains actual unedited blind-agent output. None is a
live merge recommendation.

## Historical G5: PR #1214 four-PR pilot

**Source records:** [full retained pilot report](https://github.com/decentespresso/decaid/pull/1214#issuecomment-7012478060), [pre-execution plan](https://github.com/decentespresso/decaid/pull/1214#issuecomment-7012491782), [PR body](https://github.com/decentespresso/decaid/pull/1214).

### Before excerpt

> `# G5 merge-batch analysis — #795 / #802 / #803 / #804`
>
> `- Repository: decentespresso/decaid; Related #1205, Deliverable A pilot only.`
>
> `## Candidate assessment`
>
> `| PR / head SHA | Risk and rationale | G4/current-head CI/unresolved findings | Author-tested / reviewer-reviewed SHAs; older evidence | Prerequisite / blocked-on | Suggested sequence | Recommendation and exact reason |`
>
> *(Excerpt continues; the full original table and diagnostic analysis are retained in the linked source.)*

The original record put the complete table and diagnostic analysis in the first reading path.

### After Layer 1 brief (historical)

**Decision:** **hold — 0/4 ready**; recommendation, not authorization. **Why:** (1) #802–#804 lack accepted scope and current-head G4; #802 client naming unresolved. (2) #795 lacks current-head G4 and has four unresolved **outdated** threads. (3) Reproduced #803/#804 conflicts block assembly; #804 lacks cross-mode limiter tests. **Next action:** Maintainer — record scope and client-naming decision before conflicts. **Limits:** historical main `efb717bd1e11f6a31ca7a31fd2b585bc3ded50be`; four current-head CI sets passed; no combined behavior test; author-tested SHAs **unknown**; physical zero-range behavior and firmware/simulator mismatch unverified. **Details:** [retained full proof](https://github.com/decentespresso/decaid/pull/1214#issuecomment-7012478060).

### Ranked queue

**Ranking is a decision ranking, not historical assembly order.**

| Rank | PR | Status | Reason | Action |
| --- | --- | --- | --- | --- |
| 1 | #802 | hold | scope/client naming unresolved | Maintainer: record scope/rollout decision |
| 2 | #795 | hold | no current-head G4; four unresolved outdated threads | Reviewer: review current limiter contract; retain/close threads |
| 3 | #803 | hold | reproduced assembly conflict | Implementer: resolve after #802 scope |
| 4 | #804 | hold | incomplete parser integration | Implementer: prepare parser/test fix |

### Layer 2 facts retained

- Current main was `efb717bd1e11f6a31ca7a31fd2b585bc3ded50be`; all four PR bases and merge bases were `a36f89a21360b65dd1d209bf369aaf6c0ec07555`.
- #795 head `08e0e0132402dbc79a40c88d6dafe9179ad0f6ca`: CI success; CHANGES_REQUESTED; four unresolved outdated threads; the latest author reply changed the null/default-range contract. Author local test SHA was unknown.
- #802 head `87ad40546e69b9da3a0359411e852d6c579401f8`: CI success; no G4; product/spec agreement and old-to-derived key rollout unresolved. Author and hardware test SHAs were unknown.
- #803 head `4ee67701776eaf37520db55ed44b7dd5cb5817df`: CI success; no G4; conflicts in `doc/Api.md` and `unified_de1_transport.dart`; BLE, shot JSON and client compatibility were unverified. Physical behavior required authorized human validation.
- #804 head `9ae02211d4b2b51d9ac5ae0a82c24d1a7e5c6cab`: CI success; no G4; shared profile-parser conflict; cross-mode limiter tests and machine validation were missing.
- The explicit semantic dependency was **#802 -> #803**. #795 before #804 was a test preference, not a hard dependency.
- Main + #795 + #802 assembled through `a81b37224bbf659628de6437281a485540235239` / tree `ed62b489f666a0691f6792999d1002d49e23ace5`; adding #803 failed with the two conflicts above. The alternative #795 + #802 + #804 subset failed in `lib/src/models/data/profile.dart`. No final combined SHA/tree existed.
- No Flutter tests, analysis, API smoke, simulator, or physical device run was claimed. Reviewer burden, maintainer follow-up, false positives, and regressions were **not measured**.

## Historical G4 first review: PR #1198

**Source records:** [PR body](https://github.com/decentespresso/decaid/pull/1198), [first review](https://github.com/decentespresso/decaid/pull/1198#pullrequestreview-5963726132), [later review](https://github.com/decentespresso/decaid/pull/1198#pullrequestreview-5973024291).

### Before excerpt

> **Slow reheating after standby can lose the countdown permanently.**
>
> In `estimateRemainingTime()`, the new early `not_heating` path sets `state.published = false`.
>
> Please add a regression test: establish a countdown, hold flat long enough to reach `not_heating`, then resume with a sustained 0.03 K/s ramp below target and assert that a countdown returns in a reasonable interval while stationary standby noise still produces none.

These are exact sentences from the first review, not the later author PR body. The review recorded
head `3ba3e90faa04b032876a95b91aff081dffc9fa18`; a fixed/new head and fixed-head CI or hardware
proof were unavailable. CI status at that review is **unknown**, not failed or unrun.

### After Layer 1 brief (historical)

**Decision:** **hold** — **changes required**; recommendation, not merge authorization.
**Why:** (1) The first review found a confirmed slow-reheat recovery defect: a 0.03 K/s ramp could remain `insufficient_data` after standby. (2) The fix and regression proof were unavailable at this historical review. **Next action:** Author — fix slow-recovery state handling and add a regression test covering an established session, stationary-noise negative path, and cold-start protection. **Limits:** reviewed SHA `3ba3e90faa04b032876a95b91aff081dffc9fa18`; reviewed-head CI and tested SHA **unknown**; fixed-head hardware proof unavailable. **Details:** [full first-review finding](https://github.com/decentespresso/decaid/pull/1198#pullrequestreview-5963726132).

### Layer 2 facts retained

- Risk was L2: user-observable plugin heating status/countdown, with no machine actuation changes.
- The reviewer identified the exact mechanism: `estimateRemainingTime()` set `state.published = false`; the cold-start gate then required 5 K in 18 seconds or, after 45 seconds, 1 K in that history. A 0.03 K/s ramp gained about 0.54 K in 18 seconds.
- The required negative path was stationary standby noise producing no countdown; the required positive path was a resumed slow ramp below target regaining one.
- The first review's state was CHANGES_REQUESTED at `3ba3e90f...`; it did not claim a fixed-head CI result or hardware rerun.

## Historical G4 delta review: PR #1198

**Source:** [delta review](https://github.com/decentespresso/decaid/pull/1198#pullrequestreview-5973024291).

### Before excerpt

> `Previous review / delta: 3ba3e90faa04b032876a95b91aff081dffc9fa18 → f03a6fdda0e87e2aa54500bb68f7b8ebc5be2a94`
>
> `Prior blocking finding: resolved.`

### After Layer 1 brief (historical)

**Decision:** **ready** — **approve recommendation**; recommendation, not merge authorization.
**Why:** (1) The prior slow-reheat blocker was resolved at reviewed head `f03a6fdda0e87e2aa54500bb68f7b8ebc5be2a94`. (2) Current-head [CI run `44441106595`](https://github.com/decentespresso/decaid/actions/runs/44441106595) passed; its separate Node plugin suite was absent from passed CI (#1168). The physical slow-reheat rerun and independent Node evidence remain explicitly **nonblocking** gaps for this narrow follow-up. **Next action:** Maintainer — make the normal merge decision; optional Node output or hardware capture may strengthen the record but is not a new blocker. **Limits:** delta `3ba3e90faa04b032876a95b91aff081dffc9fa18 -> f03a6fdda0e87e2aa54500bb68f7b8ebc5be2a94`; author-tested Node SHA is unknown; earlier DE1 Pro 1357 observations apply to the old SHA; no independent Node/Flutter or hardware execution. **Details:** [complete delta review](https://github.com/decentespresso/decaid/pull/1198#pullrequestreview-5973024291).

### Layer 2 facts retained

- The delta covered one follow-up commit and three changed files.
- CI run `44441106595` passed contribution policy, Flutter analyze/tests, and Linux build smoke at the new head; Python tools were skipped. The separate Node plugin suite was not wired into PR CI and was tracked by #1168.
- Criterion statuses were: standby wake verified in reported environment; standby during countdown and fast release verified in reported environment; 0.03 K/s recovery weak because hardware was not retested and no independent Node artifact existed; cooling reset/noise negative paths weak on simulation/test evidence; ETA/contract verified by inspection.
- The author reported 37 Node tests passing, but the reviewer did not independently execute them. No new blocking defects were found. The verdict was an **approve recommendation**, not authorization.

## Historical G3 evidence handoff: PR #1206

**Source records:** [PR body](https://github.com/decentespresso/decaid/pull/1206), [independent review](https://github.com/decentespresso/decaid/pull/1206#pullrequestreview-5970348576).

### Before excerpt

> `- **Commands and results:**`
>
> `- **Running-app scenarios and observed behavior:** N/A — documentation only, no endpoints or flows changed.`

The original handoff kept the technical evidence in the PR body but did not put an action-first
brief ahead of it.

### After Layer 1 brief (historical)

**Decision:** **ready for review** — G3 handoff recommendation, not approval or merge authorization. **Why:** The historical L0 documentation change reported a complete evidence index, policy-preservation checks, full Flutter analysis/tests, and five script checks (two shell and three privacy) at tested SHA `0ad0bf2f97081138debea51802cc22f1888238e3`; no runtime behavior changed. The **author handoff reports** a prior independent **SHIP**. Linked public review `5970348576` is **COMMENTED**, reports no blocking findings and successful hosted PR Checks, including Analyze/test and Linux build smoke, at that SHA; neither source grants approval. **Next action:** Maintainer — inspect the immutable five-file diff against #1203 and the responsibility marker under normal review checks. **Limits:** no device or running app; hosted issue-association policy branches were not exercised locally and the handoff did not report hosted results. Linux/AppImage/storage smoke and the later runtime-visible pilot were **not tested locally**. **Details:** [retained PR evidence](https://github.com/decentespresso/decaid/pull/1206).

### Layer 2 facts retained

- Verified SHA was `0ad0bf2f97081138debea51802cc22f1888238e3`; environment was macOS arm64 with Flutter 3.47.9 / Dart 3.13.7. No device or build flags were used.
- The handoff reported `flutter analyze` exit 0, full `flutter test` `+7023 ~1` with 0 failures, release-alias tests, Decaid app skill checks, and three privacy-check commands passing.
- It reported 26/26 relative links resolving, `git diff --check` clean, and five local policy controls: filled ACCEPT, URL form ACCEPT, unchecked checkbox REJECT, missing marker REJECT, and no issue reference REJECT.
- The exact contributor responsibility marker and issue-first rule were retained. The linked public review `5970348576` is `COMMENTED`, found no blocking findings, reported PR Checks success including Analyze/test and Linux build smoke at `0ad0bf2f97081138debea51802cc22f1888238e3`, recorded a nonblocking wording suggestion, and said no merge action was taken; it did not record **SHIP**.
- Running-app/API, screenshots, physical devices and visual journeys were not applicable to the documentation-only change; hosted issue-association policy branches were not exercised locally, and the handoff did not report hosted results. The later runtime-visible pilot was not claimed.

## Acceptance-criteria map

The authoritative issue criteria are mapped here without changing their wording:

1. **Given PR #1214's four-PR G5 pilot, produce a decision brief that says 0/4 ready, names the first action, calls out both conflict and G4/evidence blocks, and links to the retained full proof. A maintainer can identify the next decision from the brief alone.** — **satisfied** by the historical G5 example and source links.
2. **Convert one G4 review (e.g. #1198 or #1182), one delta review, and one G3 PR evidence handoff into the same layered format without losing exact SHA, negative-path, CI, hardware or outstanding blocker facts.** — **satisfied** by the three historical conversions and retained facts.
3. **Default brief is approximately 150 words or fewer, limited to at most three primary blockers and one next action, unless a risk-critical exception requires more. The detailed record remains accessible and sufficiently complete for independent verification.** — **partial**: the parent/lead independently counted 133 structural words in the final blind output, including its heading and four-row queue, with at most three primary reasons and one global action. The queue remains in historical order while the global first action is Maintainer scope, so priority clarity is imperfect; this count is not a comprehension or usability measurement. The earlier 209-word output remains retained as a historical failure.
4. **Users can distinguish `ready`, `hold`, `needs human validation`, `not tested`, `failed` and `unknown`; neither green CI nor GitHub mergeability becomes authorization to merge.** — **satisfied** by the workflow vocabulary and every canonical template.
5. **A second agent using only repository instructions (no conversation history, no installed personal preference skill) produces the same action-first structure.** — **satisfied for observed structure, with limits**: the parent-owned blind output produced the five fields, four-row ranked queue and collapsed seven-column Layer 2 record. Its queue order remains historical rather than perfectly aligned with the global Maintainer scope action. This source-only exercise does not prove universal comprehension or human-maintainer readability.
6. **No code behavior, CI/ruleset enforcement, evidence requirements, author responsibility, privacy, or merge authority is changed; documentation links and report consistency checked.** — **satisfied** by the scoped documentation change and unchanged policy/template/CI checks.
7. **Compare old and new output for decision comprehension: given the report, identify whether to merge, the first blocker, the next owner/action and what was not verified, without reading Layer 2. Capture reviewer/maintainer feedback and revise if key caveats were hidden.** — **comparison and feedback recorded, with limits**: isolated agent-proxy comparisons recorded caveats and drove revisions. The maintainer subsequently read the whole document and gave positive subjective readability feedback, quoted below. This was not a controlled human Layer 1-only four-question test.

## Actual maintainer readability feedback

The maintainer/user read the whole document, not an isolated Layer 1 brief. The parent relayed this
verbatim response during the feedback closeout after candidate `cd4f32a2` was reviewed:

> i read the whole AGENT_REPORT_EXAMPLES.md and I believe the last section was the real example? I like the new condensed approach a lot, much more readable to me than before

The parent clarified that the last section was actual unedited blind-agent output; the earlier examples
were rewritten historical reports, not live merge recommendations. The user's source question required
that clarification; it is not evidence that they independently identified every report's provenance.

This is real, positive, subjective human readability feedback. It is separate from the isolated
agent-proxy comparisons below. The user did not perform the four-question Layer 1-only comprehension
exercise. No controlled human result, universal comprehension, measured savings, formal approval or
merge authorization is claimed. The blind output's nonblocking queue/global-priority caveat remains.

## Actual read-only comprehension exercise — Pass 1 (initial)

Source: immutable `.lane/issue-1217/comprehension/reader-9fa0bd10-complete.md`, SHA-256
`0fee63b7cbe4897c536e409ad0fc8ca7f70555b2ce07068ead55691278211752`. Reader identity was
`9fa0bd10`; the exercise used repository instructions and supplied source reports only. This is
agent-proxy feedback, not human-maintainer feedback, and did not verify receipts, live state, tests,
code correctness or usability.

<details>
<summary>Stage A observed answers from Layer 1 alone</summary>

The following are the complete four answers for each report, retained from the actual reader result:

| Brief | Merge now, and why? | First blocker | Next owner/action | What was not verified? |
|---|---|---|---|---|
| G5 #1214 | **No.** Hold, 0/4 ready: incomplete G4, conflicts, missing scope/evidence. | #795 CHANGES_REQUESTED and four unresolved outdated threads. | Maintainer: record accepted feature/client-naming scope before conflict resolution. | Combined behavior; author-tested SHAs unknown; hardware/firmware. Four current-head CI sets reportedly passed. |
| G4 first #1198 | **No.** Confirmed slow-reheat recovery defect; fix/proof pending. | Previously established session may remain `insufficient_data` after standby at 0.03 K/s. | Author: add regression without weakening cold-start confidence. | Fixed-head hardware/CI. Brief identifies review SHA `3ba3e90faa04b032876a95b91aff081dffc9fa18`. |
| G4 delta #1198 | **Approve recommendation**, not merge authorization. Immediate merge appears subject to maintainer disposition of the validation gap. | No stated code blocker; hardware/Node-CI gap requires disposition. | Maintainer: decide whether further validation is needed before merge. | Reviewer ran no Node/Flutter tests or hardware; earlier hardware belongs to an earlier SHA; Node suite absent from CI. |
| G3 #1206 | **Ready for review, not merge.** Documentation evidence reportedly complete. | No defect stated; independent review outstanding. | Independent reviewer: inspect five-file diff against #1203 and preserve responsibility marker. | Running app/device, hosted issue-association policy branches, Linux build, runtime-visible pilot usability. |
</details>

<details>
<summary>Stage A answers after reading the original public reports</summary>

| Original report | Merge now, and why? | First blocker | Next owner/action | What was not verified? |
|---|---|---|---|---|
| G5 | **No.** All four hold. CI does not establish accepted scope, current-head G4, or combined behavior. | #795 unresolved review state/threads and no review at its current head; scope and assembly conflicts also block the batch. | Maintainer: settle feature-fit/accepted issue and naming policy first. Reviewer, implementation owner and separately authorized operator have subsequent actions. | Combined and partial-head behavior; local Flutter/analyze/runtime/API checks; physical behavior. Exact author-tested/hardware SHAs unknown. |
| G4 first | **No.** Slow recovery can permanently lose countdown. | Clearing `published` makes resumed 0.03 K/s heating face the cold-start gate again. | Author: fix recovery state; test establish → flat stall → slow resume, while stationary noise produces none and initial confidence remains intact. | The excerpt supplies no SHA, CI record, reviewer execution, or bounded hardware coverage for the defect/fix. |
| G4 delta | **Technical approve recommendation** at `f03a6fdda0e87e2aa54500bb68f7b8ebc5be2a94`; maintainer’s normal checks remain. | **None.** Prior blocker resolved. Missing physical recheck and independent Node proof are explicitly **nonblocking** for this follow-up. | Maintainer: normal merge decision/checks. Additional Node output or hardware capture would strengthen—not condition—the recommendation. | Reviewer executed no Node/Flutter tests or hardware. Author reports 37 Node passes; Node suite absent from CI. Earlier hardware applies to `3ba3e90f`; slow recovery not physically retested; cooling/noise evidence is simulation/test-based. |
| G3 | No merge authorization supplied. Handoff reports readiness **and an earlier independent SHIP**. | None reported. | Maintainer retains publication, product-risk and merge decisions; later usability pilots remain future work. A fresh independent review is not explicitly requested. | Hosted CI/issue association; Linux/AppImage/storage smoke; running app, physical/visual/mobile journeys; later runtime-visible template usability. Local regex controls are narrower than hosted policy. |
</details>

### Stage A comparison and observed limitations

The reader reported that G5 lost dependency/partial-head and simulator-versus-firmware caveats; G4 first
lost negative-path detail and confused a known reviewed SHA with a missing fixed head; the initial G4 delta
draft left a source-described nonblocking gap unclear, so the reader interpreted it as an apparent
condition; and G3 understated the recorded proof and invented a fresh review action. These are
comprehension observations, not correctness or timing measurements.

<details>
<summary>Stage B actual Layer 1 output and limitation</summary>

The actual output began:

> ### G5 decision brief — historical #795 / #802 / #803 / #804 batch
>
> - **Decision:** **hold — 0 of 4 ready**. Historical recommendation only; never merge authorization.
> - **Why:** (1) #795 has unresolved review state/threads and no current-head G4. (2) #803 and the alternative #804 assembly encountered conflicts. (3) #802/#803/#804 lack accepted scope/current G4; client naming remains undecided.
> - **Next action:** **Maintainer** — record accepted feature scope and client-naming policy before conflict-resolution work.
> - **Confidence / limits:** At the historical recheck, main was `efb717bd1e11f6a31ca7a31fd2b585bc3ded50be`; all four head-bound CI sets passed. Author-tested SHAs were **unknown**; reviewer SHAs were stale or absent. No final combined SHA exists; combined and partial-head behavior were **not tested**. Hardware/firmware remain unverified.
> - **Details:** [Historical full evidence report](https://github.com/decentespresso/decaid/pull/1214#issuecomment-7012478060); fingerprints and gaps below.

It did **not** produce the required compact ranked per-PR list and used a five-column candidate table
rather than the required seven-column matrix. This is a failed/partial structure exercise, not an
unqualified success. The canonical workflow now makes both structures explicit; a fresh post-refinement
exercise must check the final briefs.
</details>

At Pass 1 time, maintainer readability feedback was pending. The later full-document response is
recorded separately above; this agent-proxy exercise did not establish human comprehension or timing savings.

## Pass 2 — fresh-reader read-only exercise

Source: immutable `.lane/issue-1217/comprehension/reader-426a1bc4-complete.md`, SHA-256
`c526df99e1abff921196647a317e2d45a9f0e096ccc386b03c9ffd897b29b9f2`. Reader identity was
`426a1bc4`. Like Pass 1, this was a historical report-production exercise only: the reader used
repository instructions and supplied source reports, with no conversation history or installed
personal-preference skill. It did not accept the candidate, assess live state, verify receipts, or
provide human-maintainer feedback. The output below is retained before this final bounded clarification
pass.

### A. Actual Layer 1-only answers

| Brief | Merge now, and why? | First blocker | Next owner/action | Unverified |
|---|---|---|---|---|
| G5 four-PR pilot | **No: hold, 0/4 ready.** Review, scope, and assembly blockers remain. | First listed: #795’s unresolved review. First prioritized decision: #802’s scope. | Maintainer: record feature/client-naming scope before conflict resolution. | Combined behavior, author-tested SHAs, hardware/firmware. |
| G4 first, #1198 | **No: changes required.** Slow recovery at 0.03 K/s can remain `insufficient_data`. | Slow-reheat recovery defect. | Author: add the established-session slow-reheat regression without weakening cold-start confidence. | Reviewed-head CI, tested SHA, fixed-head hardware proof. |
| G4 delta, #1198 | **Eligible for normal merge consideration**, not authorized. Prior blocker resolved; reviewed-head CI reportedly passed. | None stated. Physical rerun and independent Node evidence explicitly nonblocking. | Maintainer: make the normal merge decision. | Author-tested Node SHA; independent Node/Flutter execution; fixed-head hardware behavior. |
| G3, #1206 | **Ready for review, not merge approval.** Documentation evidence is reported complete, with a prior SHIP review. | None stated; remaining disposition is not expressly a technical blocker. | Maintainer: inspect the five-file diff against #1203 and responsibility marker for review/publication disposition. | Hosted CI and issue-association branches; device/app, Linux/AppImage/storage smoke; later runtime pilot. |

### B. Actual comparison with original public-source reports

| Brief | Observation |
|---|---|
| G5 | **Overall hold recommendation preserved.** The new queue is explicitly a decision ranking, not a replacement for source assembly order 795→802→803→804. However, it omits that #795’s unresolved threads are **outdated**, no submitted review covers its current head, and the author changed the limiter contract. #803’s semantic dependency on #802, breaking rename, and the simulator/firmware zero-range discrepancy require opening the linked proof. #804’s queue reason also omits its reproduced parser conflict. These omissions do not reverse the verdict but matter for assembly and release decisions. |
| G4 first | **Changes-required recommendation preserved.** Public metadata confirms `CHANGES_REQUESTED` at `3ba3e90faa04b032876a95b91aff081dffc9fa18`; omitted body metadata was not a missing review. The brief abbreviates the remedy: source requires both state adjustment and regression coverage, including stationary standby noise. “Unavailable proof” concerns this recovery fix, not the earlier hardware validation acknowledged by the source. |
| G4 delta | **Approval recommendation preserved.** Nonblocking hardware/Node gaps remain nonblocking. An important compressed caveat: passing CI **did not include the separate Node plugin suite**, tracked by #1168. The source retains that distinction and its weak hardware/test-only criterion assessments. |
| G3 | **No missing review invented.** Both source and brief report an independent SHIP review. Additional maintainer inspection is a handoff action, not evidence that review never occurred. Hosted/platform gaps were not promoted into blockers. “Diff against #1203” is imprecise: #1203 supplies requirements, not necessarily a Git comparison base. |

No overall technical recommendation changed. Decision-relevant detail was compressed, particularly in
the G5 queue, but retained in linked source. These are **agent-proxy observations**, not actual
maintainer readability feedback.

### C. Actual fresh-reader G5 output excerpt

The fresh reader produced this five-field brief and ranked view:

> **Decision:** **hold — 0 of 4 ready**; recommendation only, never merge authorization.
>
> **Why:** (1) Accepted feature/client-naming scope is missing. (2) #795 has unresolved review findings; #802–#804 lack G4 review. (3) Disposable assembly reproduced #803 and #804 conflicts.
>
> **Next action:** **Maintainer** — record accepted feature scope and client-naming policy before conflict resolution.
>
> **Confidence / limits:** Historical main `efb717bd1e11f6a31ca7a31fd2b585bc3ded50be`; all four recorded-head CI checks passed. Author-tested SHAs are unknown; no review covers #795’s recorded head. No final combined SHA exists; combined behavior was **not tested**. Breaking client naming, BLE lifecycle, machine-mode safety, and simulator/firmware limiter differences remain unresolved or unverified.
>
> **Details:** [Retained historical technical evidence and follow-up commands](https://github.com/decentespresso/decaid/pull/1214#issuecomment-7012478060).
>
> **Ranked per-PR view**
>
> | Rank | PR / head | Status | Single reason | Next action |
> |---|---|---|---|---|
> | 1 | #802, `87ad4054…` | hold | Accepted scope/client naming absent | Maintainer: record scope and rollout decision. |
> | 2 | #795, `08e0e013…` | hold | Current-head review unresolved | Independent reviewer: assess current limiter contract and explicitly retain/close findings. |
> | 3 | #803, `4ee67701…` | hold | Reproduced assembly conflicts | Implementation owner: resolve after scope decision, preserving current-main lifecycle behavior. |
> | 4 | #804, `9ae02211…` | hold | Reproduced parser conflict | Implementation owner: integrate parser semantics and restore cross-mode limiter tests for review. |

The lead counted **114 structural words** in the reader's five-field brief, and **209** including
its ranked view. This is an observed brevity overrun, not an unqualified template pass or a measured
improvement. The fresh reader correctly identified no-merge G5, the first slow-recovery defect,
nonblocking delta gaps, and the prior G3 SHIP without inventing a missing review. Criterion 5's
action-first structure was observed; criterion 3's whole-output brevity adherence remains imperfect.
At Pass 2 time, maintainer readability feedback was pending. The later full-document response is
recorded separately above; this exercise did not establish measured savings or issue completion.

## Pass 3 — parent-owned blind read-only exercise (final bounded pass)

Source: immutable `.lane/issue-1217/comprehension/reader-67f3ff91-blind-complete.md`, SHA-256
`b6bf2999e985b62748c3eedf297f4d66948641479b36f1841b60205ef8e5782a`. Extraction metadata is
`.lane/issue-1217/comprehension/reader-67f3ff91-extraction.json`; the exact extracted Layer 1 is
`.lane/issue-1217/comprehension/reader-67f3ff91-layer1-only.md`. The lead extracted Python string offsets
`327` at `## G5 decision brief` through `1585`, before the first `<details>`. This excludes
the files-read/attestation preamble, Layer 2, the reference definition, and harness acceptance
metadata. The durable public source reference used by the output is reproduced below.

The parent counted with JavaScript; the lead independently confirmed **133 structural words** in Python
using the same regex pattern, including the heading and four-row ranked queue. These are lead/parent
counts, not a reader-measured claim.

The reader attested to only `AGENTS.md`, `doc/AGENT_WORKFLOW.md`, the integration skill and the original
historical pilot as inputs: no after examples, previous outputs, conversation history, personal skills,
live GitHub, shell/tests, edits or human feedback. The output had the five fields, the ranked four-PR table, and a collapsed seven-column Layer 2
record. It preserved `0 of 4 ready`, the global Maintainer scope action, CI/report fingerprints, and
untested combined/physical limits. The queue remains in historical order `795 / 802 / 803 / 804`,
while the global first action is Maintainer scope; rank 1's Reviewer delta action is therefore not
perfectly aligned with the global priority. This is source-only format evidence, not runtime or
correctness proof, human-readability feedback, or perfect-comprehension proof. It does not support a
universal-pass claim. The complete raw output remains immutable and its hash and extraction boundaries
make the count reproducible.

### Acceptance-criteria update from Pass 3

- Criterion 3 — **partial**: the lead/parent count is 133 structural words including the heading and
  ranked queue, with at most three primary reasons and one global action. The historical queue order
  and global-action mismatch leaves priority clarity imperfect; the count is not a comprehension or
  usability measurement.
- Criterion 5 — **satisfied for observed structure, with limits**: the parent-owned blind output used
  the required five fields and four-row ranked queue and retained the seven-column Layer 2 record. The
  queue-priority ambiguity remains, and this source-only exercise does not prove universal comprehension
  or human-maintainer readability.

<details>
<summary>Pass 3 parent-blind Layer 1 output — verbatim</summary>

## G5 decision brief — #795 / #802 / #803 / #804
- **Decision:** **hold — 0 of 4 ready**; recommendation only, never merge authorization.
- **Why:** #803/#804 combination conflicts; G4 missing or stale; accepted scope and client-name rollout unresolved.
- **Next action:** Maintainer — record accepted feature scope, including channel-name rollout.
- **Confidence / limits:** Historical 2026-11-19 main `efb717bd1e11f6a31ca7a31fd2b585bc3ded50be`; all recorded head CI succeeded. Author-tested SHAs unknown; latest #795 reviewer SHA `c05e2b99f8ddbbe4d33d0dbd77aabed75f56bbb2`, others none. Partial integration `a81b37224bbf659628de6437281a485540235239`; no final combined SHA. Combined behavior and physical safety **not tested**; hardware authorization pending.
- **Details:** [Complete historical evidence][source].

### Ranked per-PR view
| Rank | PR / head | Status | Single reason | Next action |
| --- | --- | --- | --- | --- |
| 1 | #795 / `08e0e013` | hold | Unresolved G4 | Reviewer: delta review |
| 2 | #802 / `87ad4054` | hold | Scope unresolved | Maintainer: scope decision |
| 3 | #803 / `4ee67701` | hold | Transport conflicts | Owner: reviewed resolution |
| 4 | #804 / `9ae02211` | hold | Parser conflict | Owner: restore cross-mode tests |

</details>

[source]: https://github.com/decentespresso/decaid/pull/1214#issuecomment-7012478060
