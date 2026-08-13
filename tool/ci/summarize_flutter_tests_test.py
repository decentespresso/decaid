#!/usr/bin/env python3

import json
import os
import tempfile
import unittest
from unittest import mock

import summarize_flutter_tests


def _event(event_type, **fields):
    event = {"type": event_type, "time": 0}
    event.update(fields)
    return json.dumps(event)


def _suite(suite_id, path):
    return _event("suite", suite={"id": suite_id, "path": path})


def _test_start(test_id, suite_id, name, time):
    return _event(
        "testStart",
        time=time,
        test={"id": test_id, "name": name, "suiteID": suite_id},
    )


def _test_done(test_id, time, result="success", skipped=False, hidden=False):
    return _event(
        "testDone",
        time=time,
        testID=test_id,
        result=result,
        skipped=skipped,
        hidden=hidden,
    )


class SummarizeFlutterTestsTest(unittest.TestCase):
    def test_parses_counts_failures_and_timings(self):
        events = [
            _event("start", time=100),
            _suite(0, "C:/repo/test/slow_test.dart"),
            _test_start(1, 0, "loading", 120),
            _test_done(1, 150, hidden=True),
            _test_start(2, 0, "slow | success", 200),
            _suite(1, "test/fast_test.dart"),
            _event("futureEvent", time=250),
            _test_start(3, 1, "fails", 300),
            _event(
                "error",
                time=400,
                testID=3,
                error="Expected: <1>\n  Actual: <2>",
                stackTrace="package:test/example_test.dart 10:3  main.<fn>",
                isFailure=True,
            ),
            _test_done(3, 500, result="failure"),
            _test_start(4, 1, "skipped", 510),
            _test_done(4, 510, skipped=True),
            _test_done(2, 800),
            _event("done", time=1000, success=False),
        ]
        lines = list(events)
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
        slow_file = report["files"][0]
        self.assertEqual(slow_file["path"], "test/slow_test.dart")
        self.assertEqual(slow_file["active_ms"], 600)
        self.assertEqual(slow_file["span_ms"], 680)
        self.assertEqual(report["tests"][0]["duration_ms"], 600)

        markdown = summarize_flutter_tests.render_summary(report)

        self.assertIn("| Flutter result | Failed |", markdown)
        self.assertIn("slow \\| success", markdown)
        self.assertIn("test/slow_test.dart", markdown)
        self.assertIn("Active time | Suite span | File", markdown)
        self.assertIn("Expected: &lt;1&gt;   Actual: &lt;2&gt;", markdown)

    def test_two_tests_in_one_file_sum_active_time(self):
        lines = [
            _event("start"),
            _suite(0, "test/sum_test.dart"),
            _test_start(1, 0, "first", 100),
            _test_done(1, 250),
            _test_start(2, 0, "second", 300),
            _test_done(2, 450),
            _event("done", success=True),
        ]
        report = summarize_flutter_tests.parse_events(lines)
        self.assertEqual(
            report["files"][0]["path"], "test/sum_test.dart"
        )
        self.assertEqual(report["files"][0]["active_ms"], 300)
        self.assertEqual(report["files"][0]["span_ms"], 350)

    def test_skipped_tests_do_not_contribute_to_active_time(self):
        lines = [
            _event("start"),
            _suite(0, "test/skipped_test.dart"),
            _test_start(1, 0, "runs", 100),
            _test_done(1, 300),
            _test_start(2, 0, "skips", 400),
            _test_done(2, 900, skipped=True),
            _event("done", success=True),
        ]
        report = summarize_flutter_tests.parse_events(lines)
        self.assertEqual(report["skipped"], 1)
        self.assertEqual(report["files"][0]["active_ms"], 200)
        # The skipped test inflates the suite span but not the active time.
        self.assertEqual(report["files"][0]["span_ms"], 800)

    def test_large_suite_span_with_small_active_time(self):
        # File A: two quick tests spread across the whole run wall-clock.
        # File B: two medium tests in a compact window.
        lines = [
            _event("start"),
            _suite(0, "test/spread_test.dart"),
            _test_start(1, 0, "early", 100),
            _test_done(1, 200),
            _test_start(2, 0, "late", 8900),
            _test_done(2, 9000),
            _suite(1, "test/compact_test.dart"),
            _test_start(3, 1, "first", 1000),
            _test_done(3, 3000),
            _test_start(4, 1, "second", 3001),
            _test_done(4, 5001),
            _event("done", success=True),
        ]
        report = summarize_flutter_tests.parse_events(lines)
        files = {item["path"]: item for item in report["files"]}
        spread = files["test/spread_test.dart"]
        compact = files["test/compact_test.dart"]

        # Spread has the bigger wall span but the smaller active time.
        self.assertEqual(spread["span_ms"], 8900)
        self.assertEqual(spread["active_ms"], 200)
        self.assertEqual(compact["span_ms"], 4001)
        self.assertEqual(compact["active_ms"], 4000)

        # Active-time ranking must put compact first.
        self.assertEqual(report["files"][0]["path"], "test/compact_test.dart")
        self.assertEqual(report["files"][1]["path"], "test/spread_test.dart")

        markdown = summarize_flutter_tests.render_summary(report)
        self.assertLess(
            markdown.index("test/compact_test.dart"),
            markdown.index("test/spread_test.dart"),
        )

    def test_orphaned_test_start_and_unknown_test_done_are_tolerated(self):
        lines = [
            _event("start"),
            _suite(0, "test/partial_test.dart"),
            _test_start(1, 0, "never completes", 100),
            _event("testDone", time=300, testID=99, result="success"),
            _event("done", success=True),
        ]
        report = summarize_flutter_tests.parse_events(lines)
        # The unknown testDone is counted but carries no timing, and the
        # orphaned testStart does not crash the parse. No suite bounds are
        # closed, so no file timing is recorded.
        self.assertEqual(report["successful"], 1)
        self.assertEqual(report["tests"], [])
        self.assertEqual(report["files"], [])

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

    def test_active_time_limit_passes_when_all_suites_are_under(self):
        lines = [
            _event("start"),
            _suite(0, "test/quick_test.dart"),
            _test_start(1, 0, "first", 100),
            _test_done(1, 2000),
            _event("done", success=True),
        ]
        with tempfile.TemporaryDirectory() as temporary_directory:
            events = os.path.join(temporary_directory, "events.json")
            with open(events, "w", encoding="utf-8") as events_file:
                events_file.write("\n".join(lines))
            summary_path = os.path.join(temporary_directory, "summary.md")
            with mock.patch.dict(
                os.environ, {"GITHUB_STEP_SUMMARY": summary_path}, clear=False
            ):
                exit_code = summarize_flutter_tests.main(
                    [events, "--max-active-ms", "20000"]
                )
        self.assertEqual(exit_code, 0)
        # Gate mode suppresses the markdown summary.
        self.assertFalse(os.path.exists(summary_path))

    def test_active_time_limit_fails_when_a_suite_is_over(self):
        lines = [
            _event("start"),
            _suite(0, "test/slow_test.dart"),
            _test_start(1, 0, "first", 100),
            _test_done(1, 21000),
            _event("done", success=True),
        ]
        with tempfile.TemporaryDirectory() as temporary_directory:
            events = os.path.join(temporary_directory, "events.json")
            with open(events, "w", encoding="utf-8") as events_file:
                events_file.write("\n".join(lines))
            with mock.patch.dict(
                os.environ, {"GITHUB_STEP_SUMMARY": ""}, clear=False
            ):
                exit_code = summarize_flutter_tests.main(
                    [events, "--max-active-ms", "20000"]
                )
        self.assertEqual(exit_code, 1)

    def test_active_time_limit_ignores_timing_unavailable_files(self):
        lines = [
            _event("start"),
            _suite(0, "test/no_timing_test.dart"),
            _test_start(1, 0, "passes", 100),
            _event("done", success=True),
        ]
        with tempfile.TemporaryDirectory() as temporary_directory:
            events = os.path.join(temporary_directory, "events.json")
            with open(events, "w", encoding="utf-8") as events_file:
                events_file.write("\n".join(lines))
            with mock.patch.dict(
                os.environ, {"GITHUB_STEP_SUMMARY": ""}, clear=False
            ):
                exit_code = summarize_flutter_tests.main(
                    [events, "--max-active-ms", "20000"]
                )
        self.assertEqual(exit_code, 0)

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
