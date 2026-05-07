#!/usr/bin/env bash
# scripts/setup-environments.sh
#
# Idempotent bootstrap for the GitHub Environments documented in
# docs/secrets.md. Creates dev/test/prod environments, applies the
# prod protection rules (required reviewers + wait timer), and
# (optionally) audits which matrix-listed secrets are missing per env.
#
# This script does NOT set secret values. Values are seeded manually
# with `gh secret set <NAME> --env <env>` so the secret material never
# passes through a local checkout / shell history of this script.
#
# Usage:
#   scripts/setup-environments.sh                # dry-run (default)
#   scripts/setup-environments.sh --apply        # create envs + prod gate
#   scripts/setup-environments.sh --list         # print existing envs
#   scripts/setup-environments.sh --check        # audit secret presence
#
# Modifiers (only apply with --apply):
#   --prod-reviewer-user <login>     GitHub username; resolved to numeric id.
#                                    Repeatable.
#   --prod-reviewer-team <org/slug>  e.g. my-org/release-managers. Repeatable.
#   --prod-wait-minutes <N>          Wait timer in minutes (default: 10).
#
# At least one --prod-reviewer-user OR --prod-reviewer-team is required
# for --apply.
#
# Environment overrides:
#   REPO_SLUG     owner/repo (auto-detected from `gh repo view` if unset)
#   ENVIRONMENTS  space-separated env list (default "dev test prod")
#
# Exit codes:
#   0  success / dry-run completed / --check found nothing missing
#   1  bad args / missing tool / gh API call failed
#   2  --check found one or more missing secrets

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)

# ---------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------
MODE=dry-run                            # dry-run | apply | list | check
ENVIRONMENTS="${ENVIRONMENTS:-dev test prod}"
PROD_WAIT_MINUTES=10
declare -a PROD_REVIEWER_USERS=()
declare -a PROD_REVIEWER_TEAMS=()

# ---------------------------------------------------------------------
# Secret matrix - kept in sync with docs/secrets.md by reviewer
# discipline. Every name here must appear in docs/secrets.md and
# vice versa. Add a new row here whenever a new password_secret_ref /
# secret_ref / sasl_password_secret_ref / *_truststore_secret_ref shows
# up in config/base/.
# ---------------------------------------------------------------------
SECRETS_COMMON=(
    MSR_ADMIN_USER
    MSR_ADMIN_PASSWORD
    TARGET_HOST
    TARGET_KUBECONFIG_B64
    REGISTRY_USER
    REGISTRY_TOKEN
    DB_PASSWORD_ORDERS_DB
    DB_PASSWORD_AUDIT_DB
    KAFKA_SASL_PASSWORD_EVENTS_CLUSTER
    KAFKA_SSL_TRUSTSTORE_EVENTS_CLUSTER
    MQTT_PASSWORD_IOT_INGEST
    MQTT_SSL_TRUSTSTORE_IOT_INGEST
    JMS_PASSWORD_UM_DEFAULT
    JMS_PASSWORD_LEGACY_MQ
    USER_PASSWORD_WM_DEPLOY_BOT
    USER_PASSWORD_WM_OPS_BOT
    GV_API_TOKEN
)
# Vault bootstrap secrets are documented as optional in docs/secrets.md
# (only required when *_secret_ref: vault://... is in use). They are not
# included in the audit by default; flip CHECK_VAULT_SECRETS=1 to
# include them.
SECRETS_VAULT=(
    VAULT_ADDR
    VAULT_ROLE_ID
    VAULT_SECRET_ID
)

# ---------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------
usage() {
    sed -n 's/^# \{0,1\}//p' "$0" | sed -n '2,35p'
}

while (( $# > 0 )); do
    case "$1" in
        --apply)                MODE=apply; shift ;;
        --list)                 MODE=list; shift ;;
        --check)                MODE=check; shift ;;
        --prod-reviewer-user)   PROD_REVIEWER_USERS+=("$2"); shift 2 ;;
        --prod-reviewer-team)   PROD_REVIEWER_TEAMS+=("$2"); shift 2 ;;
        --prod-wait-minutes)    PROD_WAIT_MINUTES=$2; shift 2 ;;
        -h|--help)              usage; exit 0 ;;
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

if ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: gh is not authenticated. Run 'gh auth login' first." >&2
    exit 1
fi

# Resolve owner/repo. Allow REPO_SLUG override (useful in CI / new repo
# without a configured remote yet).
if [[ -z "${REPO_SLUG:-}" ]]; then
    if ! REPO_SLUG=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null); then
        echo "ERROR: could not determine repo (set REPO_SLUG=owner/name)" >&2
        exit 1
    fi
fi
REPO_OWNER="${REPO_SLUG%%/*}"
REPO_NAME="${REPO_SLUG##*/}"

echo "repo:           ${REPO_SLUG}"
echo "environments:   ${ENVIRONMENTS}"
echo "mode:           ${MODE}"
echo

# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

# Resolve a GitHub username to a numeric id (required by the protection
# rules API).
resolve_user_id() {
    local login=$1
    gh api -H "Accept: application/vnd.github+json" "/users/${login}" \
        --jq .id
}

# Resolve org/slug to a numeric team id.
resolve_team_id() {
    local org_slug=$1
    local org=${org_slug%%/*}
    local slug=${org_slug##*/}
    gh api -H "Accept: application/vnd.github+json" \
        "/orgs/${org}/teams/${slug}" --jq .id
}

# List existing environments (one per line).
list_environments() {
    gh api -H "Accept: application/vnd.github+json" \
        "/repos/${REPO_SLUG}/environments" --jq '.environments[].name'
}

