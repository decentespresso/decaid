import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import check_pr_evidence


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "tool" / "ci" / "check_pr_evidence.py"


VALID_BODY = """## Summary
A contained parser change.

## Linked Issue
Related #1205

## Risk and Acceptance Criteria
- **Risk level:** L1 — isolated logic; the parser has no runtime behavior.
- **Why this level:** It changes contained validation logic only.

| Issue acceptance criterion | Status (verified / not tested / blocked) | Test, scenario or artifact |
| --- | --- | --- |
| Required fields are reported | verified | `python3 tool/ci/check_pr_evidence_test.py` — passed |

<details>
<summary>Layer 2 — technical evidence</summary>

- **Verified commit SHA:** `0123456789abcdef0123456789abcdef01234567`
- **Environment:** Ubuntu 24.04, Python 3.11, not exercised on hardware.
- **Commands and results:** `python3 tool/ci/check_pr_evidence_test.py` — 18 tests passed (exit 0).
- **Not tested / limitations / human validation needed:** None.

</details>

## Contributor Responsibility
- [x] I have reviewed and understand all changes in this PR and take responsibility for their correctness, security, behavior, licensing, and provenance, including any AI-assisted or AI-generated work. <!-- contributor-responsibility -->
"""


class CheckPrEvidenceTest(unittest.TestCase):
    def assert_codes(self, body, expected, head_sha=None):
        report = check_pr_evidence.inspect_body(body, head_sha=head_sha)
        codes = {finding["code"] for finding in report["findings"]}
        for code in expected:
            self.assertIn(code, codes, msg=f"missing {code}: {report}")
        return report

    def test_complete_body_has_no_required_field_findings(self):
        report = check_pr_evidence.inspect_body(VALID_BODY)
        codes = {finding["code"] for finding in report["findings"]}
        self.assertEqual(codes, set())

    def test_fenced_risk_examples_do_not_override_real_declarations(self):
        for fence in ("```", "~~~", "`````", "~~~~"):
            with self.subTest(fence=fence):
                body = VALID_BODY + f"\n{fence}markdown\nRisk level: L0 / L1 / L2 / L3\n{fence}\n"
                self.assertEqual(check_pr_evidence.inspect_body(body)["findings"], [])

    def test_fenced_examples_cannot_supply_any_required_evidence(self):
        expected = {"issue_reference", "risk_rationale", "criteria_evidence", "author_tested_sha", "environment", "commands_results", "limitations", "responsibility_marker"}
        for fence in ("```", "~~~", "`````", "~~~~"):
            with self.subTest(fence=fence):
                report = check_pr_evidence.inspect_body(f"{fence}markdown\n{VALID_BODY}\n{fence}\n")
                self.assertEqual({item["code"] for item in report["findings"]}, expected)
                self.assertIsNone(report["author_tested_sha"])

    def test_html_comments_cannot_supply_evidence(self):
        for body in ("<!-- Related #1205 -->", "<!--\nRelated #1205\nRisk level: L1 — isolated tooling\n-->"):
            with self.subTest(body=body):
                self.assert_codes(body, {"issue_reference", "risk_rationale"})
        report = check_pr_evidence.inspect_body("<!--\n" + VALID_BODY + "\n-->")
        self.assertEqual(len(report["findings"]), 8)
        self.assertIsNone(report["author_tested_sha"])

    def test_real_issue_and_risk_survive_commented_examples(self):
        body = "<!--\nRelated #9999\nRisk level: L0 / L1 / L2 / L3\n-->\n" + VALID_BODY
        self.assertEqual(check_pr_evidence.inspect_body(body)["findings"], [])

    def test_real_responsibility_marker_survives_comment_filtering(self):
        body = VALID_BODY + "\n<!-- unrelated multiline\ncomment -->\n"
        self.assertNotIn("responsibility_marker", {item["code"] for item in check_pr_evidence.inspect_body(body)["findings"]})
        marker = "- [x] I have reviewed the changes <!-- contributor-responsibility -->"
        for fence in ("```", "~~~"):
            with self.subTest(fence=fence):
                self.assert_codes(f"{fence}markdown\n{marker}\n{fence}", {"responsibility_marker"})

    def test_details_preserve_real_matrix_inline_commands_and_marker(self):
        body = "<details>\n<summary>Verification</summary>\n\n" + VALID_BODY + "\n</details>\n"
        self.assertEqual(check_pr_evidence.inspect_body(body)["findings"], [])

    def test_only_unfenced_author_fingerprint_is_recognized(self):
        real = "0123456789abcdef0123456789abcdef01234567"
        example = "a" * 40
        for fence in ("```", "~~~", "````"):
            with self.subTest(fence=fence):
                body = f"{fence}markdown\nAuthor-tested SHA: {example}\n{fence}\n" + VALID_BODY
                report = check_pr_evidence.inspect_body(body, head_sha=real)
                self.assertEqual(report["author_tested_sha"], real)
                self.assertEqual(report["findings"], [])

    def test_unclosed_fences_hide_the_remaining_example(self):
        expected = {"risk_rationale", "criteria_evidence", "author_tested_sha", "environment", "commands_results", "limitations", "responsibility_marker"}
        for fence in ("```", "~~~", "`````"):
            with self.subTest(fence=fence):
                report = check_pr_evidence.inspect_body(f"Related #1205\n{fence}markdown\n{VALID_BODY}")
                self.assertEqual({item["code"] for item in report["findings"]}, expected)
                self.assertIsNone(report["author_tested_sha"])

    def test_fence_closers_require_matching_character_and_minimum_length(self):
        for opening, shorter, wrong, closing in (("````", "```", "~~~~", "`````"), ("~~~~", "~~~", "````", "~~~~~")):
            with self.subTest(opening=opening):
                body = f"{opening}markdown\n{shorter}\nRisk level: L2 — example\n{wrong}\nRisk level: L3 — example\n{opening}not-a-closing-label\nRisk level: L0 — example\n{closing}\n" + VALID_BODY
                self.assertEqual(check_pr_evidence.inspect_body(body)["findings"], [])

    def test_comment_and_fence_delimiters_do_not_leak_across_contexts(self):
        for prefix in ("<!--\n```markdown\n-->\n", "```html\n<!--\n```\n"):
            with self.subTest(prefix=prefix):
                self.assertEqual(check_pr_evidence.inspect_body(prefix + VALID_BODY)["findings"], [])

    def test_inline_command_comment_literals_do_not_hide_real_evidence(self):
        body = "Commands and results: `python -c 'print(\"<!--\")'` — passed\n" + VALID_BODY
        self.assertEqual(check_pr_evidence.inspect_body(body)["findings"], [])

    def test_fenced_scope_examples_do_not_scope_real_stale_evidence(self):
        body = VALID_BODY + "\n```markdown\nAuthor evidence is reused for unaffected documentation paths.\n```\n"
        report = check_pr_evidence.inspect_body(body, head_sha="b" * 40)
        stale = [item for item in report["findings"] if item["code"] == "stale_evidence"]
        self.assertEqual(len(stale), 1)
        self.assertFalse(stale[0]["scoped_reuse"])

    def test_each_required_field_is_checked(self):
        cases = {
            "issue": ("Related #1205", "issue_reference"),
            "risk": ("**Risk level:** L1", "risk_rationale"),
            "criteria": ("Required fields are reported", "criteria_evidence"),
            "sha": ("**Verified commit SHA:** `0123456789abcdef0123456789abcdef01234567`", "author_tested_sha"),
            "environment": ("**Environment:** Ubuntu 24.04, Python 3.11, not exercised on hardware.", "environment"),
            "commands": ("**Commands and results:** `python3 tool/ci/check_pr_evidence_test.py` — 18 tests passed (exit 0).", "commands_results"),
            "limitations": ("**Not tested / limitations / human validation needed:** None.", "limitations"),
            "responsibility": ("<!-- contributor-responsibility -->", "responsibility_marker"),
        }
        for name, (text, code) in cases.items():
            with self.subTest(name=name):
                body = VALID_BODY.replace(text, "")
                if name == "limitations":
                    body = body.replace("not exercised on hardware", "local automated run")
                self.assert_codes(body, {code})

    def test_placeholder_and_empty_rows_are_not_evidence(self):
        body = VALID_BODY.replace(
            "Related #1205", "Fixes #"
        ).replace(
            "**Risk level:** L1 — isolated logic; the parser has no runtime behavior.",
            "**Risk level:** L0 / L1 / L2 / L3",
        ).replace(
            "**Why this level:** It changes contained validation logic only.",
            "**Why this level:**",
        ).replace(
            "| Required fields are reported | verified | `python3 tool/ci/check_pr_evidence_test.py` — passed |",
            "| | | |",
        ).replace(
            "`0123456789abcdef0123456789abcdef01234567`",
            "(exact head SHA these results apply to)",
        ).replace(
            "Ubuntu 24.04, Python 3.11, not exercised on hardware.",
            "(OS and platform; simulated or physical device; relevant flags; N/A if nonbehavioral)",
        ).replace(
            "`python3 tool/ci/check_pr_evidence_test.py` — 18 tests passed (exit 0).",
            "",
        ).replace("None.", "(write None if none)")
        report = check_pr_evidence.inspect_body(body)
        codes = {finding["code"] for finding in report["findings"]}
        self.assertTrue({"issue_reference", "risk_rationale", "criteria_evidence", "author_tested_sha", "environment", "commands_results", "limitations"} <= codes)

    def test_risk_requires_one_concrete_tier_and_substantive_rationale(self):
        for risk in ("L0 or L3 — TBD", "L0 / L1 / L2 / L3"):
            with self.subTest(risk=risk):
                body = VALID_BODY.replace(
                    "**Risk level:** L1 — isolated logic; the parser has no runtime behavior.",
                    f"**Risk level:** {risk}",
                )
                self.assert_codes(body, {"risk_rationale"})
        body = VALID_BODY.replace(
            "**Why this level:** It changes contained validation logic only.",
            "**Why this level:** TODO",
        )
        self.assert_codes(body, {"risk_rationale"})

    def test_every_populated_criterion_row_must_be_complete(self):
        body = VALID_BODY.replace(
            "| Required fields are reported | verified | `python3 tool/ci/check_pr_evidence_test.py` — passed |",
            "| Required fields are reported | verified | `python3 tool/ci/check_pr_evidence_test.py` — passed |\n| <criterion, from the issue> | verified | TODO |",
        )
        self.assert_codes(body, {"criteria_evidence"})

    def test_reviewer_tested_sha_alias_does_not_satisfy_author_sha(self):
        body = VALID_BODY.replace(
            "**Verified commit SHA:** `0123456789abcdef0123456789abcdef01234567`",
            "**Reviewed tested SHA:** `0123456789abcdef0123456789abcdef01234567`",
        )
        self.assert_codes(body, {"author_tested_sha"})

    def test_limits_link_alone_requires_actionable_gap(self):
        body = VALID_BODY.replace(
            "**Not tested / limitations / human validation needed:** None.",
            "**Not tested / limitations / human validation needed:** [technical report](https://example.invalid/private?token=synthetic-canary)",
        )
        self.assert_codes(body, {"limitations"})
        output = check_pr_evidence.render_report(check_pr_evidence.inspect_body(body))
        self.assertNotIn("example.invalid", output)
        self.assertNotIn("synthetic-canary", output)

    def test_external_exemption_requires_trusted_event_metadata(self):
        body = VALID_BODY.replace("Related #1205", "N/A — maintainer repository-maintenance exemption")
        self.assert_codes(body, {"issue_reference"})
        report = check_pr_evidence.inspect_body(
            body,
            external=True,
            association="MEMBER",
            author_type="User",
        )
        self.assertNotIn("issue_reference", {item["code"] for item in report["findings"]})
        linked_na = VALID_BODY.replace("Related #1205", "N/A")
        self.assert_codes(linked_na, {"issue_reference"})
        report = check_pr_evidence.inspect_body(linked_na, association="MEMBER", author_type="User")
        self.assertNotIn("issue_reference", {item["code"] for item in report["findings"]})

    def test_canonical_g3_headings_and_verification_section_are_supported(self):
        body = """## G3 technical evidence

### Scope and risk
Related #1205; L0 — documentation only.

### Acceptance matrix
| Criterion | Status | Evidence |
| --- | --- | --- |
| Documentation is accurate | verified | inspected diff |

### Verification fingerprint
Author-tested SHA: 0123456789abcdef0123456789abcdef01234567
Environment: Ubuntu, not exercised.

### Checks
`true` — passed (exit 0)

### Known gaps
None.

- [x] responsibility acknowledged <!-- contributor-responsibility -->
"""
        report = check_pr_evidence.inspect_body(body)
        self.assertEqual(report["findings"], [])

    def test_scoped_stale_evidence_requires_author_path_scope(self):
        head = "a" * 40
        body = VALID_BODY + "\nThis file is unchanged.\n"
        report = check_pr_evidence.inspect_body(body, head_sha=head)
        stale = [item for item in report["findings"] if item["code"] == "stale_evidence"]
        self.assertEqual(len(stale), 1)
        self.assertFalse(stale[0]["scoped_reuse"])

    def test_fixture_expectations_are_executed_as_regression_tests(self):
        fixture_dir = ROOT / "tool" / "ci" / "fixtures" / "pr_evidence"
        expectations = json.loads((fixture_dir / "expectations.json").read_text(encoding="utf-8"))
        for filename, expected in expectations["expected_findings"].items():
            with self.subTest(filename=filename):
                fixture = json.loads((fixture_dir / filename).read_text(encoding="utf-8"))
                digest = hashlib.sha256(fixture["body"].encode("utf-8")).hexdigest()
                self.assertEqual(digest, fixture["source_body_sha256"])
                self.assertEqual(digest, fixture["sanitized_body_sha256"])
                for span in expectations["source_spans"][filename].values():
                    self.assertIn(span, fixture["body"])
                report = check_pr_evidence.inspect_body(
                    fixture["body"],
                    head_sha=fixture.get("source_head_sha"),
                    draft=fixture.get("draft", False),
                    external=fixture.get("external", False),
                    association=fixture.get("author_association"),
                    author_type=fixture.get("author_type"),
                )
                self.assertEqual(
                    {finding["code"] for finding in report["findings"]},
                    set(expected),
                )

    def test_mixed_role_hash_line_uses_only_author_labeled_sha(self):
        body = VALID_BODY.replace(
            "**Verified commit SHA:** `0123456789abcdef0123456789abcdef01234567`",
            "Reviewer-reviewed SHA: fedcba9876543210fedcba9876543210fedcba98; Verified commit SHA: 0123456789abcdef0123456789abcdef01234567; CI SHA: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        )
        report = check_pr_evidence.inspect_body(body)
        self.assertNotIn("author_tested_sha", {item["code"] for item in report["findings"]})
        self.assertEqual(report["author_tested_sha"], "0123456789abcdef0123456789abcdef01234567")

    def test_author_sha_field_does_not_borrow_a_later_role_hash(self):
        body = VALID_BODY.replace(
            "**Verified commit SHA:** `0123456789abcdef0123456789abcdef01234567`",
            "**Verified commit SHA:** TODO; Reviewer-reviewed SHA: fedcba9876543210fedcba9876543210fedcba98",
        )
        self.assert_codes(body, {"author_tested_sha"})
        report = check_pr_evidence.inspect_body(body)
        self.assertIsNone(report["author_tested_sha"])

    def test_role_hashes_remain_distinct_in_each_order(self):
        for value in (
            "Verified commit SHA: 0123456789abcdef0123456789abcdef01234567; Reviewer-reviewed SHA: fedcba9876543210fedcba9876543210fedcba98",
            "Reviewer-reviewed SHA: fedcba9876543210fedcba9876543210fedcba98; Verified commit SHA: 0123456789abcdef0123456789abcdef01234567",
        ):
            with self.subTest(value=value):
                report = check_pr_evidence.inspect_body(VALID_BODY.replace(
                    "**Verified commit SHA:** `0123456789abcdef0123456789abcdef01234567`",
                    value,
                ))
                self.assertEqual(report["author_tested_sha"], "0123456789abcdef0123456789abcdef01234567")

    def test_reviewer_only_and_integration_hashes_do_not_satisfy_author_sha(self):
        body = VALID_BODY.replace(
            "**Verified commit SHA:** `0123456789abcdef0123456789abcdef01234567`",
            "Reviewer-reviewed SHA: fedcba9876543210fedcba9876543210fedcba98; Combined integration SHA: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        )
        report = check_pr_evidence.inspect_body(body)
        self.assertIsNone(report["author_tested_sha"])
        self.assert_codes(body, {"author_tested_sha"})

    def test_responsibility_marker_requires_anchored_checked_checkbox(self):
        for replacement in (
            "contributor-responsibility [x] is a template example",
            "<!-- contributor-responsibility -->\n- [x] commented example",
            "`- [x] code example <!-- contributor-responsibility -->`",
        ):
            with self.subTest(replacement=replacement):
                self.assert_codes(VALID_BODY.replace(
                    "- [x] I have reviewed and understand all changes in this PR and take responsibility for their correctness, security, behavior, licensing, and provenance, including any AI-assisted or AI-generated work. <!-- contributor-responsibility -->",
                    replacement,
                ), {"responsibility_marker"})

    def test_copied_empty_criterion_row_is_not_ignored(self):
        body = VALID_BODY.replace(
            "| Required fields are reported | verified | `python3 tool/ci/check_pr_evidence_test.py` — passed |",
            "| Required fields are reported | verified | `python3 tool/ci/check_pr_evidence_test.py` — passed |\n| | | |",
        )
        self.assert_codes(body, {"criteria_evidence"})

    def test_fixture_metadata_is_passed_to_inspection(self):
        fixture_dir = ROOT / "tool" / "ci" / "fixtures" / "pr_evidence"
        fixture = json.loads((fixture_dir / "pr-1198-l2.json").read_text(encoding="utf-8"))
        report = check_pr_evidence.inspect_body(
            fixture["body"],
            head_sha=fixture["source_head_sha"],
            draft=fixture["draft"],
            external=fixture.get("external", False),
            association=fixture.get("author_association"),
            author_type=fixture.get("author_type"),
        )
        self.assertNotIn("issue_reference", {item["code"] for item in report["findings"]})

    def test_real_nested_and_prose_evidence_is_present(self):
        directory = ROOT / "tool/ci/fixtures/pr_evidence"
        cases = {
            "pr-1182-l3-a.json": {"environment", "commands_results", "limitations", "author_tested_sha"},
            "pr-859-external-draft.json": {"limitations"},
            "pr-1198-l2.json": {"limitations", "commands_results"},
            "pr-1188-l3-b.json": {"limitations"},
        }
        for filename, present in cases.items():
            with self.subTest(filename=filename):
                fixture = json.loads((directory / filename).read_text(encoding="utf-8"))
                report = check_pr_evidence.inspect_body(
                    fixture["body"], fixture["source_head_sha"],
                    draft=fixture["draft"], association=fixture["author_association"],
                    author_type=fixture["author_type"],
                )
                self.assertFalse(present & {item["code"] for item in report["findings"]})
                if "author_tested_sha" in present:
                    self.assertEqual(report["author_tested_sha"], fixture["source_head_sha"])

    def test_nested_verification_keeps_children_but_not_peer_sections(self):
        body = """## Verification
### Automated
Environment: Windows, Flutter 3.47.9.
`flutter test` — 21 failed (exit 1).
### Smoke
Built and deployed **0123456789abcdef0123456789abcdef01234567** to Android 16.
## Impact
No physical hardware validation.
"""
        report = check_pr_evidence.inspect_body(body)
        codes = {item["code"] for item in report["findings"]}
        self.assertFalse({"environment", "commands_results", "author_tested_sha", "limitations"} & codes)
        outside = body.replace("## Verification", "## Planned work")
        self.assertIn("author_tested_sha", {item["code"] for item in check_pr_evidence.inspect_body(outside)["findings"]})

    def test_narrative_reviewer_ci_and_integration_shas_are_not_author_evidence(self):
        for actor in ("Reviewer", "CI", "Combined integration"):
            body = "## Verification\n" + actor + " built and deployed " + "a" * 40 + ".\n"
            self.assertIsNone(check_pr_evidence.inspect_body(body)["author_tested_sha"])
        for body in (
            "## Reviewer evidence\n### Verification\nBuilt and deployed " + "a" * 40,
            "## Verification\n### Combined integration\nBuilt and deployed " + "a" * 40,
            "## CI\nVerified commit SHA: " + "a" * 40,
        ):
            with self.subTest(body=body):
                self.assertIsNone(check_pr_evidence.inspect_body(body)["author_tested_sha"])

    def test_repeated_consistent_risk_fields_are_not_conflicts(self):
        report = check_pr_evidence.inspect_body(VALID_BODY + "\nRisk level: L1 — isolated logic.\n")
        self.assertNotIn("risk_rationale", {item["code"] for item in report["findings"]})
        report = check_pr_evidence.inspect_body(VALID_BODY + "\nRisk level: L3 — machine control.\n")
        self.assertIn("risk_rationale", {item["code"] for item in report["findings"]})

    def test_prose_environment_requires_platform_not_just_any_verification_text(self):
        body = "## Verification\nValidated the configuration parses as JSON.\n"
        self.assertIn("environment", {item["code"] for item in check_pr_evidence.inspect_body(body)["findings"]})

    def test_link_caption_alone_does_not_declare_limitations(self):
        body = "## Details\n[not run](https://example.invalid/proof)\n"
        self.assertIn("limitations", {item["code"] for item in check_pr_evidence.inspect_body(body)["findings"]})

    def test_environment_can_also_declare_an_explicit_hardware_limit(self):
        body = VALID_BODY.replace("- **Not tested / limitations / human validation needed:** None.\n", "")
        self.assertNotIn("limitations", {item["code"] for item in check_pr_evidence.inspect_body(body)["findings"]})

    def test_template_status_words_do_not_supply_limitations(self):
        template = (ROOT / ".github/pull_request_template.md").read_text(encoding="utf-8")
        self.assertIn("limitations", {item["code"] for item in check_pr_evidence.inspect_body(template)["findings"]})

    def test_command_evidence_uses_visible_text_not_link_destinations(self):
        cases = (
            ("See [report](https://example.invalid/test/pass)", False),
            ("See https://example.invalid/test/pass", False),
            ("See [report][r]\n[r]: https://example.invalid/test/pass", False),
            ("[`flutter test` — passed](https://example.invalid/report)", True),
            ("`flutter test` — failed. See [report](https://example.invalid/opaque)", True),
        )
        contexts = (
            ("## Verification\n", ""),
            ("## Verification\n### Automated\n", ""),
            ("Commands and results: ", ""),
            ("## Verification\nCommands and results: ", ""),
            ("<details>\n<summary>Evidence</summary>\n\n## Verification\n### Automated\nCommands and results: ", "\n</details>"),
        )
        for value, expected in cases:
            for prefix, suffix in contexts:
                with self.subTest(value=value, prefix=prefix):
                    report = check_pr_evidence.inspect_body(prefix + value + suffix)
                    present = "commands_results" not in {item["code"] for item in report["findings"]}
                    self.assertEqual(present, expected)

    def test_command_fields_do_not_borrow_from_metadata_siblings(self):
        metadata = "## Verification\n- **Verified commit SHA:** `" + "a" * 40 + "`\n- **Environment:** Ubuntu\n"
        limits = "\n- **Not tested / limitations / human validation needed:** None\n"
        template = (ROOT / ".github/pull_request_template.md").read_text(encoding="utf-8")
        for body in (
            metadata + "- **Commands and results:**" + limits,
            metadata + "- **Commands and results:** TODO" + limits,
            metadata + "Commands/results: TBD" + limits,
            metadata + "### Checks\n\n## Impact\n`flutter test` — passed\n",
            metadata + limits,
            template,
        ):
            with self.subTest(body=body):
                self.assert_codes(body, {"commands_results"})

    def test_empty_command_field_can_be_supplied_by_genuine_nested_checks(self):
        for wrapper in (False, True):
            body = "## Verification\n### Automated\n`flutter test` — passed\n"
            body += "### Metadata\nVerified commit SHA: `" + "a" * 40 + "`\nEnvironment: Ubuntu\n"
            body += "Commands and results:\nNot tested / limitations / human validation needed: None\n"
            if wrapper:
                body = "<details>\n<summary>Evidence</summary>\n\n" + body + "\n</details>\n"
            with self.subTest(details=wrapper):
                codes = {item["code"] for item in check_pr_evidence.inspect_body(body)["findings"]}
                self.assertNotIn("commands_results", codes)

    def test_command_result_presence_includes_honest_not_run_declarations(self):
        for result in ("passed", "21 failed (exit 1)", "not run (unavailable)"):
            with self.subTest(result=result):
                body = "## Verification\nCommands and results: `flutter test` — " + result
                codes = {item["code"] for item in check_pr_evidence.inspect_body(body)["findings"]}
                self.assertNotIn("commands_results", codes)

    def test_clear_future_commands_are_not_observed_results(self):
        for evidence in (
            "- Plan: run `flutter test` — expect all to pass.",
            "- Plan to run `flutter test` — expected to pass.",
            "- Will run `flutter test` — expect success.",
            "- Run `flutter test` — expect all to pass.",
        ):
            for prefix in ("## Verification\n", "Commands and results:\n"):
                with self.subTest(evidence=evidence, prefix=prefix):
                    self.assert_codes(prefix + evidence, {"commands_results"})

    def test_cli_head_override_is_consistent_for_every_source(self):
        event = {"pull_request": {"body": VALID_BODY, "head": {"sha": "0123456789abcdef0123456789abcdef01234567"}}}
        with tempfile.TemporaryDirectory() as directory:
            event_path = Path(directory) / "event.json"
            body_path = Path(directory) / "body.md"
            event_path.write_text(json.dumps(event), encoding="utf-8")
            body_path.write_text(VALID_BODY, encoding="utf-8")
            env = os.environ.copy()
            env["GITHUB_EVENT_PATH"] = str(event_path)
            for source in ([], ["--event", str(event_path)], ["--body", str(body_path)]):
                for override, expected in ((None, 0), ("b" * 40, 0), ("not-a-sha", 2), ("", 2)):
                    with self.subTest(source=source[:1], override=override):
                        args = source + (["--head-sha", override] if override is not None else [])
                        result = subprocess.run([sys.executable, str(SCRIPT), *args], env=env, capture_output=True, text=True, check=False)
                        self.assertEqual(result.returncode, expected)
                        if override == "b" * 40:
                            self.assertIn("stale_evidence", result.stdout)
                        if override == "not-a-sha":
                            self.assertNotIn(override, result.stdout + result.stderr)

    def test_cli_argument_errors_do_not_echo_untrusted_values(self):
        canary = "https://invalid.example/?token=SYNTHETIC_ARGV_CANARY"
        for args in ([canary], ["--unknown", canary], ["--body", canary, "--event", canary], ["--head-sha"]):
            with self.subTest(args=args[:1]):
                result = subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True, text=True, check=False)
                self.assertEqual(result.returncode, 2)
                self.assertNotIn(canary, result.stdout + result.stderr)
                self.assertNotIn("SYNTHETIC_ARGV_CANARY", result.stdout + result.stderr)

    def test_explicit_author_sha_survives_a_joint_role_heading(self):
        sha = "a" * 40
        for label in ("Author-tested SHA", "Verified author-tested commit SHA", "Author tested SHA", "Verified author tested commit SHA"):
            for heading in ("", "## Author and reviewer evidence\n"):
                with self.subTest(label=label, joint=bool(heading)):
                    body = heading + label + ": " + sha
                    self.assertEqual(check_pr_evidence.inspect_body(body)["author_tested_sha"], sha)
        for body in (
            "## Author and reviewer evidence\nVerified commit SHA: " + sha,
            "## Author and reviewer evidence\n### Reviewer execution\nVerified commit SHA: " + sha,
            "## Reviewer evidence\nVerified commit SHA: " + sha,
        ):
            with self.subTest(body=body):
                self.assertIsNone(check_pr_evidence.inspect_body(body)["author_tested_sha"])

    def test_link_destinations_are_not_author_fingerprints(self):
        visible = "a" * 40
        hidden = "b" * 40
        for label in ("Verified commit SHA", "Author-tested SHA"):
            with self.subTest(label=label):
                linked = label + ": [technical report](https://invalid.example/report/" + hidden + ")"
                self.assertIsNone(check_pr_evidence.inspect_body(linked)["author_tested_sha"])
                self.assertEqual(check_pr_evidence.inspect_body(linked + " " + visible)["author_tested_sha"], visible)
                self.assertEqual(check_pr_evidence.inspect_body(linked + "\nAuthor-tested SHA: " + visible)["author_tested_sha"], visible)

    def test_visible_link_caption_is_a_direct_author_fingerprint(self):
        visible = "a" * 40
        hidden = "b" * 40
        body = "Author-tested SHA: [" + visible + "](https://invalid.example/report/" + hidden + ")"
        self.assertEqual(check_pr_evidence.inspect_body(body)["author_tested_sha"], visible)

    def test_qualitative_checks_require_observed_results_not_future_instructions(self):
        for evidence in (
            "Validated the configuration parses as JSON.",
            "Confirmed the published release includes a ZIP matching the bundler expectations.",
        ):
            with self.subTest(evidence=evidence):
                report = check_pr_evidence.inspect_body("## Verification\n" + evidence)
                self.assertNotIn("commands_results", {item["code"] for item in report["findings"]})
                self.assertIn("environment", {item["code"] for item in report["findings"]})
        for evidence in (
            "Run validation and confirm the archive installs correctly.",
            "Plan to validate the configuration and inspect the release ZIP.",
        ):
            with self.subTest(evidence=evidence):
                self.assert_codes("## Verification\n" + evidence, {"commands_results"})

    def test_real_pretemplate_checks_are_present_without_a_platform(self):
        path = ROOT / "tool/ci/fixtures/pr_evidence/pr-1209-pre-template.json"
        fixture = json.loads(path.read_text(encoding="utf-8"))
        report = check_pr_evidence.inspect_body(fixture["body"], fixture["source_head_sha"], association=fixture["author_association"])
        codes = {item["code"] for item in report["findings"]}
        self.assertNotIn("commands_results", codes)
        self.assertIn("environment", codes)

    def test_invalid_direct_head_sha_is_input_error(self):
        with self.assertRaises(check_pr_evidence.InputError):
            check_pr_evidence.inspect_body(VALID_BODY, head_sha="not-a-sha")

    def test_external_association_event_is_context_but_not_exemption(self):
        event = {
            "pull_request": {
                "body": VALID_BODY.replace("Related #1205", "N/A"),
                "head": {"sha": "a" * 40},
                "draft": True,
                "author_association": "CONTRIBUTOR",
                "user": {"type": "User"},
            }
        }
        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as stream:
            json.dump(event, stream)
            stream.flush()
            values = check_pr_evidence.load_event(Path(stream.name))
        self.assertTrue(values["external"])
        report = check_pr_evidence.inspect_body(
            values["body"],
            head_sha=values["head_sha"],
            draft=values["draft"],
            external=values["external"],
            association=values["association"],
            author_type=values["author_type"],
        )
        self.assertTrue(report["external"])
        self.assertIn("issue_reference", {item["code"] for item in report["findings"]})

    def test_event_metadata_and_types_are_validated(self):
        exemption = VALID_BODY.replace("Related #1205", "N/A — maintainer repository-maintenance exemption")
        event = {
            "pull_request": {
                "body": exemption,
                "head": {"sha": "a" * 40},
                "draft": False,
                "author_association": "MEMBER",
                "user": {"type": "User"},
            }
        }
        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as stream:
            json.dump(event, stream)
            stream.flush()
            values = check_pr_evidence.load_event(Path(stream.name))
        report = check_pr_evidence.inspect_body(
            values["body"],
            head_sha=values["head_sha"],
            association=values["association"],
            author_type=values["author_type"],
        )
        self.assertNotIn("issue_reference", {item["code"] for item in report["findings"]})
        for bad in (
            {"pull_request": {"body": [], "head": {"sha": "a" * 40}}},
            {"pull_request": {"body": VALID_BODY, "head": {"sha": "bad"}}},
            {"pull_request": {"body": VALID_BODY, "head": {"sha": "a" * 40}, "draft": "false"}},
        ):
            with self.subTest(bad=bad):
                with tempfile.NamedTemporaryFile("w", encoding="utf-8") as stream:
                    json.dump(bad, stream)
                    stream.flush()
                    with self.assertRaises(check_pr_evidence.InputError):
                        check_pr_evidence.load_event(Path(stream.name))

    def test_cli_environment_and_invalid_encoding_are_safe(self):
        secret = "synthetic-event-canary-789"
        event = {"pull_request": {"body": "Draft " + secret, "head": {"sha": "a" * 40}, "draft": False}}
        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as stream:
            json.dump(event, stream)
            stream.flush()
            env = os.environ.copy()
            env["GITHUB_EVENT_PATH"] = stream.name
            result = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True, env=env, check=False)
        self.assertEqual(result.returncode, 0)
        self.assertNotIn(secret, result.stdout + result.stderr)
        with tempfile.NamedTemporaryFile("wb") as stream:
            stream.write(b"\xff")
            stream.flush()
            result = subprocess.run([sys.executable, str(SCRIPT), "--event", stream.name], capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("xff", result.stderr + result.stdout)

    def test_workflow_advisory_job_is_independent_and_nonblocking(self):
        workflow = (ROOT / ".github" / "workflows" / "pr-checks.yml").read_text(encoding="utf-8")
        self.assertEqual(workflow.count("python3 tool/ci/check_pr_evidence_test.py"), 1)
        job = workflow.split("  pr-evidence-advisory:\n", 1)[1]
        self.assertIn("uses: actions/checkout@v5", job)
        self.assertIn("\n    continue-on-error: true\n", job)
        self.assertIn("\n        continue-on-error: true\n", job)
        self.assertIn("GITHUB_EVENT_PATH: ${{ github.event_path }}", job)
        self.assertNotIn("needs:", job)

    def test_reviewer_and_integration_hashes_do_not_satisfy_author_hash(self):
        body = VALID_BODY.replace(
            "**Verified commit SHA:** `0123456789abcdef0123456789abcdef01234567`",
            "**Reviewer-reviewed SHA:** `0123456789abcdef0123456789abcdef01234567`\n- **Combined integration SHA:** `fedcba9876543210fedcba9876543210fedcba98`",
        )
        self.assert_codes(body, {"author_tested_sha"})

    def test_stale_sha_warns_and_scoped_reuse_is_distinguished(self):
        head = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        old = "0123456789abcdef0123456789abcdef01234567"
        report = check_pr_evidence.inspect_body(
            VALID_BODY.replace(old, old) + "\nEvidence is scoped to unaffected documentation paths and is intentionally reused from the older SHA.\n",
            head_sha=head,
        )
        stale = [item for item in report["findings"] if item["code"] == "stale_evidence"]
        self.assertEqual(len(stale), 1)
        self.assertTrue(stale[0]["scoped_reuse"])

        report = check_pr_evidence.inspect_body(VALID_BODY, head_sha=head)
        stale = [item for item in report["findings"] if item["code"] == "stale_evidence"]
        self.assertEqual(len(stale), 1)
        self.assertFalse(stale[0]["scoped_reuse"])

    def test_heading_order_details_and_spacing_variants_are_supported(self):
        body = """### Summary\nsmall change\n\n### Linked issue\n[issue](https://github.com/decentespresso/decaid/issues/1205)\n\n### Risk and acceptance criteria\nRisk level: **L0**\nWhy this level: documentation only\n\n| acceptance criterion | status | evidence |\n|---|---|---|\n| docs accurate | verified | N/A - nonvisual |\n\n<details>\n<summary>proof</summary>\n\nEnvironment: N/A - nonbehavioral\nCommands and results: `true` — passed\nVerified commit SHA: 0123456789abcdef0123456789abcdef01234567\nNot tested / limitations / human validation needed: N/A\n\n</details>\n\n### Contributor responsibility\n- [x] responsibility acknowledged <!-- contributor-responsibility -->\n"""
        report = check_pr_evidence.inspect_body(body)
        self.assertEqual(report["findings"], [])

    def test_exempt_maintainer_body_does_not_need_issue_reference(self):
        body = VALID_BODY.replace("Related #1205", "N/A — maintainer repository-maintenance exemption")
        for association, author_type in (("MEMBER", "User"), ("OWNER", "User"), ("COLLABORATOR", "User"), ("CONTRIBUTOR", "Bot")):
            with self.subTest(association=association, author_type=author_type):
                report = check_pr_evidence.inspect_body(body, association=association, author_type=author_type)
                self.assertNotIn("issue_reference", {item["code"] for item in report["findings"]})
        report = check_pr_evidence.inspect_body(body, association="CONTRIBUTOR", author_type="User")
        self.assertIn("issue_reference", {item["code"] for item in report["findings"]})

    def test_unchecked_responsibility_marker_is_not_evidence(self):
        body = VALID_BODY.replace("[x] I have reviewed", "[ ] I have reviewed")
        self.assert_codes(body, {"responsibility_marker"})

    def test_bare_link_is_uncertain_not_proof_and_no_raw_body_leak(self):
        secret = "synthetic-secret-canary-123"
        body = VALID_BODY.replace("Related #1205", "https://example.invalid/proof") + secret
        report = check_pr_evidence.inspect_body(body)
        self.assertIn("issue_reference", {item["code"] for item in report["findings"]})
        output = check_pr_evidence.render_report(report)
        self.assertNotIn(secret, output)
        self.assertNotIn("example.invalid", output)

    def test_event_parser_accepts_safe_types_and_rejects_malformed_shapes(self):
        event = {"pull_request": {"body": VALID_BODY, "head": {"sha": "a" * 40}, "draft": False}}
        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as stream:
            json.dump(event, stream)
            stream.flush()
            parsed = check_pr_evidence.load_event(Path(stream.name))
        self.assertEqual(parsed["body"], VALID_BODY)
        self.assertEqual(parsed["head_sha"], "a" * 40)

        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as stream:
            stream.write('{"pull_request": "not an object"}')
            stream.flush()
            with self.assertRaises(check_pr_evidence.InputError):
                check_pr_evidence.load_event(Path(stream.name))

    def test_cli_input_error_is_distinct_and_does_not_echo_malformed_data(self):
        secret = "synthetic-secret-canary-456"
        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as stream:
            stream.write('{"pull_request": "' + secret + '"}')
            stream.flush()
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--event", stream.name],
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid event input", result.stderr)
        self.assertNotIn(secret, result.stdout + result.stderr)

    def test_cli_missing_input_is_setup_error(self):
        env = os.environ.copy()
        env.pop("GITHUB_EVENT_PATH", None)
        result = subprocess.run([sys.executable, str(SCRIPT)], capture_output=True, text=True, env=env, check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("invalid event input", result.stderr)

    def test_cli_advisory_findings_still_exit_zero(self):
        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as stream:
            stream.write("## Summary\nDraft\n")
            stream.flush()
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--body", stream.name],
                capture_output=True,
                text=True,
                check=False,
            )
        self.assertEqual(result.returncode, 0)
        self.assertIn("advisory", result.stdout.lower())


if __name__ == "__main__":
    unittest.main()
