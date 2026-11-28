import copy
import json
import subprocess
import unittest
from pathlib import Path

import yaml


WORKFLOW = Path(__file__).resolve().parents[2] / ".github/workflows/pr-checks.yml"
HARNESS = """
const fs = require('node:fs');
const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const result = { failures: [], notices: [], pullRequests: [], issues: [] };
const github = { rest: {
  pulls: { get: async (args) => {
    result.pullRequests.push(args);
    if (input.pullError) throw new Error('PR lookup failed');
    return { data: input.current };
  } },
  issues: { get: async (args) => {
    result.issues.push(args.issue_number);
    const issue = input.issues[args.issue_number];
    if (!issue) throw Object.assign(new Error('Not found'), { status: 404 });
    return { data: issue };
  } },
} };
const context = {
  repo: { owner: 'decentespresso', repo: 'decaid' },
  payload: { pull_request: input.event },
};
const core = {
  setFailed: (message) => result.failures.push(message),
  notice: (message) => result.notices.push(message),
};
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
new AsyncFunction('context', 'github', 'core', input.script)(context, github, core)
  .catch((error) => { result.error = error.message; })
  .then(() => process.stdout.write(JSON.stringify(result)));
"""


def acknowledged_body(issue=123):
    return (
        f"Fixes #{issue}\n\n"
        "- [x] I take responsibility <!-- contributor-responsibility -->\n"
    )


class ContributionPolicyTest(unittest.TestCase):
    def setUp(self):
        self.workflow = yaml.load(WORKFLOW.read_text(), Loader=yaml.BaseLoader)
        self.current = {
            "number": 42,
            "body": acknowledged_body(),
            "author_association": "FIRST_TIME_CONTRIBUTOR",
            "user": {"type": "User"},
        }
        self.event = copy.deepcopy(self.current)
        self.issues = {123: {"state": "open", "labels": [{"name": "ready-for-human"}]}}

    def run_policy(self, **overrides):
        steps = self.workflow["jobs"]["contribution-policy"]["steps"]
        script = next(step["with"]["script"] for step in steps if "with" in step)
        payload = {
            "script": script,
            "event": self.event,
            "current": self.current,
            "issues": self.issues,
            **overrides,
        }
        process = subprocess.run(
            ["node", "-e", HARNESS],
            input=json.dumps(payload),
            text=True,
            capture_output=True,
            check=True,
            timeout=10,
        )
        return json.loads(process.stdout)

    def test_checks_acknowledgement_added_while_awaiting_approval(self):
        self.event["body"] = self.current["body"].replace("[x]", "[ ]")
        result = self.run_policy()
        self.assertEqual(result["failures"], [])
        self.assertNotIn("error", result)
        self.assertEqual(
            result["pullRequests"],
            [{"owner": "decentespresso", "repo": "decaid", "pull_number": 42}],
        )
        self.assertEqual(result["issues"], [123])

    def test_rejects_acknowledgement_removed_since_trigger(self):
        self.current["body"] = self.current["body"].replace("[x]", "[ ]")
        result = self.run_policy()
        self.assertEqual(len(result["failures"]), 1)
        self.assertIn("acknowledgement", result["failures"][0])
        self.assertEqual(result["issues"], [])

    def test_uses_current_issue_reference(self):
        self.current["body"] = acknowledged_body(456)
        self.issues[456] = self.issues.pop(123)
        result = self.run_policy()
        self.assertEqual(result["failures"], [])
        self.assertEqual(result["issues"], [456])

    def test_current_unaccepted_or_closed_issue_still_blocks(self):
        for issue in (
            {"state": "open", "labels": []},
            {"state": "closed", "labels": ["ready-for-human"]},
            {
                "state": "open",
                "labels": ["ready-for-human"],
                "pull_request": {"url": "https://example.com/pull/123"},
            },
        ):
            with self.subTest(issue=issue):
                result = self.run_policy(issues={123: issue})
                self.assertEqual(len(result["failures"]), 1)
                self.assertIn("No referenced issue", result["failures"][0])

    def test_preserves_maintainer_and_bot_exemptions(self):
        for association, user_type in (
            ("OWNER", "User"),
            ("MEMBER", "User"),
            ("COLLABORATOR", "User"),
            ("NONE", "Bot"),
        ):
            with self.subTest(association=association, user_type=user_type):
                current = {
                    **self.current,
                    "body": None,
                    "author_association": association,
                }
                current["user"] = {"type": user_type}
                result = self.run_policy(current=current)
                self.assertEqual(result["failures"], [])
                self.assertEqual(result["issues"], [])
                self.assertNotIn("error", result)

    def test_stale_maintainer_association_does_not_bypass_current_checks(self):
        self.event["author_association"] = "MEMBER"
        self.current["body"] = None
        result = self.run_policy()
        self.assertEqual(len(result["failures"]), 1)
        self.assertIn("acknowledgement", result["failures"][0])

    def test_pr_lookup_failure_does_not_fall_back_to_event_body(self):
        result = self.run_policy(pullError=True)
        self.assertEqual(result.get("error"), "PR lookup failed")
        self.assertEqual(result["issues"], [])

    def test_body_edits_trigger_revalidation(self):
        triggers = self.workflow["on"]["pull_request"].get("types", [])
        expected = {"opened", "synchronize", "reopened", "edited"}
        self.assertTrue(expected <= set(triggers))


if __name__ == "__main__":
    unittest.main()
