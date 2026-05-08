#!/usr/bin/env bash
# scripts/deploy/dispatch.sh
#
# Read config/<env>/deploy.yaml's `target.kind` and shell out to the
# right backend script. Used by .github/workflows/cd.yml so each
# deploy job is one line in YAML; the per-backend logic lives in
# scripts/deploy/{docker-ssh,k8s-helm}.sh and is unit-testable from
# the host.
#
# Inputs (env, all required where listed):
#   ENV          dev | test | prod
#   IMAGE_REF    immutable image ref
#   <secrets>    forwarded by the workflow (TARGET_HOST, TARGET_SSH_KEY,
#                TARGET_KUBECONFIG_B64, MSR_ADMIN_PASSWORD, ...)
#
# Exit codes: forwarded from the backend script.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)

ENV="${ENV:-}"
IMAGE_REF="${IMAGE_REF:-}"
if [[ -z "${ENV}" ]] || [[ -z "${IMAGE_REF}" ]]; then
    echo "ERROR: dispatch.sh requires ENV and IMAGE_REF env vars" >&2
    exit 1
fi

DEPLOY_YAML="${REPO_ROOT}/config/${ENV}/deploy.yaml"
if [[ ! -f "${DEPLOY_YAML}" ]]; then
    echo "ERROR: missing deploy descriptor: ${DEPLOY_YAML}" >&2
    exit 1
fi

TARGET_KIND=$(python3 - "${DEPLOY_YAML}" <<'PY'
import sys, yaml
with open(sys.argv[1]) as fh:
    doc = yaml.safe_load(fh)
print((doc.get("target") or {}).get("kind", ""))
PY
)
if [[ -z "${TARGET_KIND}" ]]; then
    echo "ERROR: target.kind is empty in ${DEPLOY_YAML}" >&2
    exit 1
fi

echo "==> dispatch ENV=${ENV} target.kind=${TARGET_KIND} IMAGE_REF=${IMAGE_REF}"

case "${TARGET_KIND}" in
    docker-ssh)
        # In CI we run on a self-hosted-ish ubuntu runner that SSHes
        # to the docker host. The backend script wants --local when
        # *invoked on the docker host itself*; in our flow the runner
        # is the SSH client, so we pass through the default (remote)
        # mode and let TARGET_SSH_KEY / TARGET_HOST carry the
        # connection details.
        exec "${REPO_ROOT}/scripts/deploy/docker-ssh.sh" \
            --env "${ENV}" \
            --image-ref "${IMAGE_REF}"
        ;;
    kubernetes-helm)
        exec "${REPO_ROOT}/scripts/deploy/k8s-helm.sh" \
            --env "${ENV}" \
            --image-ref "${IMAGE_REF}"
        ;;
    *)
        echo "ERROR: unsupported target.kind: ${TARGET_KIND}" >&2
        echo "       supported: docker-ssh, kubernetes-helm" >&2
        exit 1 ;;
esac
