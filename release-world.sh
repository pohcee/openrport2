#!/bin/bash

# Commits all pending work across the openrport submodules, then releases each
# one in order: server, pairing, website, scripts, then the root superproject.
#
# "Releasing" a module doesn't build/publish anything itself here - it pushes
# a version tag (server, pairing, website) or runs release-it (scripts), which
# is what actually triggers each repo's existing GitHub Actions release
# workflow (goreleaser for server/pairing, a zip+GitHub-release job for
# website, release-it's own GitHub release for scripts). We defer to those
# workflows rather than reimplementing goreleaser/build steps locally, per
# each repo's own .github/workflows/release.yml.
#
# Side effects worth knowing about, since they're not obvious from this
# script alone:
#   - server: pushing a tag also fires release-msi.yml (Windows MSI, tag
#     push). Pushing commits to main fires deploy.yml (demo-server SSH
#     deploy) and test-build.yml/lint.yml (any push).
#   - website: pushing commits to main fires alpha-release.yml (automatic
#     alpha GitHub release on every main push) and format-build-frontend.yaml,
#     in addition to release.yml firing on the version tag we push.
#   - pairing: release.yml deploys the built binary to a public pairing
#     service via SSH as part of the same tag-triggered job.
#
# Commit messages for pending code changes are generated per module by
# `gemit` (Gemini-backed) - see gemini-cli-helpers/scripts/gemit.sh. Version
# bump commits (website's package.json, and anything release-it does for
# scripts) are not run through gemit - those get deterministic/tool-generated
# messages instead.

set -e

show_help() {
  cat << EOF
Usage: $0 [-n|--dry-run]

Commits all pending work across server, pairing, website, and scripts (each
its own git submodule) using gemit, then releases each one in order:

  - server, pairing (Go, goreleaser): run the module's tests, tag the next
    patch version (bumped from the latest existing tag), and push commits +
    tag with 'git push --follow-tags'. The tag push triggers that repo's
    goreleaser-based release.yml on GitHub, which builds and publishes the
    actual release.
  - website (Nuxt): run tests if a "test" script is defined (currently none -
    the codebase has no test suite, and its ~500 pre-existing lint errors
    make lint impractical as a pass/fail gate), bump the patch version in
    package.json, commit that bump, tag
    'vX.Y.Z', and push. The tag triggers release.yml (builds + publishes a
    GitHub release); the push to main also triggers alpha-release.yml.
  - scripts (npm/release-it): run 'npm run release' (release-it), which
    handles its own version bump, changelog, tag, GitHub release, and push.

A module with no pending changes AND no unpushed local commits is skipped
entirely. A module with unpushed commits but nothing currently dirty still
goes through tests + release, since otherwise those commits would never
reach a release.

After all four modules are processed, the root superproject is committed
(submodule pointer updates plus any other root-level files) via 'gemit -a'.
That commit is NOT pushed - review it and push manually, same as each
module's own commits/tags already were pushed individually above.

WARNING: this pushes real version tags and triggers each repo's production
release workflow on GitHub (building installers/packages, creating GitHub
releases, and in pairing's case, deploying to a live pairing service via
SSH). This is not easily undone. A single confirmation prompt is shown
before anything happens.

Options:
  -n, --dry-run  Preview commit messages (gemit -p), print what version
                 would be tagged and what test command would run (without
                 actually running server/pairing/website's tests - server's
                 suite in particular is slow and spins up real local
                 listeners), and show release-it's own --dry-run preview for
                 scripts. Nothing is committed, tagged, released, or pushed,
                 and the confirmation prompt is skipped.
  -h, --help     Show this help message and exit
EOF
}

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      show_help
      exit 0
      ;;
    -n|--dry-run)
      DRY_RUN=true
      ;;
    *)
      echo "Unknown option: $arg"
      show_help
      exit 1
      ;;
  esac
done

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GEMIT="/home/jason/code/gemini-cli-helpers/scripts/gemit.sh"

if [ ! -x "$GEMIT" ]; then
  echo "gemit script not found or not executable at $GEMIT" >&2
  exit 1
fi

if ! command -v jq &> /dev/null; then
  echo "jq is required (used to read/bump website/package.json) but was not found." >&2
  exit 1
fi

MODULES=(server pairing website scripts)

has_changes() {
  [ -n "$(git -C "$1" status --porcelain)" ]
}

# True if $1's repo has local commits not yet on its upstream branch.
has_unpushed() {
  local count
  count=$(git -C "$1" rev-list --count '@{u}..HEAD' 2>/dev/null) || return 1
  [ "${count:-0}" -gt 0 ]
}

