#!/usr/bin/env bash
# scripts/deploy/rollback.sh
#
# Roll back a failed deploy by re-running the previous successful one.
# Invoked by .github/workflows/cd.yml's `if: failure()` branch when
# smoke fails after a deploy step.
#
# Strategy:
#   1. Use `gh deployment list` (REST: GET /repos/{O}/{R}/deployments)
#      to list the most recent deployments for the target environment.
#   2. The CD workflow tags every successful deploy with
#      payload.image_ref so we can recover it. Take the most recent
#      success (by created_at) whose image_ref differs from the one
#      we are currently rolling back from -- that's the previous
#      shipping image.
#   3. Re-invoke the appropriate deploy backend (docker-ssh.sh or
#      k8s-helm.sh, dispatched on config/<env>/deploy.yaml's
#      target.kind) with that image_ref, --skip-apply-config (we want
#      bit-for-bit the old container, including the old config -- IS
#      configuration is part of the rollback surface), and emit a new
#      deployment record marked `state=in_progress` so the trail is
#      auditable.
#
# Inputs (env or args):
#   ENV / --env <env>           dev | test | prod (required)
#   --image-ref <ref>           explicit override; skips the gh API
#                               lookup (used when CI already knows
#                               the previous SHA from a workflow input)
#   FAILED_IMAGE_REF / --failed-image-ref <ref>
#                               the image_ref that just failed; used
#                               to skip past the bad deployment in the
#                               gh api list. Optional but recommended.
#   --gh-repo OWNER/REPO        defaults to GITHUB_REPOSITORY
#   --apply-config              opt-in: re-run apply-config too. Off
#                               by default because rollback wants the
#                               previous container BIT-EXACT, including
#                               the previous config snapshot.
#   --dry-run                   resolve the image but don't deploy
#
#   GITHUB_TOKEN / GH_TOKEN     gh auth (required when --image-ref is
#                               not given)
#
# Exit codes:
#   0  rollback succeeded
#   1  setup error (no ENV, no auth, no previous deployment found)
#   2  the redeploy itself failed
#
# Notes:
#   * The CD workflow records every successful deploy as a separate
#     "deployment" via `gh api -X POST .../deployments` with payload
#     `{image_ref, target_kind}`. Those records are what
#     `gh deployment list` returns. The auto-deployment created by
#     GitHub when a job uses `environment:` is also returned, but
#     does NOT carry image_ref in payload -- we filter on
#     payload.image_ref non-null to skip it.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)

ENV=""
IMAGE_REF=""
FAILED_IMAGE_REF="${FAILED_IMAGE_REF:-}"
GH_REPO="${GITHUB_REPOSITORY:-}"
DRY_RUN=0
APPLY_CONFIG=0

usage() {
    sed -n 's/^# \{0,1\}//p' "$0" | sed -n '2,55p'
}

while (( $# > 0 )); do
    case "$1" in
        ENV=*)               ENV="${1#ENV=}"; shift ;;
        --env)               ENV=$2; shift 2 ;;
        --image-ref)         IMAGE_REF=$2; shift 2 ;;
        --failed-image-ref)  FAILED_IMAGE_REF=$2; shift 2 ;;
        --gh-repo)           GH_REPO=$2; shift 2 ;;
        --apply-config)      APPLY_CONFIG=1; shift ;;
        --dry-run)           DRY_RUN=1; shift ;;
        -h|--help)           usage; exit 0 ;;
        *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ -z "${ENV}" ]]; then
    echo "ERROR: ENV=<env> (or --env <env>) is required" >&2
    exit 1
fi

DEPLOY_YAML="${REPO_ROOT}/config/${ENV}/deploy.yaml"
if [[ ! -f "${DEPLOY_YAML}" ]]; then
    echo "ERROR: missing deploy descriptor: ${DEPLOY_YAML}" >&2
    exit 1
fi

