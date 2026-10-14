#!/usr/bin/env bash
# AOM development/release controller for Oracle Linux (macOS builds run in CI).
# Requires a GitHub repository-scoped deploy key for git and GitHub Actions
# configured with AOM Dev P12 secrets, an enabled signing variable, and billing.
set -euo pipefail
umask 077

REPO_DIR="${AOM_REPO_DIR:-/data/academic-workspace/projects/all-of-macos}"
MANIFEST="${AOM_RELEASE_MANIFEST:-/data/academic-workspace/projects/aom-release-cache/1.0.11-release-manifest.json}"
REL_API="${AOM_RELEASE_COMMAND:-/home/ubuntu/.local/bin/aom-release}"
PRESIGNED="${AOM_PRESIGNED_COMMAND:-/home/ubuntu/.local/bin/aom-publish-presigned}"
REMOTE="git@github.com:kyw1-2/All-of-MacOS.git"
usage() {
  cat <<'EOF'
Usage: aomctl <doctor|status|sync|commit|push|release|verify-cache>
  doctor               Inspect dependencies and GitHub access (no secret output).
  status               Show local Git state and known release paths.
  sync                 Fetch and fast-forward main (refuses a dirty worktree).
  commit MESSAGE PATH…  Commit explicitly named paths only (never auto-add all).
  push                 Non-force push local main to private GitHub origin.
  release              Push main, or dispatch release.yml when already up-to-date.
  verify-cache         Verify stored 1.0.11 presigned DMG using its manifest.
AOM_REPO_DIR can override the workspace. AOM_RELEASE_MANIFEST overrides cache.
For publishing newly built binaries, GitHub must provide a working macOS runner
and AOM Dev signing secrets. Oracle Linux cannot compile SwiftUI/AppKit.
EOF
}
die() { printf 'AOM ERROR: %s\n' "$*" >&2; exit 1; }
check_repo() {
  [[ -d "$REPO_DIR/.git" ]] || die "No Git repository at $REPO_DIR"
  [[ "$(git -C "$REPO_DIR" remote get-url origin)" == "$REMOTE" ]] ||
    die "Unexpected Git origin: expected private AOM SSH origin"
}
clean() {
  [[ -z "$(git -C "$REPO_DIR" status --porcelain)" ]] ||
    die "Working tree is dirty. Commit or stash changes first."
}
current_main() {
  [[ "$(git -C "$REPO_DIR" branch --show-current)" == "main" ]] ||
    die "Checkout main before syncing or publishing."
}
sync_main() {
  clean
  current_main
  GIT_TERMINAL_PROMPT=0 git -C "$REPO_DIR" fetch --prune origin main
  git -C "$REPO_DIR" merge --ff-only origin/main
}
push_main() {
  clean
  current_main
  # Explicitly refuse non-fast-forward pushes; never force or rewrite a tag.
  GIT_TERMINAL_PROMPT=0 git -C "$REPO_DIR" push origin HEAD:refs/heads/main
}
cmd="${1:-status}"
shift || true
case "$cmd" in
  help|-h|--help) usage ;;
  doctor)
    check_repo
    printf 'repository: %s\n' "$REPO_DIR"
    printf 'commit: %s\n' "$(git -C "$REPO_DIR" rev-parse --short HEAD)"
    for bin in git python3 curl ssh; do
      if command -v "$bin" >/dev/null 2>&1; then
        printf '%s: available\n' "$bin"
      else
        printf '%s: MISSING\n' "$bin"
      fi
    done
    if [[ -r "$HOME/.ssh/aom_github_deploy" ]]; then
      printf 'GitHub deploy key: locally present (remote registration not implied)\n'
    else
      printf 'GitHub deploy key: NOT PROVISIONED\n'
    fi
    if [[ -r "$HOME/.config/aom-release/dispatch-token" ]]; then
      printf 'Actions dispatch credential: locally present (scope not verified)\n'
    else
      printf 'Actions dispatch credential: NOT PROVISIONED\n'
    fi
    if [[ -r "$HOME/.config/aom-release/contents-token" ]]; then
      printf 'Release REST credential: locally present (scope not verified)\n'
    else
      printf 'Release REST credential: NOT PROVISIONED\n'
    fi
    if timeout 15 env GIT_TERMINAL_PROMPT=0 git -C "$REPO_DIR" ls-remote origin HEAD >/dev/null 2>&1; then
      printf 'Private GitHub remote: ACCESS OK\n'
    else
      printf 'Private GitHub remote: ACCESS BLOCKED\n'
    fi
    printf 'macOS build/sign runner: external macOS required; Linux does not provide Xcode\n'
    printf 'macOS workflow: https://github.com/kyw1-2/All-of-MacOS/actions/workflows/release.yml\n'
    ;;
  status)
    check_repo
    git -C "$REPO_DIR" status --short --branch
    printf 'SHA: %s\n' "$(git -C "$REPO_DIR" rev-parse HEAD)"
    printf 'origin: %s\n' "$(git -C "$REPO_DIR" remote get-url origin)"
    printf 'release workflow: https://github.com/kyw1-2/All-of-MacOS/actions/workflows/release.yml\n'
    ;;
  sync)
    check_repo
    sync_main
    ;;
  commit)
    check_repo
    [[ $# -ge 2 ]] || die "Usage: aomctl commit MESSAGE PATH [PATH ...]"
    msg="$1"; shift
    [[ -n "$msg" ]] || die "Empty commit message"
    for p in "$@"; do
      case "$p" in
        *'.p12'*|*'.pem'*|*'.key'*|*'.env'*|*'credential'*|*'token'*)
          die "Refusing likely credential path: $p" ;;
      esac
    done
    git -C "$REPO_DIR" add -- "$@"
    git -C "$REPO_DIR" diff --cached --quiet -- "$@" && die "No staged changes in named paths"
    # Only commit explicitly named paths. Other staging stays out of this commit.
    git -C "$REPO_DIR" commit --only -m "$msg" -- "$@"
    ;;
  push)
    check_repo
    push_main
    ;;
  release)
    check_repo
    clean
    current_main
    before="$(git -C "$REPO_DIR" rev-parse HEAD)"
    # No blind force push. Regular push rejects divergent remote histories.
    push_main
    printf 'Source pushed/verified at %s\n' "$before"
    printf 'An applicable main push starts release.yml automatically.\n'
    printf 'For a manual rebuild/dispatch use: aom-release trigger\n'
    printf 'Requires healthy GitHub billing and AOM_SIGNING_READY=true; check CI before claiming success.\n'
    ;;
  verify-cache)
    [[ -x "$PRESIGNED" ]] || die "Missing $PRESIGNED"
    [[ -r "$MANIFEST" ]] || die "Missing $MANIFEST"
    "$PRESIGNED" verify "$MANIFEST"
    ;;
  *) usage >&2; exit 2 ;;
esac