# Dirtiness/unpushed snapshot taken up front, before anything is committed -
# a live check on server after its own commit would come back clean, but
# that doesn't mean pairing/website/scripts should be skipped.
declare -A DIRTY UNPUSHED
for m in "${MODULES[@]}"; do
  if has_changes "$PROJECT_ROOT/$m"; then DIRTY[$m]=1; else DIRTY[$m]=0; fi
  if has_unpushed "$PROJECT_ROOT/$m"; then UNPUSHED[$m]=1; else UNPUSHED[$m]=0; fi
done

needs_release() {
  [ "${DIRTY[$1]}" = 1 ] || [ "${UNPUSHED[$1]}" = 1 ]
}

# $1.$2.$3 -> $1.$2.$(($3+1)), stripping an optional leading 'v' first.
bump_patch() {
  local v="${1#v}" major minor patch
  IFS='.' read -r major minor patch <<< "$v"
  echo "$major.$minor.$((patch + 1))"
}

# Highest bare X.Y.Z tag (no 'v' prefix) in $1, or empty if none exist.
# Restricted to the bare form since that's the convention each of these two
# repos' tags have settled on (server has none prefixed; pairing has one
# legacy 'v0.1.0' tag that predates its own switch away from the prefix).
latest_bare_semver_tag() {
  git -C "$1" tag --list \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -t. -k1,1n -k2,2n -k3,3n \
    | tail -1
}

next_go_version() {
  local latest
  latest="$(latest_bare_semver_tag "$1")"
  bump_patch "${latest:-0.0.0}"
}

website_current_version() {
  jq -r .version "$PROJECT_ROOT/website/package.json"
}

website_next_version() {
  bump_patch "$(website_current_version)"
}

run_tests_server() {
  (cd "$PROJECT_ROOT/server" && make test)
}

run_tests_pairing() {
  (cd "$PROJECT_ROOT/pairing" && go test -race ./...)
}

# Description of what run_tests_website would do, for status/dry-run output.
# Deliberately doesn't fall back to 'yarn lint' when no test script exists:
# the codebase currently carries ~500 pre-existing lint errors unrelated to
# any given release, so treating lint as a pass/fail gate here would block
# every release on unrelated debt instead of testing what's changing.
website_test_description() {
  if grep -q '"test"' "$PROJECT_ROOT/website/package.json"; then
    echo "yarn test"
  else
    echo "(no test script defined, nothing to run)"
  fi
}

run_tests_website() {
  if grep -q '"test"' "$PROJECT_ROOT/website/package.json"; then
    (cd "$PROJECT_ROOT/website" && yarn test)
  else
    echo "website: no test script defined, skipping."
  fi
}

ensure_scripts_release_deps() {
  if [ ! -x "$PROJECT_ROOT/scripts/node_modules/.bin/release-it" ]; then
    echo "release-it not found in scripts/node_modules, running npm install..."
    (cd "$PROJECT_ROOT/scripts" && npm install)
  fi
}

# --- release steps (real, not dry-run) ---------------------------------

release_go_module() {
  local mod="$1" test_fn="$2" path="$PROJECT_ROOT/$1"
  if [ "${DIRTY[$mod]}" = 1 ]; then
    (cd "$path" && "$GEMIT" -a)
  fi
  if ! needs_release "$mod"; then
    echo "$mod: no pending changes and nothing unpushed, skipping."
    return
  fi
  echo "$mod: running tests..."
  "$test_fn"
  local next
  next="$(next_go_version "$path")"
  echo "$mod: tagging $next"
  (cd "$path" && git tag -a "$next" -m "$next")
  echo "$mod: pushing commits + tag (triggers GitHub release workflow)..."
  (cd "$path" && git push origin HEAD --follow-tags)
}

release_website() {
  local path="$PROJECT_ROOT/website"
  if [ "${DIRTY[website]}" = 1 ]; then
    (cd "$path" && "$GEMIT" -a)
  fi
  if ! needs_release website; then
    echo "website: no pending changes and nothing unpushed, skipping."
    return
  fi
  run_tests_website
  local next tag tmp
  next="$(website_next_version)"
  tag="v$next"
  echo "website: bumping package.json version to $next and tagging $tag"
  tmp="$(mktemp)"
  jq --arg v "$next" '.version = $v' "$path/package.json" > "$tmp"
  mv "$tmp" "$path/package.json"
  (cd "$path" && git add package.json && git commit -m "chore(release): $tag")
  (cd "$path" && git tag -a "$tag" -m "$tag")
  echo "website: pushing commits + tag (triggers release.yml + alpha-release.yml)..."
  (cd "$path" && git push origin HEAD --follow-tags)
}

