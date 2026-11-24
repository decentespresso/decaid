"""Filename contract for versioned Decaid release assets.

Every versioned release asset carries the full git tag, including its leading
``v`` (``decaid-android-v0.9.4.apk``), while the stable ``-latest`` aliases stay
version-free. The checks below execute the release workflow's own shell
snippets, so the contract cannot drift away from what a release actually runs.
"""

import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RELEASE_WORKFLOW = ROOT / ".github" / "workflows" / "release.yml"
PR_CHECKS_WORKFLOW = ROOT / ".github" / "workflows" / "pr-checks.yml"
PACKAGE_APPIMAGE = ROOT / "scripts" / "package_appimage.sh"
ALIAS_SCRIPT = ROOT / "scripts" / "create_release_aliases.sh"
RELEASE_DOC = ROOT / "doc" / "RELEASE.md"

WORKFLOW_TEXT = RELEASE_WORKFLOW.read_text()
PR_CHECKS_TEXT = PR_CHECKS_WORKFLOW.read_text()
APPIMAGE_TEXT = PACKAGE_APPIMAGE.read_text()
ALIAS_SCRIPT_TEXT = ALIAS_SCRIPT.read_text()
DOC_TEXT = RELEASE_DOC.read_text()

METADATA_TAG = "${{ needs.release-metadata.outputs.tag }}"
METADATA_VERSION = "${{ needs.release-metadata.outputs.version }}"
APPCAST_TAG = "${{ steps.version.outputs.tag }}"
APPCAST_VERSION = "${{ steps.version.outputs.version }}"
INPUT_VERSION = "${{ inputs.version }}"
SHELL_TAG = "${TAG}"

STABLE_TAG = "v0.9.4"
BETA_TAG = "v0.9.4-beta.1"
DRY_RUN_TAG = "v0.0.0-dryrun"

ARTIFACTS = (
    ("android-apk", "decaid-android-{tag}.apk"),
    ("macos-app", "decaid-macos-{tag}.zip"),
    ("macos-app", "decaid-macos-{tag}.dmg"),
    ("linux-app", "decaid-linux-x64-{tag}.tar.gz"),
    ("linux-app", "decaid-linux-x86_64-{tag}.AppImage"),
    ("raspberrypi-linux-arm64-app", "decaid-linux-arm64-{tag}.tar.gz"),
    ("raspberrypi-linux-arm64-app", "decaid-linux-aarch64-{tag}.AppImage"),
    ("windows-app", "decaid-windows-x64-{tag}.zip"),
    ("ios-ipa-unsigned", "decaid-ios-unsigned-{tag}.ipa"),
)
CHECKSUM_MANIFEST = "decaid-{tag}-SHA256SUMS.txt"
LATEST_MANIFEST = "decaid-latest-SHA256SUMS.txt"
LATEST_ALIASES = tuple(name.format(tag="latest") for _, name in ARTIFACTS)


def step_run_script(text, step_name):
    """Return the dedented ``run:`` block of the named workflow step."""
    lines = text.splitlines()
    marker = "- name: {}".format(step_name)
    start = next(
        index for index, line in enumerate(lines) if line.strip() == marker
    )
    run_index = next(
        index
        for index in range(start, len(lines))
        if lines[index].strip() == "run: |"
    )
    run_indent = len(lines[run_index]) - len(lines[run_index].lstrip())
    body = []
    for line in lines[run_index + 1 :]:
        indented = len(line) - len(line.lstrip())
        if line.strip() and indented <= run_indent:
            break
        body.append(line)
    return textwrap.dedent("\n".join(body)) + "\n"


def render(script, tag="", version="", input_version=""):
    """Substitute the expressions GitHub would resolve before running."""
    rendered = script
    for expression, value in (
        (INPUT_VERSION, input_version),
        (METADATA_TAG, tag),
        (METADATA_VERSION, version),
        (APPCAST_TAG, tag),
        (APPCAST_VERSION, version),
    ):
        rendered = rendered.replace(expression, value)
    if "${{" in rendered:
        raise AssertionError(
            "unresolved workflow expression in snippet:\n{}".format(rendered)
        )
    return rendered


def run_bash(script, env):
    return subprocess.run(
        ["bash", "-euo", "pipefail", "-c", script],
        capture_output=True,
        text=True,
        env=env,
    )