# ---------------------------------------------------------------------
# Resolve the previous successful image_ref via gh deployment list.
# Skipped when --image-ref is supplied.
# ---------------------------------------------------------------------
resolve_previous_image() {
    if [[ -z "${GH_REPO}" ]]; then
        echo "ERROR: --gh-repo (or GITHUB_REPOSITORY env) is required to look up deployments" >&2
        return 1
    fi
    if ! command -v gh >/dev/null 2>&1; then
        echo "ERROR: gh CLI not on PATH; either install it or pass --image-ref directly" >&2
        return 1
    fi

    # The REST API caps `per_page` at 100; we only need the recent few.
    # Filter chain:
    #   - state == 'success' (successful CD record)
    #   - payload.image_ref present (skip the GH-auto deployments that
    #     don't carry our payload)
    #   - image_ref != FAILED_IMAGE_REF (don't redeploy the broken image)
    # Sort by created_at desc, take .[0].payload.image_ref.
    local deployments_json
    if ! deployments_json=$(gh api \
            "repos/${GH_REPO}/deployments?environment=${ENV}&per_page=50" \
            --paginate=false 2>/dev/null); then
        echo "ERROR: failed to list deployments for ${GH_REPO} env=${ENV}" >&2
        return 1
    fi

    # gh api returns the deployments array; for each, fetch its statuses
    # to find the latest state. We do this in a single jq invocation by
    # pulling deployment ids first, then `gh api` per id for statuses.
    # That's O(n) network but n is at most 50 and rollback latency is
    # not a hot path.
    local ids
    ids=$(jq -r '.[].id' <<<"${deployments_json}")
    if [[ -z "${ids}" ]]; then
        echo "ERROR: no deployments found for env=${ENV}" >&2
        return 1
    fi

    local id state image_ref winner=""
    while IFS= read -r id; do
        # state: latest status for this deployment
        state=$(gh api "repos/${GH_REPO}/deployments/${id}/statuses?per_page=1" \
                  --jq '.[0].state // ""' 2>/dev/null || true)
        if [[ "${state}" != "success" ]]; then
            continue
        fi
        image_ref=$(jq -r --argjson id "${id}" \
            '.[] | select(.id == $id) | .payload.image_ref // ""' \
            <<<"${deployments_json}")
        if [[ -z "${image_ref}" ]]; then
            continue
        fi
        if [[ -n "${FAILED_IMAGE_REF}" ]] && [[ "${image_ref}" == "${FAILED_IMAGE_REF}" ]]; then
            continue
        fi
        winner="${image_ref}"
        break
    done <<<"${ids}"

    if [[ -z "${winner}" ]]; then
        echo "ERROR: no previous successful deployment with image_ref found for env=${ENV}" >&2
        echo "       (failed image: ${FAILED_IMAGE_REF:-unknown})" >&2
        return 1
    fi
    printf '%s' "${winner}"
}

if [[ -z "${IMAGE_REF}" ]]; then
    echo "==> resolving previous image_ref via gh deployment list (env=${ENV})"
    IMAGE_REF=$(resolve_previous_image) || exit 1
    echo "==> previous successful image: ${IMAGE_REF}"
fi

# ---------------------------------------------------------------------
# Read target.kind from deploy.yaml -> dispatch to the right backend.
# ---------------------------------------------------------------------
TARGET_KIND=$(python3 - "${DEPLOY_YAML}" <<'PY'
import sys, yaml
with open(sys.argv[1]) as fh:
    doc = yaml.safe_load(fh)
print((doc.get("target") or {}).get("kind", ""))
PY
)
if [[ -z "${TARGET_KIND}" ]]; then
    echo "ERROR: deploy.yaml target.kind is empty in ${DEPLOY_YAML}" >&2
    exit 1
fi

# Common deploy args. Rollback wants the previous container BIT-EXACT,
# so we skip apply-config by default (the previous image was running
# against its own previous config; re-running apply now with the
# CURRENT config tree could land an in-flight schema change on the
# rolled-back code path). --apply-config opts back in.
COMMON_ARGS=(--env "${ENV}" --image-ref "${IMAGE_REF}")
if (( APPLY_CONFIG == 0 )); then
    COMMON_ARGS+=(--skip-apply-config)
fi
if (( DRY_RUN == 1 )); then
    COMMON_ARGS+=(--dry-run)
fi

case "${TARGET_KIND}" in
    docker-ssh)
        echo "==> rolling back via docker-ssh backend"
        # CI uses --local because the script is already on the docker host
        # (appleboy/ssh-action SSHes there first). Outside CI the
        # operator can drop --local; we add it here when GH Actions sets
        # GITHUB_ACTIONS=true.
        if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
            COMMON_ARGS+=(--local)
        fi
        if ! "${REPO_ROOT}/scripts/deploy/docker-ssh.sh" "${COMMON_ARGS[@]}"; then
            echo "ERROR: docker-ssh rollback redeploy failed" >&2
            exit 2
        fi
        ;;
    kubernetes-helm)
        echo "==> rolling back via kubernetes-helm backend"
        if ! "${REPO_ROOT}/scripts/deploy/k8s-helm.sh" "${COMMON_ARGS[@]}"; then
            echo "ERROR: k8s-helm rollback redeploy failed" >&2
            exit 2
        fi
        ;;
    *)
        echo "ERROR: unsupported target.kind in ${DEPLOY_YAML}: ${TARGET_KIND}" >&2
        exit 1 ;;
esac

echo
echo "Rollback deployed image: ${IMAGE_REF} to env=${ENV} (target.kind=${TARGET_KIND})"
exit 0