release_scripts() {
  local path="$PROJECT_ROOT/scripts"
  if [ "${DIRTY[scripts]}" = 1 ]; then
    (cd "$path" && "$GEMIT" -a)
  fi
  if ! needs_release scripts; then
    echo "scripts: no pending changes and nothing unpushed, skipping."
    return
  fi
  ensure_scripts_release_deps
  echo "scripts: running npm run release (release-it: version, changelog, tag, GitHub release, push)..."
  (cd "$path" && npm run release)
}

# --- dry-run reporting ---------------------------------------------------

dry_run_module() {
  local m="$1"
  echo ""
  echo "--- $m ---"
  if [ "${DIRTY[$m]}" = 1 ]; then
    echo "Pending changes detected. Commit preview:"
    (cd "$PROJECT_ROOT/$m" && "$GEMIT" -p)
  elif [ "${UNPUSHED[$m]}" = 1 ]; then
    echo "No pending changes, but local commits are unpushed - would still release."
  else
    echo "No changes, nothing unpushed - would skip."
    return
  fi
  case "$m" in
    server)
      echo "Would run: make test (go test -race -v ./... - not executed in dry run, it's slow and side-effecting)"
      echo "Would tag: $(next_go_version "$PROJECT_ROOT/server") (latest existing: $(latest_bare_semver_tag "$PROJECT_ROOT/server"))"
      echo "Would push commits + tag to trigger release.yml/release-msi.yml on GitHub."
      ;;
    pairing)
      echo "Would run: go test -race ./..."
      echo "Would tag: $(next_go_version "$PROJECT_ROOT/pairing") (latest existing: $(latest_bare_semver_tag "$PROJECT_ROOT/pairing"))"
      echo "Would push commits + tag to trigger release.yml on GitHub."
      ;;
    website)
      echo "Would run: $(website_test_description)"
      echo "Would bump package.json version to $(website_next_version) and tag v$(website_next_version)"
      echo "Would push commits + tag, triggering release.yml and alpha-release.yml on GitHub."
      ;;
    scripts)
      echo "Would run: npm run release (release-it) - showing release-it's own dry run:"
      if [ -x "$PROJECT_ROOT/scripts/node_modules/.bin/release-it" ]; then
        (cd "$PROJECT_ROOT/scripts" && npx release-it --dry-run)
      else
        echo "(release-it not installed yet in scripts/node_modules - run 'npm install' there, or a real run will do it automatically)"
      fi
      ;;
  esac
}

# --- main -----------------------------------------------------------------

echo "--- release-world.sh ---"
if [ "$DRY_RUN" = true ]; then
  echo "DRY RUN: no commits, tags, releases, or pushes will actually happen."
else
  echo "Commit messages will be generated per module by gemit (Gemini)."
fi
echo ""
echo "Release order: ${MODULES[*]}, then root"
echo ""

if [ "$DRY_RUN" = true ]; then
  for m in "${MODULES[@]}"; do
    dry_run_module "$m"
  done
  echo ""
  echo "--- root ---"
  (cd "$PROJECT_ROOT" && "$GEMIT" -p)
  echo ""
  echo "=== Dry run complete. Nothing was committed, tagged, released, or pushed. ==="
  exit 0
fi

for m in "${MODULES[@]}"; do
  if [ "${DIRTY[$m]}" = 1 ]; then
    echo "  - $m (pending changes, will commit + release)"
  elif [ "${UNPUSHED[$m]}" = 1 ]; then
    echo "  - $m (no pending changes, unpushed commits found, will release)"
  else
    echo "  - $m (no changes, will skip)"
  fi
done
echo ""
echo "Each released module pushes a real version tag and triggers that repo's"
echo "production release workflow on GitHub (goreleaser builds, GitHub"
echo "releases, and in pairing's case a live SSH deploy). This cannot be"
echo "easily undone."
echo ""
read -p "Proceed? [y/N] " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 1
fi

echo ""
echo "=== Processing server ==="
release_go_module server run_tests_server

echo ""
echo "=== Processing pairing ==="
release_go_module pairing run_tests_pairing

echo ""
echo "=== Processing website ==="
release_website

echo ""
echo "=== Processing scripts ==="
release_scripts

echo ""
echo "=== Committing root superproject (submodule pointer updates) ==="
(cd "$PROJECT_ROOT" && "$GEMIT" -a)

echo ""
echo "NOTE: nothing was pushed from the root superproject. Each module's tag"
echo "push above already triggered its own release; the root commit here"
echo "(updated submodule pointers) is left for you to review and push"
echo "manually."
echo ""
echo "=== release-world.sh complete ==="
