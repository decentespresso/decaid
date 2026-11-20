# #1205 Deliverable B — evidence-completeness validator

## Scope

Deliverable B adds a small standard-library Python advisory parser for PR descriptions. It checks field presence and obvious internal consistency only; it does not verify behavior, linked artifacts, screenshots, hardware, video, or claims. It must not change the existing contributor policy, PR template, workflow gates, or branch rules. The parser accepts a body file plus optional PR head SHA, or safely extracts those values from a GitHub event JSON file.

The validator reports actionable field names and severity, never raw body text, URLs, snippets, credentials, or interpolated input. Findings are advisory and exit zero; malformed input, unsupported event shapes, and setup/I/O failures have a distinct nonzero exit.

## Design

- Keep parsing line-oriented and dependency-free. Heading text, spacing, Markdown tables, `<details>` blocks, and links are treated as layout variants rather than fixed section positions.
- Require or warn on: linked issue or explicitly permitted maintainer/automation exemption; one concrete L0–L3 risk and rationale; substantive acceptance-criterion/status/evidence rows when criteria are declared; the author’s `Verified commit SHA`; environment/platform (or proportionate `N/A`); exact commands and results; explicit limitations including `None`/`N/A`; and the existing `contributor-responsibility` marker.
- Treat copied template placeholders, empty rows, unchecked markers, and bare links as missing or uncertain evidence. A stale author SHA compared with the PR head is a review-needed warning. Explicitly scoped older evidence receives a scoped-reuse warning; reviewer-reviewed and combined-integration SHAs never substitute for author-tested SHA.
- Handle draft, legacy, external, missing-environment, and exempt PRs proportionately: findings are advisory, and no evidence gap becomes a required failure. No online verification is performed.
- CLI input is `--body`, optional `--head-sha`, or `--event`; event JSON is parsed with `json.load`, with safe type checks and no assumption that command output is pure JSON. The output is fixed diagnostic text or a bounded summary and is safe for untrusted PR data.

## Tests and fixtures

`tool/ci/check_pr_evidence_test.py` follows the repository’s `unittest` style. Tests cover complete valid bodies, each field independently missing/placeholder, stale SHA and scoped older evidence, role confusion, headings/order/spacing and closed details, exemptions, copied templates, legitimate `N/A`, draft/legacy/external cases, malformed and type-mismatched event JSON, and secret-canary non-disclosure. Public sanitized fixtures record source URL, collection time, source head SHA, and sanitation notes without API dumps or personal metadata. The fixture corpus includes the requested L0 #1210, L1 #1213, L2 #1198, L3 #1182/#1188, layered #1220, and representative pre-template, external, draft, missing-environment, partial, and N/A bodies where publicly accessible.

## Verification and pilot

Run `python3 tool/ci/check_pr_evidence_test.py` while iterating, capturing a real red run before implementation and a green run after implementation. Run the CLI against every sanitized fixture and manually classify expected findings before comparing actual output. Report counts, false-positive definition, missed findings, and limits honestly; absent data remains `not measured`. Although this is a Python-only change, the repository's required final verification still includes `flutter analyze` and the full `flutter test` suite; those gates are owned by the parent on a clean candidate.

## Integration proposal

After parser stabilization, the smallest integration is one independent nonblocking workflow job that reads the pull-request event body through a file-safe path, emits a fixed job summary, and never gates existing jobs or alters external-contributor policy. The existing tools job may also run the focused unittest command; neither invocation changes required checks or policy authority.
