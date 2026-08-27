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
change:
    trellis changelog new

# Preview unreleased version bumps and changelog
changelog-preview:
    trellis version plan

# === RELEASE ===

# Apply version bumps and regenerate CHANGELOG.md
version-apply:
    trellis version apply

# Create and push missing release tags
tag:
    trellis tag create --push

# === MAINTENANCE ===

# Remove build artifacts
clean:
    trellis run clean

# Validate workspace invariants
doctor:
    trellis doctor

# === CI ===

# Run all CI checks (format, check, test, build)
ci: format-check check test build-strict

# Alias for PR checks
alias pr := ci

# Run extended checks for main branch
main: ci docs
