#!/usr/bin/env bash
# scripts/deploy/db-snapshot.sh
#
# Pre-prod-deploy DB schema snapshot for emergency rollback (Task 7.3).
# Runs against the *currently-live* prod environment, BEFORE the new
# image rolls out, so the artifact captures the schema state that the
# previous container expected.
#
# Mechanism:
#   1. Materialise KUBECONFIG from TARGET_KUBECONFIG_B64 (same recipe
#      as scripts/deploy/k8s-helm.sh).
#   2. Find a pod of the live release (label app.kubernetes.io/instance=
#      wm-svc-<env>) and `kubectl exec` wm-mcp into it. wm-mcp is in
#      the corporate base image (Task 1.1) so it's always present.
#   3. Run wm-mcp jdbc_pool_export_schema --output json against the
#      configured pool (config/<env>/deploy.yaml: db_snapshot.pool).
#   4. Persist to reports/cd/db-snapshot-<short_sha>.json. The
#      workflow uploads it as an artifact named the same.
#
# Inputs (env, all required where listed):
#   ENV                    target environment name (default: prod)
#   TARGET_KUBECONFIG_B64  base64-encoded kubeconfig (or KUBECONFIG)
#   MSR_ADMIN_USER         wm-mcp credentials (default: Administrator)
#   MSR_ADMIN_PASSWORD     wm-mcp credentials (required)
#   SHORT_SHA              for the output filename
#
# Outputs:
#   * reports/cd/db-snapshot-<sha>.json  (the schema dump)
#   * GITHUB_OUTPUT path=...             (workflow artifact upload)
#
# Skip behaviour:
#   * If config/<env>/deploy.yaml has db_snapshot.enabled=false (or no
#     db_snapshot block), the script no-ops and exits 0.
#   * If no pods are found yet (first-ever deploy), the script also
#     no-ops and exits 0 -- nothing to snapshot.
#
# Exit codes:
#   0  snapshot taken (or skipped on purpose)
#   1  setup error (kubeconfig invalid, wm-mcp call failed)

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)

ENV="${ENV:-prod}"
SHORT_SHA="${SHORT_SHA:-$(date +%Y%m%dT%H%M%SZ)}"
DEPLOY_YAML="${REPO_ROOT}/config/${ENV}/deploy.yaml"

if [[ ! -f "${DEPLOY_YAML}" ]]; then
    echo "ERROR: missing deploy descriptor: ${DEPLOY_YAML}" >&2
    exit 1
fi

# Read db_snapshot config from deploy.yaml.
read_snapshot_config=$(python3 - "${DEPLOY_YAML}" <<'PY'
import sys, yaml
with open(sys.argv[1]) as fh:
    doc = yaml.safe_load(fh)
snap = doc.get("db_snapshot") or {}
release = (doc.get("container") or {}).get("name") or f"wm-svc-{(doc.get('target') or {}).get('namespace','')}"
namespace = (doc.get("target") or {}).get("namespace", "")
print(f"ENABLED={'1' if snap.get('enabled', False) else '0'}")
print(f"POOL={snap.get('pool', '')}")
print(f"NAMESPACE={namespace}")
print(f"RELEASE={release}")
PY
)
eval "${read_snapshot_config}"

if [[ "${ENABLED}" != "1" ]]; then
    echo "==> db_snapshot disabled in ${DEPLOY_YAML}; skipping"
    echo "path=" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
fi
if [[ -z "${POOL}" ]]; then
    echo "ERROR: db_snapshot.enabled=true but db_snapshot.pool is empty in ${DEPLOY_YAML}" >&2
    exit 1
fi

# Materialise KUBECONFIG.
KUBECONFIG_TMPFILE=""
cleanup() {
    [[ -n "${KUBECONFIG_TMPFILE}" ]] && rm -f -- "${KUBECONFIG_TMPFILE}"
}
trap cleanup EXIT

if [[ -z "${KUBECONFIG:-}" ]] || [[ ! -r "${KUBECONFIG}" ]]; then
    if [[ -z "${TARGET_KUBECONFIG_B64:-}" ]]; then
        echo "ERROR: neither KUBECONFIG nor TARGET_KUBECONFIG_B64 is set" >&2
        exit 1
    fi
    KUBECONFIG_TMPFILE=$(mktemp -t wmcicd-snapshot-kubeconfig.XXXXXX)
    chmod 600 "${KUBECONFIG_TMPFILE}"
    if ! printf '%s' "${TARGET_KUBECONFIG_B64}" | base64 -d > "${KUBECONFIG_TMPFILE}" 2>/dev/null; then
        echo "ERROR: TARGET_KUBECONFIG_B64 base64-decode failed" >&2
        exit 1
    fi
    if [[ ! -s "${KUBECONFIG_TMPFILE}" ]]; then
        echo "ERROR: TARGET_KUBECONFIG_B64 decoded to empty file" >&2
        exit 1
    fi
    export KUBECONFIG="${KUBECONFIG_TMPFILE}"
fi

# Find a live pod. If nothing matches, this is a first-ever prod
# deploy -- there is no schema state to snapshot yet, so we exit 0.
NS="${NAMESPACE:-wm-svc-${ENV}}"
POD=$(kubectl get pods -n "${NS}" \
        -l "app.kubernetes.io/instance=${RELEASE}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "${POD}" ]]; then
    echo "==> no live pods (instance=${RELEASE}, ns=${NS}); first deploy, skipping snapshot"
    echo "path=" >> "${GITHUB_OUTPUT:-/dev/null}"
    exit 0
fi

OUT_DIR="${REPO_ROOT}/reports/cd"
OUT_FILE="${OUT_DIR}/db-snapshot-${SHORT_SHA}.json"
mkdir -p "${OUT_DIR}"

echo "==> wm-mcp jdbc_pool_export_schema pool=${POOL} pod=${POD} ns=${NS}"

# Pipe an empty body in (the verb takes config from --pool). Capture
# stdout to the artifact file; capture stderr separately for diagnostics.
err_file=$(mktemp)
set +e
kubectl exec -n "${NS}" "${POD}" -- \
    env \
        WM_MCP_TARGET=http://localhost:5555 \
        WM_MCP_USER="${MSR_ADMIN_USER:-Administrator}" \
        WM_MCP_PASSWORD="${MSR_ADMIN_PASSWORD}" \
    wm-mcp jdbc_pool_export_schema --pool "${POOL}" --output json \
    > "${OUT_FILE}" 2>"${err_file}"
rc=$?
set -e

if (( rc != 0 )); then
    echo "ERROR: wm-mcp jdbc_pool_export_schema exited ${rc}" >&2
    head -c 400 "${err_file}" >&2 || true
    rm -f "${OUT_FILE}" "${err_file}"
    exit 1
fi
rm -f "${err_file}"

if [[ ! -s "${OUT_FILE}" ]]; then
    echo "ERROR: wm-mcp returned 0 but produced an empty snapshot" >&2
    exit 1
fi

# Light validation: must be parseable JSON.
if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${OUT_FILE}" 2>/dev/null; then
    echo "ERROR: snapshot is not valid JSON" >&2
    exit 1
fi

bytes=$(wc -c < "${OUT_FILE}")
echo "==> snapshot OK: ${OUT_FILE} (${bytes} bytes)"

# Surface the path to the workflow's `steps.<id>.outputs.path`.
echo "path=${OUT_FILE}" >> "${GITHUB_OUTPUT:-/dev/null}"
