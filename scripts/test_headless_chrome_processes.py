#!/usr/bin/env python3
import contextlib
import errno
import io
import os
import struct
import subprocess
import unittest
from unittest import mock

import headless_chrome_processes as processes

TOKEN = "run-12345-Ab123456"
MARKER = f"DECAID_CHROME_RUN_TOKEN={TOKEN}".encode()


def argument_buffer(arguments, environment):
    return (
        struct.pack("i", len(arguments))
        + b"/usr/bin/probe\0\0\0"
        + b"\0".join(arguments) + b"\0"
        + b"\0".join(environment) + b"\0\0"
    )


class ProcessEnvironmentTests(unittest.TestCase):
    def test_darwin_argv_marker_is_not_an_environment_marker(self):
        data = argument_buffer([b"probe", MARKER], [b"OTHER=value"])
        environment = processes.darwin_environment(data)
        self.assertNotIn(MARKER, environment)
        self.assertIn(b"OTHER=value", environment)

    def test_darwin_reader_retains_the_actual_environment_marker(self):
        data = argument_buffer([b"probe"], [MARKER, b"OTHER=value"])
        self.assertIn(MARKER, processes.darwin_environment(data))

    def test_unsupported_platform_is_a_clear_nonzero_error(self):
        output, errors = io.StringIO(), io.StringIO()
        with mock.patch.object(processes.sys, "platform", "unsupported"):
            with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                status = processes.main(["--check"])
        self.assertEqual(status, 1)
        self.assertEqual(output.getvalue(), "")
        self.assertIn("unsupported process environment platform", errors.getvalue())

    def test_unreadable_required_environment_fails_without_partial_output(self):
        row = f"12345 12345 {os.geteuid()} S\n"
        snapshot = subprocess.CompletedProcess([], 0, stdout=row, stderr="")
        output, errors = io.StringIO(), io.StringIO()
        with mock.patch.object(processes.subprocess, "run", return_value=snapshot):
            with mock.patch.object(processes, "environment_for", side_effect=PermissionError(errno.EPERM, "not permitted")):
                with mock.patch.object(processes, "process_exists", return_value=True):
                    with contextlib.redirect_stdout(output), contextlib.redirect_stderr(errors):
                        status = processes.main([TOKEN, "999"])
        self.assertEqual(status, 1)
        self.assertEqual(output.getvalue(), "")
        self.assertIn("cannot inspect process 12345", errors.getvalue())

    def test_disappearing_process_is_a_safe_empty_scan(self):
        row = f"12345 12345 {os.geteuid()} S\n"
        snapshot = subprocess.CompletedProcess([], 0, stdout=row, stderr="")
        with mock.patch.object(processes.subprocess, "run", return_value=snapshot):
            with mock.patch.object(processes, "environment_for", side_effect=ProcessLookupError(errno.ESRCH, "gone")):
                self.assertEqual(processes.owned_processes(TOKEN, 999), [])

    def test_zombie_process_is_not_a_live_scan_target(self):
        status = subprocess.CompletedProcess([], 0, stdout="Z\n", stderr="")
        with mock.patch.object(processes.os, "kill"):
            with mock.patch.object(processes.subprocess, "run", return_value=status):
                self.assertFalse(processes.process_exists(12345))

    def test_foreign_effective_uid_is_never_inspected(self):
        row = f"12345 12345 {os.geteuid() + 1} S\n"
        snapshot = subprocess.CompletedProcess([], 0, stdout=row, stderr="")
        with mock.patch.object(processes.subprocess, "run", return_value=snapshot):
            with mock.patch.object(processes, "environment_for") as read_environment:
                self.assertEqual(processes.owned_processes(TOKEN, 999), [])
                read_environment.assert_not_called()


if __name__ == "__main__":
    unittest.main()
