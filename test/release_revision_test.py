import copy
import importlib.util
import json
import os
import tempfile
import textwrap
import unittest
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
from unittest.mock import patch
import subprocess

spec = importlib.util.spec_from_file_location(
    "release_revision", Path(__file__).resolve().parents[1] / "scripts/release_revision.py",
)
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)

REPOSITORY = "tylerbutler/aquamarine"
REVISION = "a" * 40
PR = {
    "merged": True,
    "base": {"ref": "main", "repo": {"full_name": REPOSITORY}},
    "head": {"ref": "release/pending", "repo": {"full_name": REPOSITORY}},
    "merge_commit_sha": REVISION,
}


class ReleaseRevisionTest(unittest.TestCase):
    def test_approved_merge(self):
        self.assertEqual(release.approved_revision(PR, REPOSITORY), REVISION)

    def test_rejects_untrusted_prs(self):
        for path, value in [
            (("merged",), False),
            (("base", "ref"), "other"),
            (("base", "repo", "full_name"), "other/repo"),
            (("head", "ref"), "feature"),
            (("head", "repo"), None),
            (("head", "repo", "full_name"), "fork/aquamarine"),
            (("merge_commit_sha",), None),
            (("merge_commit_sha",), "main"),
            (("merge_commit_sha",), REVISION + "\nrevision=main"),
        ]:
            with self.subTest(path=path, value=value):
                pr = copy.deepcopy(PR)
                target = pr
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
                with self.assertRaises(ValueError):
                    release.approved_revision(pr, REPOSITORY)

    def run_event(self, event_name, event, number=""):
        with tempfile.TemporaryDirectory() as directory:
            event_path = Path(directory) / "event.json"
            event_path.write_text(json.dumps(event))
            env = {
                "GITHUB_EVENT_NAME": event_name,
                "GITHUB_EVENT_PATH": str(event_path),
                "GITHUB_REPOSITORY": REPOSITORY,
                "GITHUB_REF": "refs/heads/main",
                "INPUT_RELEASE_PR": number,
            }
            output = StringIO()
            with patch.dict(os.environ, env), redirect_stdout(output):
                release.main()
            return output.getvalue()

    def test_merge_event_never_uses_current_main(self):
        with patch.object(release.subprocess, "run") as run:
            self.assertEqual(
                self.run_event("pull_request", {"action": "closed", "pull_request": PR}),
                f"revision={REVISION}\n",
            )
            run.assert_not_called()

    def test_recovery_resolves_exact_approved_pr(self):
        with patch.object(release.subprocess, "run") as run:
            run.return_value.stdout = json.dumps(PR)
            self.assertEqual(self.run_event("workflow_dispatch", {}, "42"), f"revision={REVISION}\n")
            run.assert_called_once_with(
                ["gh", "api", f"repos/{REPOSITORY}/pulls/42"],
                check=True, capture_output=True, text=True,
            )

    def test_recovery_rejects_invalid_numbers_before_api(self):
        for number in ["", "0", "-1", "42/../1", "$(touch bad)", "42\n"]:
            with self.subTest(number=number), patch.object(release.subprocess, "run") as run:
                with self.assertRaises(ValueError):
                    self.run_event("workflow_dispatch", {}, number)
                run.assert_not_called()

    def test_recovery_rejects_non_main_dispatch(self):
        with patch.dict(os.environ, {"GITHUB_REF": "refs/heads/feature"}):
            with patch.object(release.subprocess, "run") as run:
                env = {"GITHUB_EVENT_NAME": "workflow_dispatch", "GITHUB_REPOSITORY": REPOSITORY}
                with tempfile.TemporaryDirectory() as directory:
                    event_path = Path(directory) / "event.json"
                    event_path.write_text("{}")
                    env["GITHUB_EVENT_PATH"] = str(event_path)
                    with patch.dict(os.environ, env), self.assertRaises(ValueError):
                        release.main()
                run.assert_not_called()

    def test_api_failure_is_not_a_successful_output(self):
        with patch.object(
            release.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "gh"),
        ):
            with self.assertRaises(subprocess.CalledProcessError):
                self.run_event("workflow_dispatch", {}, "42")

    def test_rejects_other_events(self):
        for name, event in [("push", {}), ("pull_request", {"action": "opened"})]:
            with self.subTest(name=name), self.assertRaises(ValueError):
                self.run_event(name, event)

    def test_preparation_passes_inputs_as_arguments(self):
        workflow = (Path(__file__).resolve().parents[1] / ".github/workflows/release.yml").read_text()
        block = workflow.split("        run: |\n", 1)[1].split("\n  tag:", 1)[0]
        command = textwrap.dedent(block)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            executable = path / "trellis"
            executable.write_text("#!/bin/bash\nprintf '%s\\n' \"$@\"\n")
            executable.chmod(0o755)
            output = path / "output"
            env = {
                **os.environ,
                "PATH": f"{path}:{os.environ['PATH']}",
                "GITHUB_OUTPUT": str(output),
                "INPUT_PRE": "$(touch injected); rc",
                "INPUT_VERSION": "0.2.0 --pre none",
            }
            subprocess.run(["bash", "-euo", "pipefail", "-c", command], env=env, cwd=path, check=True)
            self.assertEqual(output.read_text().splitlines(), [
                "release", "pr", "--base", "main", "--branch", "release/pending",
                "--resume", "--auto-pre", "--skip-unchanged",
                "--pre", env["INPUT_PRE"], "--set", f"aquamarine={env['INPUT_VERSION']}",
                "--github-output",
            ])
            self.assertFalse((path / "injected").exists())
            env.update(INPUT_PRE="", INPUT_VERSION="")
            subprocess.run(["bash", "-euo", "pipefail", "-c", command], env=env, cwd=path, check=True)
            self.assertEqual(output.read_text().splitlines()[-10:], [
                "release", "pr", "--base", "main", "--branch", "release/pending",
                "--resume", "--auto-pre", "--skip-unchanged", "--github-output",
            ])


if __name__ == "__main__":
    unittest.main()
