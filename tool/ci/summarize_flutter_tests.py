#!/usr/bin/env python3

import argparse
import html
import json
import os
import sys
from pathlib import Path


def _time(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def _duration(start, end):
    if start is None or end is None or end < start:
        return None
    return end - start


def _display_path(value):
    path = str(value).replace("\\", "/")
    if "/test/" in path:
        return "test/" + path.rsplit("/test/", 1)[1]
    return path


def parse_events(lines):
    suites = {}
    suite_bounds = {}
    starts = {}
    errors = {}
    tests = []
    failures = []
    successful = 0
    failed = 0
    skipped = 0
    malformed_lines = 0
    start_time = None
    done_time = None
    run_success = None

    for line in lines:
        if not line.strip():
            continue
        try:
            event = json.loads(line)
        except (json.JSONDecodeError, TypeError):
            malformed_lines += 1
            continue
        if not isinstance(event, dict):
            continue

        event_type = event.get("type")
        event_time = _time(event.get("time"))
        if event_type == "start":
            start_time = event_time
        elif event_type == "done":
            done_time = event_time
            if isinstance(event.get("success"), bool):
                run_success = event["success"]
        elif event_type == "suite":
            suite = event.get("suite")
            if isinstance(suite, dict) and isinstance(suite.get("id"), (int, str)):
                suites[suite["id"]] = _display_path(suite.get("path", "unknown"))
        elif event_type == "testStart":
            test = event.get("test")
            if not isinstance(test, dict) or not isinstance(test.get("id"), (int, str)):
                continue
            suite_id = test.get("suiteID")
            starts[test["id"]] = {
                "time": event_time,
                "name": str(test.get("name", f"test {test['id']}")),
                "suite_id": suite_id,
            }
            if event_time is not None and isinstance(suite_id, (int, str)):
                bounds = suite_bounds.setdefault(suite_id, [event_time, None])
                bounds[0] = min(bounds[0], event_time)
        elif event_type == "error":
            test_id = event.get("testID")
            if isinstance(test_id, (int, str)) and event.get("error") is not None:
                errors.setdefault(test_id, []).append(str(event["error"]))
        elif event_type == "testDone":
            test_id = event.get("testID")
            started = starts.pop(test_id, {})
            test_errors = errors.pop(test_id, [])
            suite_id = started.get("suite_id")
            if event_time is not None and isinstance(suite_id, (int, str)):
                bounds = suite_bounds.get(suite_id)
                if bounds is not None:
                    bounds[1] = event_time if bounds[1] is None else max(bounds[1], event_time)
            if event.get("hidden") is True:
                continue

            name = started.get("name", f"test {test_id}")
            path = suites.get(suite_id, "unknown")
            result = str(event.get("result", "unknown"))
            is_skipped = event.get("skipped") is True
            if is_skipped:
                skipped += 1
            elif result == "success":
                successful += 1
            else:
                failed += 1
                failures.append(
                    {
                        "name": name,
                        "path": path,
                        "result": result,
                        "error": "\n".join(test_errors),
                    }
                )

            duration_ms = _duration(started.get("time"), event_time)
            if duration_ms is not None and not is_skipped:
                tests.append(
                    {"duration_ms": duration_ms, "name": name, "path": path}
                )

    file_span_ms = {}
    for suite_id, bounds in suite_bounds.items():
        duration_ms = _duration(*bounds)
        if duration_ms is not None and suite_id in suites:
            path = suites[suite_id]
            file_span_ms[path] = file_span_ms.get(path, 0) + duration_ms

    # Active test time: the sum of individual non-skipped test durations for
    # a path. Unlike the suite wall span this is not inflated by concurrent
    # suite scheduling, so it is the metric to use for optimization targets.
    file_active_ms = {}
    for test in tests:
        path = test["path"]
        file_active_ms[path] = file_active_ms.get(path, 0) + test["duration_ms"]

    files = [
        {
            "path": path,
            "active_ms": file_active_ms.get(path),
            "span_ms": file_span_ms.get(path),
        }
        for path in set(file_span_ms) | set(file_active_ms)
    ]
    files.sort(key=lambda item: item["active_ms"] or 0, reverse=True)

    return {
        "duration_ms": _duration(start_time, done_time),
        "successful": successful,
        "failed": failed,
        "skipped": skipped,
        "run_success": run_success,
        "malformed_lines": malformed_lines,
        "failures": failures,
        "files": files,
        "tests": sorted(tests, key=lambda test: test["duration_ms"], reverse=True),
    }


def _format_duration(duration_ms):
    if duration_ms is None:
        return "Unavailable"
    if duration_ms >= 60_000:
        return f"{duration_ms / 60_000:.2f} min"
    if duration_ms >= 1_000:
        return f"{duration_ms / 1_000:.3f} s"
    return f"{duration_ms:.0f} ms"


def _escape(value):
    return (
        html.escape(str(value), quote=False)
        .replace("|", "\\|")
        .replace("\n", " ")
        .replace("\r", " ")
    )


def suites_over_limit(report, max_active_ms):
    return [
        item
        for item in report["files"]
        if (item["active_ms"] or 0) > max_active_ms
    ]


def render_summary(report):
    result = {True: "Passed", False: "Failed"}.get(report["run_success"], "Unknown")
    lines = [
        "## Flutter test timing",
        "",
        "| Metric | Value |",
        "| --- | ---: |",
        f"| Flutter result | {result} |",
        f"| Execution duration | {_format_duration(report['duration_ms'])} |",
        f"| Successful tests | {report['successful']} |",
        f"| Failed tests | {report['failed']} |",
        f"| Skipped tests | {report['skipped']} |",
    ]
    if report["malformed_lines"]:
        lines.append(f"| Malformed lines ignored | {report['malformed_lines']} |")

    if report["failures"]:
        lines.extend(
            [
                "",
                "### Failed tests",
                "",
                "| Test | File | Result | Error |",
                "| --- | --- | --- | --- |",
            ]
        )
        lines.extend(
            "| {} | {} | {} | {} |".format(
                _escape(test["name"]),
                _escape(test["path"]),
                _escape(test["result"]),
                _escape(test["error"] or "Unavailable"),
            )
            for test in report["failures"][:20]
        )
        if len(report["failures"]) > 20:
            lines.append(f"\n{len(report['failures']) - 20} additional failures omitted.")

    lines.extend(["", "### Slowest test files by active test time", ""])
    if report["files"]:
        lines.extend(["| Active time | Suite span | File |", "| ---: | ---: | --- |"])
        lines.extend(
            "| {} | {} | {} |".format(
                _format_duration(item["active_ms"]),
                _format_duration(item["span_ms"]),
                _escape(item["path"]),
            )
            for item in report["files"][:20]
        )
        lines.append(
            "\n"
            "Active time is the sum of individual non-skipped test "
            "durations; suite span is first-start to last-test-completion "
            "and can be inflated by concurrent suite scheduling."
        )
    else:
        lines.append("Timing unavailable from the captured events.")

    lines.extend(["", "### Slowest individual tests", ""])
    if report["tests"]:
        lines.extend(["| Duration | Test | File |", "| ---: | --- | --- |"])
        lines.extend(
            "| {} | {} | {} |".format(
                _format_duration(test["duration_ms"]),
                _escape(test["name"]),
                _escape(test["path"]),
            )
            for test in report["tests"][:20]
        )
    else:
        lines.append("Timing unavailable from the captured events.")
    return "\n".join(lines) + "\n"


def _write_summary(markdown):
    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not summary_path:
        print(markdown, end="")
        return
    with open(summary_path, "a", encoding="utf-8") as summary:
        summary.write(markdown)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("events", type=Path)
    parser.add_argument(
        "--max-active-ms",
        type=int,
        default=None,
        help=(
            "Gate mode: exit 1 when any test file's active time exceeds "
            "this many ms. Suppresses the markdown summary."
        ),
    )
    args = parser.parse_args(argv)
    try:
        with args.events.open(encoding="utf-8", errors="replace") as events:
            report = parse_events(events)
        markdown = render_summary(report)
    except Exception as error:
        message = _escape(error)
        markdown = (
            "## Flutter test timing\n\n"
            f"Timing summary unavailable due to a reporting error: `{message}`\n\n"
            "The Flutter test step exit status remains authoritative.\n"
        )
        print(f"Flutter timing summary unavailable: {error}", file=sys.stderr)
        report = None

    if args.max_active_ms is not None:
        if report is None:
            return 0
        offenders = suites_over_limit(report, args.max_active_ms)
        if offenders:
            print(
                f"{len(offenders)} test suite(s) exceed the "
                f"{args.max_active_ms} ms active-time limit:",
                file=sys.stderr,
            )
            for item in offenders:
                print(
                    f"  {item['path']}: {_format_duration(item['active_ms'])}",
                    file=sys.stderr,
                )
            return 1
        return 0

    try:
        _write_summary(markdown)
    except OSError as error:
        print(f"Could not write Flutter timing summary: {error}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
