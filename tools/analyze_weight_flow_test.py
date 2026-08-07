#!/usr/bin/env python3

import unittest
from datetime import datetime, timedelta, timezone

import analyze_weight_flow


class MetricsTest(unittest.TestCase):
    def test_metrics_use_the_longest_active_run(self):
        start = datetime(2026, 7, 22, tzinfo=timezone.utc)
        flows = [0.0, 1.0, 1.5, 0.0, 2.0, 2.5, 3.5, 3.0]
        samples = [
            {
                "timestamp": start + timedelta(milliseconds=index * 250),
                "weight": float(index),
                "flow": flow,
            }
            for index, flow in enumerate(flows)
        ]

        result = analyze_weight_flow.metrics(samples)

        self.assertEqual(result["samples"], 8)
        self.assertEqual(result["active_samples"], 4)
        self.assertAlmostEqual(result["cadence_hz"], 4.0)
        self.assertAlmostEqual(result["mean_abs_delta"], 2 / 3)
        self.assertAlmostEqual(result["tail_mean_abs_delta"], 2 / 3)
        self.assertAlmostEqual(result["p95_abs_delta"], 1.0)
        self.assertAlmostEqual(result["mean_abs_second_delta"], 1.0)

    def test_metrics_handles_empty_samples(self):
        result = analyze_weight_flow.metrics([])
        self.assertEqual(result["samples"], 0)
        self.assertEqual(result["active_samples"], 0)
        self.assertEqual(result["cadence_hz"], 0.0)

    def test_metrics_handles_no_scale_measurements(self):
        shot = {"measurements": [{"scale": None}, {"no_scale": True}]}
        samples = analyze_weight_flow.extract_samples(shot)
        self.assertEqual(samples, [])

    def test_metrics_handles_malformed_scale_record(self):
        shot = {
            "measurements": [
                {"scale": {"timestamp": "2026-01-01T00:00:00Z"}},
                {"scale": {"timestamp": "2026-01-01T00:00:00Z", "weight": "nope"}},
                {
                    "scale": {
                        "timestamp": "2026-01-01T00:00:00Z",
                        "weight": 100,
                        "weightFlow": "slow",
                    }
                },
            ]
        }
        samples = analyze_weight_flow.extract_samples(shot)
        self.assertEqual(samples, [])


class ValidationTest(unittest.TestCase):
    def test_accepts_valid_shot_ids(self):
        valid = ["abc123", "shot-001", "2026-07-22_esp", "test.v1"]
        for sid in valid:
            analyze_weight_flow.validate_shot_id(sid)

    def test_rejects_dot_and_dotdot(self):
        with self.assertRaises(ValueError):
            analyze_weight_flow.validate_shot_id(".")
        with self.assertRaises(ValueError):
            analyze_weight_flow.validate_shot_id("..")

    def test_rejects_path_traversal(self):
        bad_ids = ["../../tmp/result", "foo/bar", "a\\b"]
        for sid in bad_ids:
            with self.assertRaises(ValueError):
                analyze_weight_flow.validate_shot_id(sid)

    def test_rejects_empty(self):
        with self.assertRaises(ValueError):
            analyze_weight_flow.validate_shot_id("")


if __name__ == "__main__":
    unittest.main()
