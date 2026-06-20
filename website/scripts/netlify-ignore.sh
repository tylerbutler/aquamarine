#!/bin/sh
set -eu

website_path="website/"
base_branch="${NETLIFY_BASE_BRANCH:-main}"
commit_ref="${COMMIT_REF:-HEAD}"

if [ "${CONTEXT:-}" = "deploy-preview" ]; then
  git fetch --quiet origin "refs/heads/$base_branch:refs/remotes/origin/$base_branch"
  git diff --quiet "refs/remotes/origin/$base_branch...$commit_ref" -- "$website_path"
  exit $?
fi

if [ -n "${CACHED_COMMIT_REF:-}" ]; then
  git diff --quiet "$CACHED_COMMIT_REF" "$commit_ref" -- "$website_path"
  exit $?
fi

exit 1
