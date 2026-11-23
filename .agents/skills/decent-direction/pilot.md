# Direction pilot — live 0.9.4 milestone

- **Decision:** **needs human validation** — the 0.9.4 direction is observed and attributed; the issue choices and the driver condition need a maintainer answer.
- **Why:** `approved` — 0.9.4 description "Additional API hardening. Driver runtime improvements if needed." (creator `tadelv`, observed 2026-11-23, edit date unknown); `candidate` — #1135, #1110, #1192 fit, #925 stays with 0.10.0; `unknown` — item list, driver condition, and #1141/#1078 membership.
- **Next action:** Maintainer — name 0.9.4's API-hardening items and whether the driver condition applies, or update the description to say so.
- **Confidence / limits:** live public reads 2026-11-23; docs at `1d74fbf`; an observation date is not an edit or approval date; effort `not measured`.
- **Details:** collapsed below.

<details>
<summary>Layer 2 — sources, snapshot and proposed issue choices</summary>

## Sources

| Source | Establishes | Read |
| --- | --- | --- |
| [Milestone 0.9.4](https://github.com/decentespresso/decaid/milestone/10) | Description "Additional API hardening. Driver runtime improvements if needed."; creator `tadelv`; 3 open, 2 closed; created 2026-11-18; `updated_at` 2026-11-23T15:09:26Z is neither an edit nor an approval date | 2026-11-23 |
| [Milestone 0.10.0](https://github.com/decentespresso/decaid/milestone/7) | "Decent Backend sync (anchor B): TLS/HTTPS listener, auth redirect, resource fallback, plugin certs. Design-first: open the sync-contract discussion before scheduling." | 2026-11-23 |
| [Milestone 0.9.3](https://github.com/decentespresso/decaid/milestone/9) | No description; open with #1192 after release `v0.9.3` was published 2026-11-23 | 2026-11-23 |
| [`doc/Api.md` § Deliberate limits](../../../doc/Api.md#deliberate-limits-of-the-setting) | Plain HTTP on port 8080 exposes bearer tokens; HTTPS is #925, optional full REST/WS authentication is #1135 | `1d74fbf` |
| [`doc/RELEASE.md` § 0.9.3 upgrade](../../../doc/RELEASE.md#093-upgrade-extension-management-protection-becomes-opt-in) | Extension-management protection is opt-in; the café hardening and provisioning guide is #1192 and forthcoming | `1d74fbf` |
| Issues [#1135](https://github.com/decentespresso/decaid/issues/1135), [#1110](https://github.com/decentespresso/decaid/issues/1110), [#1192](https://github.com/decentespresso/decaid/issues/1192), [#925](https://github.com/decentespresso/decaid/issues/925), [#1141](https://github.com/decentespresso/decaid/issues/1141), [#1078](https://github.com/decentespresso/decaid/issues/1078) | State, labels and milestone shown in the candidate table | 2026-11-23 |

## Approved direction — inside its stated scope

| Status | Statement | Scope | Source | Observed | Decided by | Edit or approval date | Supersedes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `approved` | 0.9.4 carries additional API hardening | Subject only: no issue list, no endpoint list | [milestone 0.9.4](https://github.com/decentespresso/decaid/milestone/10) description | 2026-11-23 | maintainer-controlled milestone, creator `tadelv`; description editor `not recorded` | `unknown` | — |
| `approved` | Driver runtime improvements are in 0.9.4 only if needed | The "if needed" condition is unresolved; item unnamed | same description | 2026-11-23 | same | `unknown` | — |
| `approved` | 0.10.0 carries the TLS/HTTPS listener and auth redirect, design-first | Sync-contract discussion precedes scheduling | [milestone 0.10.0](https://github.com/decentespresso/decaid/milestone/7) description | 2026-11-23 | maintainer-controlled milestone, creator `tadelv`; description editor `not recorded` | `unknown` | — |

The description sets direction, not an issue selection. Nothing above approves a specific item, and
"if needed" stays a condition until a maintainer answers it.

## Candidate — proposed issue choices, not assignments

| Choice | Fits because | Consequence or cost | Owner or blocker |
| --- | --- | --- | --- |
| Add #1135 optional REST/WS authentication to 0.9.4 | Full API authentication is hardening of the API surface | L3 authorization evidence; tokenless LAN clients need a compatibility answer | `needs-refinement`; no milestone; maintainer accepts scope |
| Keep #1110 WebSocket lifecycle events in 0.9.4 and refine it first | Already in the milestone; extends the API surface | Versioned public event contract; `needs-triage` and `needs-refinement` both present | Maintainer refines; readiness unset |
| Re-home #1192 café hardening and provisioning guide to 0.9.4 | Documents the hardening a shared device needs | It sits in the published 0.9.3 milestone; no owner recorded | Owner `not recorded`; a move needs authorization |
| Leave #925 TLS listener in 0.10.0 | 0.10.0's description names it, design-first | Pulling it forward would add L3 transport scope before the design-first discussion; the description does not prohibit earlier work, so it needs maintainer scope and scheduling acceptance | Maintainer decision; no move proposed |

No label, assignment or milestone content is changed by this pilot.

## Unknown and conflicts

- Which items count as "additional API hardening" in 0.9.4. Owner: maintainer.
- Whether the driver condition is met, and which driver behavior it names. Owner: maintainer.
- #1078 scale reconnection is open in 0.9.4 and may fit the unresolved "if needed" driver
  condition. Whether that condition covers it is unknown, so the pilot neither includes nor excludes
  it and claims no stale membership. Owner: maintainer.
- #1141 onboarding is open in 0.9.4 and no relationship between it and either description sentence is
  established; its membership is not shown to be stale or wrong. Owner: maintainer.
- 0.9.3 stays open with #1192 after its release: stale delivery state, not direction.
- Description editor and edit or approval date are `not recorded`; `updated_at` is neither.

## Provenance and revision

No earlier 0.9.4 description was observed, so no superseded row exists and no history is invented.
An unchanged re-read adds nothing. A later run that reads different text quotes it, dates it by that
run's observation, and names the row above under **Supersedes**, leaving the old row readable. A
maintainer ruling the theme out gets a `ruled out` row with reason, decider and date.

Conditional walkthrough: if the description became "API hardening: #1135 authentication only", #1135
moves from candidate to approved against that source and the first row becomes superseded. No such
edit is observed.

</details>

<details>
<summary>Optional decision map, scenario checks and measurement</summary>

## Optional decision map

Optional: a milestone never requires a map, and two sharp decisions do not need one either. If a
maintainer wants the 0.9.4 route charted, it starts like this. Every line below is a proposal.

```
## Destination
proposed — awaiting confirmation: which API-hardening decisions 0.9.4 settles.

## Notes
Public sources only. No build authority; implementation waits for a G1-accepted issue.

## Decisions so far
- none resolved — no maintainer answer recorded.

## Not yet specified
- The exposure model the hardening targets: home LAN, shared café device, or remote clients.

## Out of scope
none ruled yet.

## Frontier
| Question | Resolves by |
| Which of authentication (#1135), transport confidentiality (#925) and documentation (#1192) is 0.9.4 hardening? | human |
| Which driver runtime behavior, if any, meets "if needed"? | human |
| Which REST/WS endpoints lack authentication today? | research (AFK) — `doc/Api.md` answers it |
```

Sharp, blocked questions sit on the Frontier, not in fog; fog is a question that cannot be phrased
sharply yet. Empty fog alone does not make an effort single-session. Resolution, scope rulings and
residuals, not an empty Frontier, clear the map; see
[`contracts.md#cleared-map-handoff`](contracts.md#cleared-map-handoff) for the standalone G1 handoff.

## Scenario checks

| Case | Expected and where it shows |
| --- | --- |
| Live broad description honored | Approved rows quote the 0.9.4 description verbatim; no approval beyond it |
| Conditional stays conditional | "if needed" appears as scope plus an open question, never as approved work |
| Issue choices are not assignments | Candidate table only; no label, milestone or assignment change |
| Blank description | 0.9.3 has none: its direction is `unknown`, not inferred from membership |
| Later placement is not exclusive | 0.10.0 names TLS, design-first; #925 stays a 0.10.0 candidate and earlier inclusion is recorded as needing maintainer scope and scheduling acceptance, not as a contradiction |
| Membership stays uncertain | #1078 may fit the unresolved driver condition and #1141's relationship is unestablished; neither is called stale or in error |
| Stale delivery state | #1192 sits in the published 0.9.3 milestone; recorded, not moved |
| Unattributed description | Creator and description editor are separate fields; editor `not recorded` |
| Unknown history | No superseded row invented; only an observed change creates one |
| Revision or rejection | Conditional walkthrough above; `ruled out` keeps reason, decider and date |

These are text-level checks a reader can reproduce. They do not prove that a future agent follows
the skill, and no live maintainer session produced decisions.

## Measurement

| Metric | Value |
| --- | --- |
| Maintainer minutes | not measured |
| Extra questions or rounds | not measured |
| Incorrect dispositions | not measured |
| Unnecessary issues | 0 created — no tracker write was authorized |

</details>
