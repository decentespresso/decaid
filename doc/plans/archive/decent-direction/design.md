# #1224 Phase A — decent-direction design rationale

## Scope

Phase A of #1224 only: a repository-local `decent-direction` skill, two separate contracts (product
compass, decision map), and one public-safe draft pilot. `decent-triage`, `decent-refine` and
`decent-release` are Phases B–D and were not implemented; no label, milestone, issue or repository
direction document was created. No runtime behavior changed.

## Why two contracts, not one

The compass and the map answer different questions and are read on different cadences. The compass
is a standing snapshot: what is approved, what is candidate, what is unknown, and which single human
decision comes next. A map is situational: one bounded initiative whose destination can be named but
whose route cannot. Folding them together makes "the backlog" look like strategy — the exact failure
#1224 names — so the compass separates maintainer-authored direction, including a milestone
description, from delivery facts such as milestone membership, labels, counts and release notes. An
`approved` line needs an attributed maintainer source; membership never supplies one.

## Authorized adaptation — milestone descriptions are direction

Issue #1224 originally treated a milestone as delivery evidence only. The operator authorized an
adaptation on 2026-11-23: the maintainer writes and edits milestone descriptions to steer direction,
candidate issue inclusion and the refinement a milestone needs, so a maintainer-authored description
is direction within the scope its words state. Requiring a separate `PRODUCT_DIRECTION.md` or a
second theme-approval round would duplicate the source the maintainer already maintains and add
rounds without decisions, which completion criterion 1 does not ask for: an approved/candidate/
unknown split with one human action, not a new approval ceremony.

Guardrails kept:

- A milestone title, its issue membership, labels, open and closed counts, assignment and
  `updated_at` are delivery facts. They expose conflicts and seat candidates; they never state
  direction or approve an issue.
- Broad and conditional wording keeps its scope. "Additional API hardening" approves a subject, not
  an issue list; "if needed" stays conditional until a named maintainer resolves it.
- Provenance is the milestone URL, the verbatim description, the creator and the observation date.
  The API exposes the milestone creator, not the description editor, so the editor reads
  `not recorded`; `updated_at` proves neither the edit nor the approval date.
- The description is reread on every run. Only observed text creates a row; a changed description is
  quoted, dated by its own observation and supersedes the earlier row, which stays readable. No
  earlier text is reconstructed.
- An empty, vague, conflicting, stale or unattributed description is `unknown` with its reason and
  at most the decision-critical question.
- Recommending issue inclusion or refinement is not assigning issues or editing the milestone.

The superseded wording appears in the original issue text and in the first draft of this rationale;
this section replaces it.

## What was adapted from Wayfinder

Inspected `mattpocock/skills` `wayfinder` SKILL.md and its guide at refinement time. Kept: the
destination-first act, decision questions rather than implementation slices, the fog test (sharpness
now, not answerability now), fog graduation, the frontier, out-of-scope as a scope boundary that
never graduates, the map as an index pointing at one place per decision, and plan-not-build.

Dropped, because Decaid already has a tracker contract and an evidence workflow: `wayfinder:` label
families, child-issue blocking as a required mechanism, research branches, assignee-as-claim,
autonomous ticket creation, and the skill's own setup/prerequisite ecosystem. Upstream's own guide
records its worst failure — an agent writing "this map carries execution" into a map's Notes and
later reading it back as permission — so Notes here explicitly carry no build authority and every
traffic to implementation goes through the G1 handoff.

## Provenance and authority

A theme changes by appending a dated entry that names the entry it supersedes; the superseded row
stays readable. `ruled out` records reason, decider and date and stays visible. Where the deciding
authority is not recorded, the entry says `decided by: not recorded` rather than inventing a
maintainer. This is what makes revision and rejection auditable in one read instead of in git
history.

Agents recommend; maintainers decide strategy, issue acceptance, release scope and publication.
Tracker writes require explicit authorization, and the reply records the before/after.

## G1 handoff without Phase C

`decent-refine` does not exist yet, so the cleared-map handoff restates the G1 fields itself:
problem, affected behavior, scope boundary, compatibility and constraints, observable acceptance
criteria, negative-path and test expectations, proposed L0–L3 risk, unresolved unknowns with owner,
and an explicit human acceptance gate. An implementing agent can write tests from that block and a
maintainer can accept or reject scope, with no skill dependency.

## Pilot choices

The pilot reads the live public 0.9.4 milestone description ("Additional API hardening. Driver
runtime improvements if needed.") and separates three things a single read can confuse: the observed
maintainer direction inside its stated scope, proposed issue choices that fit that reading, and the
questions nobody answered. Public sources keep it safe: the milestone, its public issue membership,
`doc/Api.md` and `doc/RELEASE.md`. #925, #1135, #1192 and the open membership of #1141 and #1078 give
the pilot real counterexamples — a conditional item, a later-milestone placement that constrains
timing without prohibiting earlier work, a stale 0.9.3 delivery state, and an unattributed
description editor. The optional map is shown as an optional walkthrough, because a milestone never
requires one. Metrics that no human session produced stay `not measured`.

## Verification approach

No behavior, so verification is contract presence, link resolution, Layer 1 bounds and scenario
checks: each check names the live case and the text that must carry it, so a maintainer can reproduce
it by eye. The checks cover a broad description honored, conditional wording held conditional,
issue recommendations kept out of assignments, the blank, stale and unattributed description cases,
and the two bounded-uncertainty cases a first read tends to overstate: a possible driver-runtime fit
for #1078 that stays unknown, and a later-milestone placement that constrains timing without
prohibiting earlier work. The claims are text-level; they do not prove that a future agent follows
the skill, and no maintainer session ran.