# Build the JSON body for PUT /repos/.../environments/<env>.
# Empty body == no protection rules. Prod gets reviewers + wait timer.
#
# Args:
#   $1  env name (dev|test|prod|...)
#   $2  strict (1 == fail if prod has no reviewers configured;
#                0 == emit a planning preview body with empty reviewers
#                so dry-run can show the shape without requiring auth-y
#                lookups against the GitHub user/team API)
build_env_body() {
    local env=$1
    local strict=${2:-1}
    if [[ "$env" != "prod" ]]; then
        echo '{}'
        return
    fi

    local reviewers_json='[]'
    if (( strict == 1 )); then
        if (( ${#PROD_REVIEWER_USERS[@]} == 0 && ${#PROD_REVIEWER_TEAMS[@]} == 0 )); then
            echo "ERROR: --prod-reviewer-user or --prod-reviewer-team must be set when applying to prod" >&2
            exit 1
        fi
        for u in "${PROD_REVIEWER_USERS[@]}"; do
            local uid
            uid=$(resolve_user_id "$u")
            reviewers_json=$(jq --argjson id "$uid" '. + [{"type":"User","id":$id}]' <<<"$reviewers_json")
        done
        for t in "${PROD_REVIEWER_TEAMS[@]}"; do
            local tid
            tid=$(resolve_team_id "$t")
            reviewers_json=$(jq --argjson id "$tid" '. + [{"type":"Team","id":$id}]' <<<"$reviewers_json")
        done
    else
        # Planning preview: synthesise reviewer entries by login/slug
        # without resolving them. Body is for human inspection only.
        for u in "${PROD_REVIEWER_USERS[@]}"; do
            reviewers_json=$(jq --arg login "$u" '. + [{"type":"User","login":$login,"id":"<unresolved>"}]' <<<"$reviewers_json")
        done
        for t in "${PROD_REVIEWER_TEAMS[@]}"; do
            reviewers_json=$(jq --arg slug "$t" '. + [{"type":"Team","slug":$slug,"id":"<unresolved>"}]' <<<"$reviewers_json")
        done
        if (( ${#PROD_REVIEWER_USERS[@]} == 0 && ${#PROD_REVIEWER_TEAMS[@]} == 0 )); then
            reviewers_json='["<must-supply --prod-reviewer-user or --prod-reviewer-team for --apply>"]'
        fi
    fi

    jq -n \
        --argjson wait "$PROD_WAIT_MINUTES" \
        --argjson reviewers "$reviewers_json" \
        '{
            wait_timer: $wait,
            prevent_self_review: true,
            reviewers: $reviewers,
            deployment_branch_policy: {
                protected_branches: false,
                custom_branch_policies: true
            }
        }'
}

# PUT the environment (idempotent: GH treats this as upsert).
apply_environment() {
    local env=$1
    local body
    body=$(build_env_body "$env" 1)
    gh api -X PUT \
        -H "Accept: application/vnd.github+json" \
        "/repos/${REPO_SLUG}/environments/${env}" \
        --input - <<<"$body" >/dev/null
    echo "  applied:  ${env}"

    # Configure the branch policy for prod (only main).
    if [[ "$env" == "prod" ]]; then
        # Idempotency: GH returns 422 if the policy already exists with
        # the same name; tolerate that.
        local pol_body
        pol_body='{"name":"main","type":"branch"}'
        if ! gh api -X POST \
            -H "Accept: application/vnd.github+json" \
            "/repos/${REPO_SLUG}/environments/${env}/deployment-branch-policies" \
            --input - <<<"$pol_body" >/dev/null 2>&1; then
            echo "  note:     branch policy 'main' already present (or 422 - tolerable)"
        else
            echo "  branch:   main only (custom branch policy)"
        fi
    fi
}

# Print the planned mutation without doing it.
plan_environment() {
    local env=$1
    local body
    body=$(build_env_body "$env" 0)
    echo "  would PUT /repos/${REPO_SLUG}/environments/${env}"
    if [[ "$body" != "{}" ]]; then
        jq . <<<"$body" | sed 's/^/    /'
    fi
}

# List the names of secrets defined for a given environment. The GH
# API returns names only, never values.
list_env_secrets() {
    local env=$1
    gh api -H "Accept: application/vnd.github+json" --paginate \
        "/repos/${REPO_SLUG}/environments/${env}/secrets" \
        --jq '.secrets[].name' 2>/dev/null || true
}

# Audit one env against the matrix. Set CHECK_VAULT_SECRETS=1 in the
# environment to also require VAULT_ADDR / VAULT_ROLE_ID / VAULT_SECRET_ID.
check_env_secrets() {
    local env=$1
    local present
    present=$(list_env_secrets "$env" | sort -u)
    local -a expected=("${SECRETS_COMMON[@]}")
    if [[ "${CHECK_VAULT_SECRETS:-0}" == "1" ]]; then
        expected+=("${SECRETS_VAULT[@]}")
    fi
    local missing=()
    for s in "${expected[@]}"; do
        if ! grep -qx -- "$s" <<<"$present"; then
            missing+=("$s")
        fi
    done
    if (( ${#missing[@]} == 0 )); then
        printf '%-6s : ok\n' "$env"
        return 0
    fi
    printf '%-6s : missing %s\n' "$env" "${missing[*]}"
    return 1
}

# ---------------------------------------------------------------------
# Mode dispatch
# ---------------------------------------------------------------------
case "$MODE" in
    list)
        echo "existing environments:"
        list_environments | sed 's/^/  /'
        ;;

    dry-run)
        echo "Would create / update the following environments:"
        for env in $ENVIRONMENTS; do
            echo "- ${env}"
            plan_environment "$env"
        done
        echo
        echo "Re-run with --apply to commit these changes."
        ;;

    apply)
        echo "Applying environments:"
        for env in $ENVIRONMENTS; do
            echo "- ${env}"
            apply_environment "$env"
        done
        echo
        echo "Done. Run with --check to audit secret presence."
        ;;

    check)
        echo "Auditing secret presence per environment:"
        echo "(matrix lives in docs/secrets.md and SECRETS_COMMON in this script)"
        echo
        rc=0
        for env in $ENVIRONMENTS; do
            check_env_secrets "$env" || rc=2
        done
        exit "$rc"
        ;;

    *)
        echo "ERROR: unknown mode: $MODE" >&2
        exit 1 ;;
esac
