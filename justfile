# Gleam Project Tasks

# === ALIASES ===
alias b := build
alias t := test
alias f := format
alias c := check
alias d := docs
alias cl := change

default:
    @just --list

# === DEPENDENCIES ===

# Download project dependencies
deps:
    trellis run deps

# === BUILD ===

# Build project (Erlang target)
build:
    trellis run build

# Build with warnings as errors
build-strict:
    trellis run build --strict

# === TESTING ===

# Run all tests
test:
    trellis run test

# Check release trust boundaries without remote writes
test-release:
    python3 -B -m unittest discover -s test -p '*_test.py'

# === CODE QUALITY ===

# Format source code
format:
    trellis run format

# Check formatting without changes
format-check:
    trellis run format --check

# Type check without building
check:
    trellis run check

# === DOCUMENTATION ===

# Build documentation
docs:
    trellis run docs

# === CHANGELOG ===

# Create a new changelog entry
[positional-arguments]
change *ARGS:
    trellis changelog new "$@"

# Preview unreleased version bumps and changelog
[positional-arguments]
changelog-preview *ARGS:
    trellis version plan "$@"

# === RELEASE ===

# Apply version bumps and regenerate CHANGELOG.md
[positional-arguments]
version-apply *ARGS:
    trellis version apply "$@"

# Create/update the release PR; preserve pending intent and candidate mode
[positional-arguments]
release-pr *ARGS:
    trellis release pr --base main --branch release/pending --resume --auto-pre --skip-unchanged "$@"

# Preview tags without creating or pushing them
tag-plan:
    trellis tag plan

# Create/push missing tags and GitHub releases; run only at an approved release merge
tag:
    trellis tag create --github-release

# === MAINTENANCE ===

# Remove build artifacts
clean:
    trellis run clean

# Validate workspace invariants
doctor:
    trellis doctor

# === CI ===

# Run all CI checks (format, check, tests, build, workspace)
ci: format-check check test test-release build-strict doctor

# Alias for PR checks
alias pr := ci

# Run extended checks for main branch
main: ci docs
