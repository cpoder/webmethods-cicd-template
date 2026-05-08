#!/usr/bin/env bash
# scripts/deploy/record-deployment.sh
#
# Tag a successful deploy in the GitHub deployments API with our
# image_ref payload, so scripts/deploy/rollback.sh can find the
# previous successful image when smoke fails.
#
# Why a separate record (not the auto-deployment GitHub creates from
# `environment:`)? The auto-record's `payload` field cannot be set from
# inside the workflow that triggers it -- by the time the job runs,
# the deployment object already exists. Creating our own deployment
# with payload.image_ref lets `gh deployment list` carry the data we
# need.
#
# Usage:
#   record-deployment.sh <env> <sha> <image_ref>
#
# Required env:
#   GH_TOKEN or GITHUB_TOKEN   gh auth
#   GH_REPO                    OWNER/REPO. Defaults to GITHUB_REPOSITORY.
#
# Exit codes:
#   0  deployment + status recorded
#   1  setup error or API failure (we WARN-don't-fail in CI;
#      the workflow's deploy succeeded, missing audit record is not
#      cause to fail the whole run)

set -euo pipefail

env_name=${1:-}
sha=${2:-}
image_ref=${3:-}

if [[ -z "${env_name}" || -z "${sha}" || -z "${image_ref}" ]]; then
    echo "Usage: record-deployment.sh <env> <sha> <image_ref>" >&2
    exit 1
fi

GH_REPO=${GH_REPO:-${GITHUB_REPOSITORY:-}}
if [[ -z "${GH_REPO}" ]]; then
    echo "WARN: no GH_REPO / GITHUB_REPOSITORY; skipping deployment record" >&2
    exit 0
fi
if [[ -z "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
    echo "WARN: no GH_TOKEN / GITHUB_TOKEN; skipping deployment record" >&2
    exit 0
fi
export GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN}}"

if ! command -v gh >/dev/null 2>&1; then
    echo "WARN: gh CLI not on PATH; skipping deployment record" >&2
    exit 0
fi

# 1. Create the deployment. `auto_merge=false` skips merge-up checks
# (they don't apply -- we already deployed). `required_contexts=[]`
# disables status-check requirements. `task=deploy` is the standard
# value. payload carries our image_ref + target_kind so rollback can
# read it back.
#
# We pipe the JSON body via stdin (--input -) so the payload object
# nests cleanly. The -f/-F flag form would need workarounds for
# nested objects, which gh-api doesn't support directly.
payload=$(cat <<JSON
{
  "ref": "${sha}",
  "environment": "${env_name}",
  "task": "deploy",
  "auto_merge": false,
  "required_contexts": [],
  "description": "cd.yml: deployed ${image_ref}",
  "payload": {
    "image_ref": "${image_ref}",
    "recorded_by": "scripts/deploy/record-deployment.sh"
  }
}
JSON
)
if ! deployment_id=$(printf '%s' "${payload}" \
        | gh api -X POST "repos/${GH_REPO}/deployments" \
            --input - --jq '.id' 2>&1); then
    echo "WARN: failed to create deployment record: ${deployment_id}" >&2
    exit 0
fi

if ! [[ "${deployment_id}" =~ ^[0-9]+$ ]]; then
    echo "WARN: unexpected response creating deployment: ${deployment_id}" >&2
    exit 0
fi

# 2. Mark the deployment success so it appears in `gh deployment list`
# filtered by state=success (which is what rollback.sh queries).
status_payload=$(cat <<JSON
{
  "state": "success",
  "description": "deploy succeeded; image=${image_ref}",
  "environment": "${env_name}",
  "auto_inactive": false
}
JSON
)
if ! printf '%s' "${status_payload}" \
        | gh api -X POST "repos/${GH_REPO}/deployments/${deployment_id}/statuses" \
            --input - >/dev/null 2>&1; then
    echo "WARN: created deployment ${deployment_id} but failed to set success status" >&2
fi

echo "Recorded deployment id=${deployment_id} env=${env_name} image=${image_ref}"
