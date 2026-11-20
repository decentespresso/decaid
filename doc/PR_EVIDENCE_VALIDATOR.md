# PR evidence validator (advisory)

`tool/ci/check_pr_evidence.py` checks PR evidence **presence and obvious consistency**, not truthfulness. It cannot establish that a command ran, that linked proof is accessible, or that a screenshot, video, hardware claim or behavior is true. No finding authorizes acceptance or merge.

## Local use

```sh
python3 tool/ci/check_pr_evidence.py --body path/to/pr-body.md --head-sha <40-character-head>
python3 tool/ci/check_pr_evidence.py --event path/to/pull-request-event.json
python3 tool/ci/check_pr_evidence_test.py
```

With no source argument, the CLI reads `GITHUB_EVENT_PATH`. An explicit `--head-sha` overrides the head consistently for body, explicit-event and default-event inputs; empty or malformed overrides exit 2. Event JSON supplies body, head, draft state, author association and bot/user type. Trusted metadata permits existing maintainer/automation issue exemptions; an external self-declared exemption does not. This check does not query issue acceptance or replace Contribution policy.

Evidence findings exit **0**. Invalid input/types/encoding, unreadable files, missing input and unknown/conflicting CLI arguments exit **2** with fixed diagnostics. Unexpected code failures remain errors. Output never copies body text, URLs, SHA values or arbitrary snippets. Sanitizing argparse errors is local CLI hardening, not evidence of a hosted-CI injection: the job passes no body on argv. The parser and tests use only the Python standard library.

## Recognized evidence and limits

Checks cover an issue reference or permitted exemption; L0–L3 risk and rationale; criterion/status/evidence rows; author-tested full SHA; environment/platform; commands/results; declared limitations, including explicit `None`/`N/A`; and the existing anchored checked responsibility marker. Placeholders and copied empty rows are not evidence. Consistent repeated risk fields are allowed; conflicting tiers produce an advisory.

Shared section extraction retains child headings until a peer or higher-level heading. Evidence may be in closed details, field lists, nested Verification sections or prose. Explicit failed results still count as result presence, never success. Clear full-SHA built/deployed claims in author verification count as fingerprint presence; reviewer/CI/integration fingerprints do not substitute. Explicit author-labelled fingerprints also survive joint author/reviewer headings; generic verified fingerprints in reviewer-only/CI/integration sections do not become author evidence. A fully visible 40-hex link caption is a directly stated fingerprint; a hash only in a hidden link destination is not. Older author evidence produces a review-needed warning, including scoped reuse, not rejection.

This is intentionally generous but bounded recognition, not a Markdown implementation, general policy engine or tense interpreter. It can miss unfamiliar wording or accept an imprecise declaration. For risk rationale, use an inline `Why this level: ...` value or an inline explanation after the tier; a continuation after an empty rationale label can receive an advisory. An environment statement such as no hardware exercised can also declare a limitation without a separate limitations field. For checks, fingerprint/environment/limitations metadata, field labels and template instructions do not fill an empty command field. Genuine observed narrative elsewhere in nested Verification/details can still supply checks despite that blank field. The tested clear Plan/Will/Run-with-expected-result forms are excluded; this is not a universal claim to understand future versus completed work. An explicit command with `not run (unavailable)` is a status declaration, not evidence of execution. Link-only evidence remains a gap for manual inspection, not verified linked content. Draft, legacy, external and missing-environment bodies receive nonblocking diagnostics; the check cannot infer their behavior, approve exemptions or waive existing hard gates. Criterion checks inspect the supplied matrix, not the issue's actual completeness. Author SHAs must contain all 40 hexadecimal characters; the event head alone supplies no author evidence.

## Public-fixture pilot

Nine unchanged public bodies are stored under `tool/ci/fixtures/pr_evidence/`: L0 #1210, L1 #1213, L2 #1198, L3 #1182/#1188, layered #1220, pre-template #1209, external draft #859 and draft #880. Each records its live collection timestamp, source URL/head, association/draft/type, and original/body digests. Safe public links are retained. No body sanitation was needed in these snapshots; historical state can differ from the live API collection.

`expectations.json` records manually maintained presence judgments, verbatim supporting spans and reasons for missing fields. Exact labels are not a condition of presence. The corrected classification has **47 present and 25 absent fields** across 72 observations: #1209's declared JSON-validation and release-ZIP confirmation count as check/results, like qualitative inspection in #1210. No platform is inferred from JSON validation, and future smoke instructions remain distinct from observed checks.

Earlier label-restricted zero-FP claims were invalid. The subsequent 46/26 classification also wrongly omitted #1209's qualitative results; sample agreement did not reveal that mistaken expectation. After that panel-settled correction, the local comparison observed 0 false-positive omissions among 47 manually present fields and 0 missed omissions among 25 absent fields. These revised convenience-sample judgments do not establish a population rate, globally correct parsing, independent collection order, benefit estimate or truthfulness.

The original seven-field probe currently recognizes all seven nested/prose declarations. A separate unchanged panel probe reproduced seven failures among ten controls/counterexamples for CLI overrides/diagnostics, SHA visibility/roles and #1209 checks; it now passes all ten. Committed regressions cover those cases, metadata, source spans and fixture digests. Historical local missing-module and unchecked-checkbox RED artifacts are distinct from these probes and are not final-candidate gates. Reviewer effort, regressions, time savings, inaccessible-link truth and actual execution remain **not measured**.

## CI and final verification

This change adds one unit-test invocation to the existing tools job and a separate **nonblocking PR evidence advisory** job. The advisory reads event JSON as data, writes the fixed report to the job summary, has no dependency edges, and distinguishes setup errors from findings. Existing permissions, triggers, Contribution policy and Flutter/Linux jobs are unchanged. No new required check or branch-rule change is introduced.

Local Python results do not replace repository gates. Final `flutter analyze` and full `flutter test`, exact-candidate receipts and independent review are still required on a clean isolated candidate before claiming completion. No running-app or physical-device test is implied by this parser-only change.
