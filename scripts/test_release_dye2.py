#!/usr/bin/env python3
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

import yaml


ROOT = Path(__file__).resolve().parents[1]


class ReleaseDye2Test(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        (self.root / "bin").mkdir()
        shutil.copy(ROOT / "scripts/fetch_dye2_plugin.sh", self.root / "scripts")
        for plugin in ("shot_upload", "dcamp"):
            (self.root / f"scripts/fetch_{plugin}_plugin.sh").write_text(
                "#!/usr/bin/env bash\nexit 0\n"
            )
            (self.root / f"scripts/fetch_{plugin}_plugin.sh").chmod(0o755)
        self.log = self.root / "gh.log"
        self.output = self.root / "output"
        self.env = {
            **os.environ,
            "PATH": f"{self.root / 'bin'}:{os.environ['PATH']}",
            "GITHUB_REF": "refs/tags/v2.0.0",
            "GITHUB_OUTPUT": str(self.output),
            "GH_LOG": str(self.log),
            "LATEST_TAG": "v1.2.3",
            "FIXTURE_ZIP": str(self.root / "dye2.reaplugin-v1.2.3.zip"),
        }
        for key in ("DYE2_VERSION", "DYE2_REPO", "DYE2_API_VERSION"):
            self.env.pop(key, None)
        with zipfile.ZipFile(self.env["FIXTURE_ZIP"], "w") as archive:
            archive.writestr(
                "dye2.reaplugin/manifest.json",
                '{"id":"dye2.reaplugin","version":"1.2.3",'
                '"apiVersion":"1","permissions":["log","api"]}',
            )
            archive.writestr("dye2.reaplugin/plugin.js", "function createPlugin() {}")
        gh = self.root / "bin/gh"
        gh.write_text('''#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >> "$GH_LOG"
case "$1 $2" in
  'release view')
    if [ "${FAIL_VIEW:-0}" = 1 ]; then exit 1; fi
    printf '%s\\n' "$LATEST_TAG"
    ;;
  'release download')
    [ "$3" = v1.2.3 ]
    while [ "$1" != --dir ]; do shift; done
    cp "$FIXTURE_ZIP" "$2/"
    ;;
  *) exit 1 ;;
esac
''')
        gh.chmod(0o755)
        self.jobs = yaml.safe_load((ROOT / ".github/workflows/release.yml").read_text())["jobs"]

    def run_step(self, script, env=None):
        return subprocess.run(
            ["bash", "-e", "-o", "pipefail", "-c", script],
            cwd=self.root,
            env={**self.env, **(env or {})},
            capture_output=True,
            text=True,
        )

    def resolver(self):
        metadata = self.jobs["release-metadata"]
        expression = metadata["outputs"].get("dye2_version")
        self.assertIsNotNone(expression, "release-metadata must export dye2_version")
        step = next(s for s in metadata["steps"] if expression == "${{ steps." + s.get("id", "") + ".outputs.version }}")
        return step["run"]

    def test_one_resolution_reaches_every_platform_and_rerun(self):
        result = self.run_step(self.resolver())
        self.assertEqual(result.returncode, 0, result.stderr)
        version = dict(line.split("=", 1) for line in self.output.read_text().splitlines())["version"]
        self.assertEqual(version, "v1.2.3")
        platforms = {name: job for name, job in self.jobs.items() if name.startswith("build-")}
        self.assertEqual(len(platforms), 6)
        for name, job in [*platforms.items(), next(iter(platforms.items()))]:
            with self.subTest(platform=name):
                self.assertIn("release-metadata", job["needs"])
                step = next(s for s in job["steps"] if "fetch_dye2_plugin.sh" in s.get("run", ""))
                env = {**job.get("env", {}), **step.get("env", {})}
                self.assertEqual(env.get("DYE2_VERSION"), "${{ needs.release-metadata.outputs.dye2_version }}")
                result = self.run_step(step["run"], {"DYE2_VERSION": version, "LATEST_TAG": "v9.9.9"})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("installed dye2.reaplugin-v1.2.3.zip", result.stdout)
        calls = self.log.read_text().splitlines()
        self.assertEqual(
            [call for call in calls if call.startswith("release view ")],
            ["release view --repo decentespresso/dye2 --json tagName -q .tagName"],
        )
        self.assertEqual(sum(call.startswith("release download v1.2.3 ") for call in calls), 7)

    def test_resolution_failure_stops_metadata(self):
        for env in ({"FAIL_VIEW": "1"}, {"LATEST_TAG": ""}, {"LATEST_TAG": "null"}):
            with self.subTest(env=env):
                self.output.unlink(missing_ok=True)
                result = self.run_step(self.resolver(), env)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse(self.output.exists() and self.output.read_text().strip())

    def test_standalone_fetch_still_resolves_latest(self):
        result = self.run_step("./scripts/fetch_dye2_plugin.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("installed dye2.reaplugin-v1.2.3.zip", result.stdout)
        self.assertEqual(len(self.log.read_text().splitlines()), 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
