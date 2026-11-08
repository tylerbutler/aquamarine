"""Resolve only the immutable merge revision of a trusted release PR."""

import json
import os
import re
import subprocess
from pathlib import Path


def approved_revision(pr, repository):
    if not (
        pr.get("merged") is True
        and pr.get("base", {}).get("ref") == "main"
        and pr.get("base", {}).get("repo", {}).get("full_name") == repository
        and pr.get("head", {}).get("ref") == "release/pending"
        and (pr.get("head", {}).get("repo") or {}).get("full_name") == repository
    ):
        raise ValueError("Release requires a merged, same-repository release/pending PR to main.")
    revision = pr.get("merge_commit_sha") or ""
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Release PR has no valid immutable merge revision.")
    return revision


def main():
    event_name = os.environ["GITHUB_EVENT_NAME"]
    repository = os.environ["GITHUB_REPOSITORY"]
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    if event_name == "workflow_dispatch":
        if os.environ["GITHUB_REF"] != "refs/heads/main":
            raise ValueError("Run release recovery on main.")
        number = os.environ.get("INPUT_RELEASE_PR", "")
        if not re.fullmatch(r"[1-9][0-9]*", number):
            raise ValueError("Recovery requires a positive release PR number.")
        pr = json.loads(subprocess.run(
            ["gh", "api", f"repos/{repository}/pulls/{number}"],
            check=True, capture_output=True, text=True,
        ).stdout)
    elif event_name == "pull_request" and event.get("action") == "closed":
        pr = event["pull_request"]
    else:
        raise ValueError("Only a closed release PR or manual recovery can create tags.")
    print(f"revision={approved_revision(pr, repository)}")


if __name__ == "__main__":
    main()
