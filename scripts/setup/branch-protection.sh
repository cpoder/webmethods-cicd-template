#!/usr/bin/env bash
# scripts/setup/branch-protection.sh
#
# Idempotent bootstrap for branch protection on `main`. Codifies the
# rules described in docs/branch-protection.md so the configuration
# lives in version control instead of clickops:
#
#   - require pull request review with >= 1 approval
#   - require code-owner review (CODEOWNERS bumps `/config/prod/` to >= 2)
#   - dismiss stale approvals on new commits
#   - require last push to be approved (post-approval push triggers re-review)
#   - require status check `gate` (the orchestrator's aggregator job)
#   - require strictly up-to-date branches
#   - require linear history (no merge commits)
#   - require signed commits
#   - block force-pushes and branch deletion
#   - restrict who can push to `main` to a release bot (App / user / team)
#   - enforce admins (no admin bypass)
#
# The PUT to `/branches/:b/protection` is upsert in the GitHub API, so
# re-running the script is safe. `required_signatures` lives behind a
# separate sub-resource (POST/DELETE), and the script enables it
# idempotently by tolerating "already enabled" responses.
#
# Usage:
#   scripts/setup/branch-protection.sh                # dry-run (default)
#   scripts/setup/branch-protection.sh --apply ...    # apply changes
#   scripts/setup/branch-protection.sh --show         # GET current state
#   scripts/setup/branch-protection.sh --remove       # tear down (rare)
#
# Restriction modifiers (at least one is required for --apply unless
# --no-restrict-pushers is passed):
#   --bot-app    <slug>    GitHub App slug allowed to push to main
#                          (e.g. `release-bot`). Repeatable.
#   --bot-user   <login>   GitHub user login allowed to push. Repeatable.
#   --bot-team   <slug>    Team slug (not org/slug -- just slug) allowed
#                          to push. Repeatable.
#   --no-restrict-pushers  Skip the `restrictions` block entirely. Only
#                          use for repos that genuinely allow any
#                          maintainer to push to main; the task spec
#                          requires a release-bot restriction in the
#                          default deployment.
#
# Other modifiers:
#   --branch        <name>   Default: main
#   --gate-check    <name>   Status check context name. Default: gate
#                            (matches `name: gate` in
#                            .github/workflows/ci.yml).
#   --approvals     <N>      Minimum approving reviews. Default: 1.
#                            CODEOWNERS implicitly bumps changes
#                            touching `/config/prod/` to >= 2 because
#                            `require_code_owner_reviews:true` makes
#                            every distinct owners rule contribute its
#                            own required approval.
#   --no-signatures          Skip the signed-commits sub-call (escape
#                            hatch for environments that cannot enforce
#                            this yet).
#
# Environment overrides:
#   REPO_SLUG     owner/repo (auto-detected via `gh repo view` if unset)
#
# Exit codes:
#   0  success / dry-run completed / --show printed state
#   1  bad args / missing tool / gh API call failed
#   2  --remove failed verification (protection still present)
#
# This script is meant to be run by a repo admin (only admins can edit
# branch protection). It does NOT need any GitHub Secrets to function.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)

# ---------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------
MODE=dry-run                        # dry-run | apply | show | remove
BRANCH=main
GATE_CHECK=gate
APPROVALS=1
APPLY_SIGNATURES=1
APPLY_RESTRICTIONS=1
declare -a BOT_APPS=()
declare -a BOT_USERS=()
declare -a BOT_TEAMS=()

# ---------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------
usage() {
    # Print the file header (line 2 of the filtered set onward, up to
    # the first non-comment-non-blank line) by stripping `# ` prefixes
    # and stopping at the first line that doesn't start with `#`.
    awk '
        NR == 1 { next }                       # skip shebang
        /^#/    { sub(/^# ?/, ""); print; next }
        /^$/    { exit }
        { exit }
    ' "$0"
}

while (( $# > 0 )); do
    case "$1" in
        --apply)               MODE=apply; shift ;;
        --show)                MODE=show; shift ;;
        --remove)              MODE=remove; shift ;;
        --bot-app)             BOT_APPS+=("$2"); shift 2 ;;
        --bot-user)            BOT_USERS+=("$2"); shift 2 ;;
        --bot-team)            BOT_TEAMS+=("$2"); shift 2 ;;
        --no-restrict-pushers) APPLY_RESTRICTIONS=0; shift ;;
        --no-signatures)       APPLY_SIGNATURES=0; shift ;;
        --branch)              BRANCH=$2; shift 2 ;;
        --gate-check)          GATE_CHECK=$2; shift 2 ;;
        --approvals)           APPROVALS=$2; shift 2 ;;
        -h|--help)             usage; exit 0 ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 1 ;;
    esac
