#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo_root"

script="website/scripts/netlify-ignore.sh"

run_ignore() {
  if [ ! -x "$script" ]; then
    echo "missing executable ignore script: $script"
    exit 99
  fi

  CONTEXT="$1" COMMIT_REF="$2" CACHED_COMMIT_REF="${3:-}" "$script"
}

test_deploy_preview_builds_when_pr_changes_website() {
  set +e
  run_ignore deploy-preview HEAD
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    echo "expected deploy-preview website changes to build, got ignore"
    exit 1
  fi
}

test_deploy_preview_ignores_when_pr_does_not_change_website() {
  set +e
  run_ignore deploy-preview origin/main
  status=$?
  set -e

  if [ "$status" -ne 0 ]; then
    echo "expected deploy-preview without website changes to ignore, got build"
    exit 1
  fi
}

test_non_preview_uses_cached_commit_diff() {
  set +e
  run_ignore branch-deploy HEAD HEAD
  status=$?
  set -e

  if [ "$status" -ne 0 ]; then
    echo "expected non-preview unchanged cached commit to ignore, got build"
    exit 1
  fi
}

test_deploy_preview_builds_when_pr_changes_website
test_deploy_preview_ignores_when_pr_does_not_change_website
test_non_preview_uses_cached_commit_diff
