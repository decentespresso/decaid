# Direction contracts

Two contracts: the **product compass** (standing) and the **decision map** (one initiative). Both are
Markdown a maintainer reads. Neither writes to the tracker.

Line status vocabulary: `approved`, `candidate`, `unknown`, `ruled out`, `superseded`.

## Direction sources

Record direction from these sources, strongest first. The third is not direction.

1. **A maintainer-authored milestone description.** It is direction within its stated scope. Record
   the milestone title and number, the verbatim text, the milestone URL, the creator, and the date
   you read it. The API exposes the milestone creator, not the description editor: write
   `creator <login>` and `description editor: not recorded` unless a maintainer says who wrote it.
2. **A direct maintainer statement**: issue or PR comment, release note, doc change, or reply.
   Record the same fields.
3. **Delivery facts**: milestone title, issue membership, labels, open and closed counts,
   assignment, `updated_at`. They show what is planned or shipped and expose conflicts. They do not
   state direction, and they never approve an issue.

Reread the live description on every run. Unchanged text adds no row. Changed text gets a new dated
row quoting it and naming the row it supersedes, with the old row kept. Never reconstruct a
description nobody observed.

Broad and conditional wording keeps its own scope. "API hardening" sets a subject, not an issue
list; "if needed" leaves that item conditional until a named maintainer resolves the condition.
Turning either into approved work needs a new maintainer statement.

An empty, vague, conflicting, stale or unattributed direction statement is `unknown` with the
specific reason, and produces at most the decision-critical question.

## Product compass

A snapshot answers four questions in this order: what a maintainer stated, what is only proposed,
what nobody has answered, and which single human decision comes next.

Deliver it in the answer or a local draft. A maintainer may authorize a committed versioned document
(for example `doc/PRODUCT_DIRECTION.md`) once its contents and publication scope are approved. That
document is optional. Editing a milestone description already revises the direction, so no separate
theme-approval ceremony is required.

### Sections

1. **Consulted** — each source with link or path, and the date read or repository state.
2. **Approved** — statements a maintainer made, inside the scope they stated:
   `Status | Statement | Scope | Source | Observed | Decided by | Edit or approval date | Supersedes`.
3. **Candidate** — agent proposals, typically issue inclusion, exclusion or refinement order:
   `Choice | Fits because | Consequence or cost | Owner or blocker`.
4. **Unknown** — unanswered questions with who can answer, plus each missing, vague, conflicting,
   stale or unattributed direction statement with its reason.
5. **Conflicts** — delivery facts that disagree with an approved row or with each other.
6. **One next action** — the highest-value human decision, stated once.

### Approved rows

- Status is `approved`, `ruled out` or `superseded`.
- `Decided by` names who decided. A milestone row reads
  `maintainer-controlled milestone, creator <login>; description editor not recorded` unless a
  maintainer says who wrote it.
- `Observed` is the date the agent read the source. The edit or approval date stays `unknown` until
  a maintainer states it; `updated_at` establishes neither.
- `Scope` quotes the wording that bounds the row. A row never widens past that wording.
- A change appends a row naming the row it supersedes. `ruled out` records reason, decider and date.
  Old rows keep their place; nothing is deleted.
- An `approved` row carries an issue selection only when the maintainer named the issues. Otherwise
  the selection is a candidate.

### Candidates

- Every candidate states its consequence or cost and what blocks it. Issue inclusion stays a
  proposal until a maintainer accepts it; refinement order is a recommendation.
- Labels, assignments and milestone contents stay untouched without separate authorization, and an
  authorized write records its before and after.

## Decision map

One map owns one bounded destination. One decision lives in one place: its ticket or question line.
The map is an index and repeats only a one-line gist with a link.

A map is optional. A milestone never requires one: its description is direction and its membership
is a delivery fact, and neither is a route. Chart a map when one initiative has a named destination
and an unclear route across sessions.

### Sections

```
## Destination
## Notes
## Decisions so far
## Not yet specified
## Out of scope
## Frontier
```

- **Destination** — one or two lines fixing the scope, marked
  `confirmed by <owner>, <date>` or `proposed — awaiting confirmation`. Every question is measured
  against it.
- **Notes** — domain context, sources, standing preferences. No build authority.
- **Decisions so far** — one line per resolved decision:
  `- <name> — <answer>; decided by <owner>, <date>; source <link>; revises <earlier name>`.
  Attribution that does not exist reads `decided by: not recorded` and stays that way.
- **Not yet specified** — the fog: in-scope questions the agent cannot state sharply yet.
- **Out of scope** — work past the destination, with the reason and the decider. A question
  resolved as out of scope closes and leaves one line here; it never graduates.
- **Frontier** — open decision questions and investigations, each marked `human` or `research`,
  with the blocking dependency named when it cannot resolve yet.

### Decision questions

```
## Question
<the decision this question resolves>

## Resolves by
<human answer, or research already done and linked>
```

A question asks whether, what or which. A ticket that reads "build the X" is implementation work: it
belongs in the handoff, not on the map. Research may run AFK; a human product question resolves only
through a human answer, and an agent answering its own question has broken the contract.

Fog or question is decided by sharpness now, not answerability now: a question that reads clearly is
a frontier item even when blocked; a question that cannot be phrased sharply is a fog line. One
fog patch may graduate into several questions, or none.

### Where a map lives

A draft map is delivered in the answer or a local file. A tracker map needs explicit maintainer
authorization; it then becomes one map issue with child decision questions, blocking links between
them, and no readiness label on a question. Refer to questions by name; an id rides inside the name.
Existing repository labels stay; this contract adds none.

### No-fog bypass

An empty **Not yet specified** section is not enough. Bypass the map only when the task is clear
enough for one session: one bounded outcome, no unresolved decision question, no open investigation
and no unresolved scope question. Report that and hand off without a map.

No fog with several sharp, unresolved decision questions is still a multi-session effort: chart the
map and resolve one decision per session even though **Not yet specified** is empty. Skinning a
decision map onto a clear single-session task adds rounds and no decisions.

## Cleared-map handoff

When every map item is closed the map is done: no in-scope fog, decision question or investigation
remains open. Each item is resolved with an answer and its source, ruled out of scope or superseded
with a decider, or carried into the handoff as a named residual unknown with an owner. An empty
**Frontier** alone does not clear the map while fog remains.

It hands off a G1 specification input:

- user problem, and who has it
- affected behavior, in scope and explicitly out of scope
- compatibility, constraints and dependencies
- observable acceptance criteria
- negative-path and test expectations
- proposed risk level L0–L3 with rationale and the evidence tier that level needs
- unresolved unknowns with their owner, or `none`
- **human acceptance gate** — the maintainer sets `ready-for-agent` or `ready-for-human` and accepts
  scope. The agent proposes these fields and stops there.

`decent-refine` is not a prerequisite. The block above is readable and actionable on its own, so the
handoff works while that skill does not exist. Notes never authorize implementation here or
downstream; the handoff stops at the gate.