done

# ---------------------------------------------------------------------
# Tool / auth preflight
# ---------------------------------------------------------------------
require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "ERROR: $1 not found on PATH (required by $(basename "$0"))" >&2
        exit 1
    fi
}
require_tool gh
require_tool jq

# `--show` and `dry-run` don't strictly need an authenticated `gh`
# (dry-run only prints the body it would send), but `--show` needs the
# token to read protection state and `--apply`/`--remove` need admin
# scope. Be loud about it up front.
if [[ "$MODE" != "dry-run" ]]; then
    if ! gh auth status >/dev/null 2>&1; then
        echo "ERROR: gh is not authenticated. Run 'gh auth login' first." >&2
        exit 1
    fi
fi

# Resolve owner/repo. Allow REPO_SLUG override (useful in CI / dry-run
# without a configured remote yet).
if [[ -z "${REPO_SLUG:-}" ]]; then
    if ! REPO_SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null); then
        if [[ "$MODE" == "dry-run" ]]; then
            REPO_SLUG="<owner>/<repo>"
        else
            echo "ERROR: could not determine repo (set REPO_SLUG=owner/name)" >&2
            exit 1
        fi
    fi
fi

echo "repo:           ${REPO_SLUG}"
echo "branch:         ${BRANCH}"
echo "gate check:     ${GATE_CHECK}"
echo "approvals:      ${APPROVALS}"
echo "mode:           ${MODE}"
echo

# ---------------------------------------------------------------------
# Body builders
# ---------------------------------------------------------------------

# JSON body for PUT /repos/:o/:r/branches/:b/protection.
#
# `enforce_admins:true` means the protections also block admins. This
# is intentional -- the whole point is that even repo admins must go
# through a PR. `required_signatures` is NOT a top-level field on this
# endpoint; it has its own sub-resource (handled below).
build_protection_body() {
    local restrictions_json
    if (( APPLY_RESTRICTIONS == 1 )); then
        # `null` means "no restrictions". Empty arrays mean "nobody can
        # push at all". We want the latter for users/teams and the
        # configured app(s) in apps[].
        restrictions_json=$(jq -n \
            --argjson users "$(printf '%s\n' "${BOT_USERS[@]:-}" \
                | jq -R 'select(length>0)' | jq -s .)" \
            --argjson teams "$(printf '%s\n' "${BOT_TEAMS[@]:-}" \
                | jq -R 'select(length>0)' | jq -s .)" \
            --argjson apps "$(printf '%s\n' "${BOT_APPS[@]:-}" \
                | jq -R 'select(length>0)' | jq -s .)" \
            '{users: $users, teams: $teams, apps: $apps}')
    else
        restrictions_json=null
    fi

    jq -n \
        --argjson approvals "$APPROVALS" \
        --arg gate "$GATE_CHECK" \
        --argjson restrictions "$restrictions_json" \
        '{
            required_status_checks: {
                strict: true,
                contexts: [$gate]
            },
            enforce_admins: true,
            required_pull_request_reviews: {
                dismiss_stale_reviews: true,
                require_code_owner_reviews: true,
                required_approving_review_count: $approvals,
                require_last_push_approval: true
            },
            restrictions: $restrictions,
            required_linear_history: true,
            allow_force_pushes: false,
            allow_deletions: false,
            block_creations: false,
            required_conversation_resolution: true,
            lock_branch: false,
            allow_fork_syncing: false
        }'
}

# ---------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------