def read_github_output(path):
    values = {}
    for line in Path(path).read_text().splitlines():
        key, _, value = line.partition("=")
        values[key] = value
    return values


class MetadataResolutionTest(unittest.TestCase):
    """The release-metadata snippet is the single source of the tag."""

    def resolve(self, event, ref="", input_version=""):
        script = render(
            step_run_script(WORKFLOW_TEXT, "Resolve tag and version"),
            input_version=input_version,
        )
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "github-output"
            output.touch()
            env = dict(
                os.environ,
                GITHUB_EVENT_NAME=event,
                GITHUB_REF=ref,
                GITHUB_OUTPUT=str(output),
            )
            result = run_bash(script, env)
            self.assertEqual(
                result.returncode,
                0,
                "tag resolution failed for {} {}: {}".format(
                    event, ref or input_version, result.stderr
                ),
            )
            return read_github_output(output)

    def test_tag_push_keeps_full_tag_and_bare_version(self):
        for tag in (STABLE_TAG, BETA_TAG):
            with self.subTest(tag=tag):
                outputs = self.resolve("push", "refs/tags/{}".format(tag))
                self.assertEqual(outputs["tag"], tag)
                self.assertEqual(outputs["version"], tag[1:])

    def test_tag_push_without_v_prefix_is_rejected(self):
        script = render(step_run_script(WORKFLOW_TEXT, "Resolve tag and version"))
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "github-output"
            output.touch()
            env = dict(
                os.environ,
                GITHUB_EVENT_NAME="push",
                GITHUB_REF="refs/tags/0.9.4",
                GITHUB_OUTPUT=str(output),
            )
            result = run_bash(script, env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Expected a v* tag", result.stderr)

    def test_dispatch_synthesizes_tag_from_bare_version_input(self):
        cases = (
            ("", DRY_RUN_TAG, DRY_RUN_TAG[1:]),
            ("0.9.4", STABLE_TAG, "0.9.4"),
            (STABLE_TAG, STABLE_TAG, "0.9.4"),
            (BETA_TAG, BETA_TAG, "0.9.4-beta.1"),
        )
        for input_version, expected_tag, expected_version in cases:
            with self.subTest(input=input_version):
                outputs = self.resolve(
                    "workflow_dispatch", "refs/heads/agent/issue-1240", input_version
                )
                self.assertEqual(outputs["tag"], expected_tag)
                self.assertEqual(outputs["version"], expected_version)


class FilenameContractTest(unittest.TestCase):
    """Every versioned filename the workflow builds names the full tag."""

    def test_workflow_filenames_use_tag_expressions(self):
        for _, name in ARTIFACTS:
            with self.subTest(artifact=name):
                self.assertIn(name.format(tag=METADATA_TAG), WORKFLOW_TEXT)
        self.assertIn(CHECKSUM_MANIFEST.format(tag=METADATA_TAG), WORKFLOW_TEXT)

    def test_appcast_references_renamed_macos_zip(self):
        zip_name = "decaid-macos-{}.zip".format(APPCAST_TAG)
        self.assertIn(zip_name, WORKFLOW_TEXT)
        self.assertIn(
            '--pattern "{}"'.format(zip_name),
            WORKFLOW_TEXT,
        )

    def test_expected_artifact_validation_uses_tag(self):
        for _, name in ARTIFACTS:
            with self.subTest(artifact=name):
                self.assertIn(name.format(tag=SHELL_TAG), WORKFLOW_TEXT)
        self.assertIn(CHECKSUM_MANIFEST.format(tag=SHELL_TAG), WORKFLOW_TEXT)

    def test_no_versioned_filename_uses_bare_version(self):
        offenders = re.findall(
            r"decaid-[A-Za-z0-9_.-]*(?:\$\{\{[^}]*\}\}|\$\{[A-Za-z_]+\})",
            WORKFLOW_TEXT,
        )
        self.assertTrue(offenders, "no versioned filenames found in release.yml")
        for offender in offenders:
            with self.subTest(filename=offender):
                self.assertTrue(
                    offender.endswith("outputs.tag }}")
                    or offender.endswith(SHELL_TAG),
                    "versioned filename must use the full tag: {}".format(offender),
                )

    def test_publish_globs_cover_every_artifact(self):
        for job, name in ARTIFACTS:
            with self.subTest(artifact=name):
                self.assertIn("release-artifacts/{job}/*".format(job=job), WORKFLOW_TEXT)
        self.assertIn(LATEST_MANIFEST, WORKFLOW_TEXT)

    def test_stable_aliases_stay_version_free(self):
        self.assertIn('alias="${source/-${TAG}/-latest}"', ALIAS_SCRIPT_TEXT)
        self.assertIn(
            'scripts/create_release_aliases.sh release-artifacts "$TAG"',
            WORKFLOW_TEXT,
        )
        for alias in LATEST_ALIASES:
            with self.subTest(alias=alias):
                self.assertNotIn(alias, WORKFLOW_TEXT)
        self.assertIn(LATEST_MANIFEST, WORKFLOW_TEXT)
        self.assertIn(LATEST_MANIFEST, DOC_TEXT)
        self.assertIn(
            "releases/latest/download/decaid-android-latest.apk", DOC_TEXT
        )

    def test_documentation_uses_tag_placeholder(self):
        self.assertIn("decaid-macos-<tag>.zip", DOC_TEXT)
        self.assertIn("decaid-<tag>-SHA256SUMS.txt", DOC_TEXT)

    def test_appimage_packager_names_the_tag(self):
        self.assertIn(
            'OUTPUT="${OUTDIR}/decaid-linux-${ARCH}-${TAG}.AppImage"', APPIMAGE_TEXT
        )
        for arch in ("x86_64", "aarch64"):
            with self.subTest(arch=arch):
                self.assertIn(
                    '{} ${{{{ needs.release-metadata.outputs.tag }}}} "$GITHUB_WORKSPACE"'.format(
                        arch
                    ),
                    WORKFLOW_TEXT,
                )
        self.assertIn('x86_64 v0.0.0-test "$RUNNER_TEMP"', PR_CHECKS_TEXT)
        self.assertIn(
            '"$RUNNER_TEMP/decaid-linux-x86_64-v0.0.0-test.AppImage"', PR_CHECKS_TEXT
        )


class ExpectedArtifactStepTest(unittest.TestCase):
    """The real validation step accepts tag names and rejects bare versions."""

    def run_assert_step(self, directory, tag, version):
        script = render(
            step_run_script(WORKFLOW_TEXT, "Assert expected release artifacts"),
            tag=tag,
            version=version,
        )
        return subprocess.run(
            ["bash", "-euo", "pipefail", "-c", script],
            capture_output=True,
            text=True,
            cwd=directory,
        )

    def write_artifacts(self, directory, tag, name_hook=None):
        for job, name in ARTIFACTS:
            filename = name.format(tag=tag)
            if name_hook is not None:
                filename = name_hook(filename)
            path = Path(directory) / "release-artifacts" / job / filename
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("x")

    def test_accepts_stable_and_beta_tag_artifacts(self):
        for tag in (STABLE_TAG, BETA_TAG):
            with self.subTest(tag=tag):
                with tempfile.TemporaryDirectory() as directory:
                    self.write_artifacts(directory, tag)
                    result = self.run_assert_step(directory, tag, tag[1:])
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_bare_version_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            self.write_artifacts(
                directory,
                STABLE_TAG,
                name_hook=lambda name: name.replace(STABLE_TAG, STABLE_TAG[1:]),
            )
            result = self.run_assert_step(directory, STABLE_TAG, "0.9.4")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("missing", result.stderr)

    def test_checksum_manifest_lists_tag_names(self):
        for tag in (STABLE_TAG, BETA_TAG):
            with self.subTest(tag=tag):
                with tempfile.TemporaryDirectory() as directory:
                    self.write_artifacts(directory, tag)
                    script = render(
                        step_run_script(WORKFLOW_TEXT, "Generate SHA-256 manifest"),
                        tag=tag,
                        version=tag[1:],
                    )
                    result = subprocess.run(
                        ["bash", "-euo", "pipefail", "-c", script],
                        capture_output=True,
                        text=True,
                        cwd=directory,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    manifest = Path(directory) / CHECKSUM_MANIFEST.format(tag=tag)
                    self.assertTrue(manifest.is_file(), result.stdout)
                    entries = {
                        line.split()[1]
                        for line in manifest.read_text().splitlines()
                        if line.strip()
                    }
                    expected = {
                        name.format(tag=tag) for _, name in ARTIFACTS
                    }
                    self.assertEqual(entries, expected)


if __name__ == "__main__":
    unittest.main()
