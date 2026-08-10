#!/usr/bin/env python3

import json
import os
import tempfile
import unittest
from unittest import mock

import summarize_flutter_tests


class SummarizeFlutterTestsTest(unittest.TestCase):
    def test_parses_counts_failures_and_timings(self):
        events = [
            {"type": "start", "time": 100},
            {
                "type": "suite",
                "time": 110,
                "suite": {"id": 0, "path": "C:/repo/test/slow_test.dart"},
            },
            {
                "type": "testStart",
                "time": 120,
                "test": {"id": 1, "name": "loading", "suiteID": 0},
            },
            {
                "type": "testDone",
                "time": 150,
                "testID": 1,
                "result": "success",
                "hidden": True,
                "skipped": False,
            },
            {
                "type": "testStart",
                "time": 200,
                "test": {"id": 2, "name": "slow | success", "suiteID": 0},
            },
            {
                "type": "suite",
                "time": 210,
                "suite": {"id": 1, "path": "test/fast_test.dart"},
            },
            {"type": "futureEvent", "time": 250},
            {
                "type": "testStart",
                "time": 300,
                "test": {"id": 3, "name": "fails", "suiteID": 1},
            },
            {
                "type": "error",
                "time": 400,
                "testID": 3,
                "error": "Expected: <1>\n  Actual: <2>",
                "stackTrace": "package:test/example_test.dart 10:3  main.<fn>",
                "isFailure": True,
            },
            {
                "type": "testDone",
                "time": 500,
                "testID": 3,
                "result": "failure",
                "hidden": False,
                "skipped": False,
            },
            {
                "type": "testStart",
                "time": 510,
                "test": {"id": 4, "name": "skipped", "suiteID": 1},
            },
            {
                "type": "testDone",
                "time": 510,
                "testID": 4,
                "result": "success",
                "hidden": False,
                "skipped": True,
            },
            {
                "type": "testDone",
                "time": 800,
                "testID": 2,
                "result": "success",
                "hidden": False,
                "skipped": False,
            },
            {"type": "done", "time": 1000, "success": False},
        ]
        lines = [json.dumps(event) for event in events]
        lines.insert(2, json.dumps([{"event": "test.startedProcess"}]))
        lines.insert(3, "")
        lines.insert(3, "not json")

        report = summarize_flutter_tests.parse_events(lines)

        self.assertEqual(report["duration_ms"], 900)
        self.assertEqual(report["successful"], 1)
        self.assertEqual(report["failed"], 1)
        self.assertEqual(report["skipped"], 1)
        self.assertEqual(report["malformed_lines"], 1)
        self.assertFalse(report["run_success"])
        self.assertEqual(report["failures"][0]["name"], "fails")
        self.assertEqual(
            report["failures"][0]["error"], "Expected: <1>\n  Actual: <2>"
        )
        self.assertEqual(report["files"][0], (680, "test/slow_test.dart"))
        self.assertEqual(report["tests"][0]["duration_ms"], 600)

        markdown = summarize_flutter_tests.render_summary(report)

        self.assertIn("| Flutter result | Failed |", markdown)
        self.assertIn("slow \\| success", markdown)
        self.assertIn("test/slow_test.dart", markdown)
        self.assertIn("Expected: &lt;1&gt;   Actual: &lt;2&gt;", markdown)

    def test_keeps_counts_when_timing_is_unavailable(self):
        lines = [
            json.dumps({"type": "start"}),
            json.dumps(
                {
                    "type": "suite",
                    "suite": {"id": 0, "path": "test/no_timing_test.dart"},
                }
            ),
            json.dumps(
                {
                    "type": "testStart",
                    "test": {"id": 1, "name": "passes", "suiteID": 0},
                }
            ),
            json.dumps(
                {
                    "type": "testDone",
                    "time": 5,
                    "testID": 1,
                    "result": "success",
                    "hidden": False,
                    "skipped": False,
                }
            ),
            json.dumps({"type": "done", "success": True}),
        ]

        report = summarize_flutter_tests.parse_events(lines)
        markdown = summarize_flutter_tests.render_summary(report)

        self.assertEqual(report["successful"], 1)
        self.assertIsNone(report["duration_ms"])
        self.assertEqual(report["files"], [])
        self.assertEqual(report["tests"], [])
        self.assertIn("Unavailable", markdown)

    def test_reporting_error_does_not_replace_the_flutter_exit_status(self):
        with tempfile.TemporaryDirectory() as temporary_directory:
            summary_path = os.path.join(temporary_directory, "summary.md")
            missing_events = os.path.join(temporary_directory, "missing.json")
            with mock.patch.dict(
                os.environ, {"GITHUB_STEP_SUMMARY": summary_path}, clear=False
            ):
                exit_code = summarize_flutter_tests.main([missing_events])

            self.assertEqual(exit_code, 0)
            with open(summary_path, encoding="utf-8") as summary:
                markdown = summary.read()
            self.assertIn("reporting error", markdown)
            self.assertIn("Flutter test step exit status remains authoritative", markdown)


if __name__ == "__main__":
    unittest.main()