# `--apply` requires at least one push principal unless explicitly
# opted out, otherwise GitHub will reject the request with HTTP 422
# ("must specify at least one of users, teams, apps").
validate_apply_args() {
    if (( APPLY_RESTRICTIONS == 1 )); then
        if (( ${#BOT_APPS[@]} == 0 && ${#BOT_USERS[@]} == 0 && ${#BOT_TEAMS[@]} == 0 )); then
            echo "ERROR: --apply requires --bot-app / --bot-user / --bot-team," >&2
            echo "       OR pass --no-restrict-pushers to skip the restriction." >&2
            echo "       The task spec requires the release bot to be the only" >&2
            echo "       principal allowed to push to ${BRANCH}." >&2
            exit 1
        fi
    fi
}

# ---------------------------------------------------------------------
# API helpers
# ---------------------------------------------------------------------

# PUT the protection body. Idempotent at the GH API level.
apply_protection() {
    local body=$1
    gh api -X PUT \
        -H "Accept: application/vnd.github+json" \
        "/repos/${REPO_SLUG}/branches/${BRANCH}/protection" \
        --input - <<<"$body" >/dev/null
    echo "  applied:  PUT /repos/${REPO_SLUG}/branches/${BRANCH}/protection"
}

# Enable required signed commits. POST is idempotent by GH (returns
# 200 if already enabled, 201 on first enable). 4xx is a real error.
apply_signatures() {
    local out
    if out=$(gh api -X POST \
        -H "Accept: application/vnd.github+json" \
        "/repos/${REPO_SLUG}/branches/${BRANCH}/protection/required_signatures" \
        2>&1); then
        echo "  applied:  POST /repos/${REPO_SLUG}/branches/${BRANCH}/protection/required_signatures"
    else
        # Some GH versions return a non-2xx when already enabled; check
        # by re-reading state instead of assuming the error is fatal.
        if signatures_enabled; then
            echo "  applied:  required_signatures already enabled (idempotent no-op)"
        else
            echo "ERROR: failed to enable required_signatures: $out" >&2
            exit 1
        fi
    fi
}

# Read current required_signatures state (true|false).
signatures_enabled() {
    gh api \
        -H "Accept: application/vnd.github+json" \
        "/repos/${REPO_SLUG}/branches/${BRANCH}/protection/required_signatures" \
        --jq '.enabled' 2>/dev/null \
        | grep -qx true
}

# Read full protection state. Returns 0 even if not protected (the API
# returns 404 in that case, which the caller can detect).
show_protection() {
    if ! gh api \
        -H "Accept: application/vnd.github+json" \
        "/repos/${REPO_SLUG}/branches/${BRANCH}/protection" 2>/dev/null \
        | jq .; then
        echo "(no protection rules currently configured on ${BRANCH})" >&2
        return 0
    fi
    if signatures_enabled; then
        echo "required_signatures: enabled"
    else
        echo "required_signatures: disabled"
    fi
}

# DELETE the protection. Tolerates 404 (already gone).
remove_protection() {
    if gh api -X DELETE \
        -H "Accept: application/vnd.github+json" \
        "/repos/${REPO_SLUG}/branches/${BRANCH}/protection" >/dev/null 2>&1; then
        echo "  removed:  protection on ${BRANCH}"
    else
        # If it was already absent, GH returns 404. Verify by GET.
        if ! gh api \
            -H "Accept: application/vnd.github+json" \
            "/repos/${REPO_SLUG}/branches/${BRANCH}/protection" >/dev/null 2>&1; then
            echo "  removed:  no protection was configured (already absent)"
        else
            echo "ERROR: failed to remove protection on ${BRANCH}" >&2
            exit 2
        fi
    fi
}

# ---------------------------------------------------------------------
# Mode dispatch
# ---------------------------------------------------------------------
case "$MODE" in
    show)
        show_protection
        ;;

    dry-run)
        echo "Would PUT /repos/${REPO_SLUG}/branches/${BRANCH}/protection with body:"
        body=$(build_protection_body)
        jq . <<<"$body" | sed 's/^/  /'
        echo
        if (( APPLY_SIGNATURES == 1 )); then
            echo "Would POST /repos/${REPO_SLUG}/branches/${BRANCH}/protection/required_signatures"
            echo
        fi
        if (( APPLY_RESTRICTIONS == 1 )) \
           && (( ${#BOT_APPS[@]} == 0 && ${#BOT_USERS[@]} == 0 && ${#BOT_TEAMS[@]} == 0 )); then
            echo "WARNING: no --bot-app / --bot-user / --bot-team supplied."
            echo "         --apply will refuse to run until at least one is given,"
            echo "         OR --no-restrict-pushers is passed to bypass the"
            echo "         release-bot restriction (not recommended)."
            echo
        fi
        echo "Re-run with --apply (and the same modifiers) to commit these changes."
        ;;

    apply)
        validate_apply_args
        body=$(build_protection_body)
        apply_protection "$body"
        if (( APPLY_SIGNATURES == 1 )); then
            apply_signatures
        else
            echo "  skipped:  required_signatures (--no-signatures)"
        fi
        echo
        echo "Done. Run with --show to verify."
        ;;

    remove)
        remove_protection
        ;;

    *)
        echo "ERROR: unknown mode: $MODE" >&2
        exit 1 ;;
esac
