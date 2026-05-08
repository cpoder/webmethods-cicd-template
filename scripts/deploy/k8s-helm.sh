#!/usr/bin/env bash
# scripts/deploy/k8s-helm.sh
#
# Deploy a built service image to a Kubernetes cluster via Helm.
# This is the `target.kind: kubernetes-helm` deploy backend; the
# Docker host (SSH) flow lives in scripts/deploy/docker-ssh.sh.
#
# Pipeline:
#   1. Decode TARGET_KUBECONFIG_B64 (env var, populated from
#      ${{ secrets.TARGET_KUBECONFIG_B64 }} in CI) -> 0600 tmpfile.
#      Export KUBECONFIG to point at it; never write to ~/.kube/config.
#      An already-set KUBECONFIG env or --kubeconfig flag wins.
#   2. helm upgrade --install wm-svc-<env> helm/wm-microservice/ \
#        -f helm/wm-microservice/values-<env>.yaml \
#        --namespace <ns> --create-namespace \
#        --set image.tag=<sha7> \
#        --set-string config.data.<KEY>=<VAL> ... \
#        [ESO disabled -> --set-string secret.data.<KEY>=<VAL> ...] \
#        --wait --timeout 5m
#      The --wait makes helm block until the Deployment reaches its
#      ready replicas; --atomic rolls back on failure so the cluster
#      doesn't end up half-upgraded.
#   3. After rollout: kubectl rollout status deployment/<svc> --timeout 5m
#      (defence-in-depth: --wait in step 2 already covers the happy
#      path, but rollout status surfaces stuck-progressing pods that
#      slipped past helm's readiness check).
#   4. kubectl port-forward svc/<svc> <local>:5555 in the background,
#      wait for the local socket to come up, run scripts/apply-config.sh
#      against http://localhost:<local>, tear the port-forward down.
#
# Acceptance criterion (Task 7.2):
#   `helm lint helm/wm-microservice/` clean; `helm template ... | kubeval`
#   passes; deploying to a kind cluster spins up 2 ready pods and
#   `kubectl exec` of `curl :5555/invoke/wm.server:ping` returns OK.
#
# Usage:
#   IMAGE_REF=ghcr.io/cpoder/wm-svc:11.1.0-svc-abc1234 \
#   TARGET_KUBECONFIG_B64=<base64-of-kubeconfig.yaml> \
#   MSR_ADMIN_PASSWORD=...                            \
#   SAG_LICENSE_KEY_DEV=...                           \
#       scripts/deploy/k8s-helm.sh ENV=dev
#
# Both `ENV=dev` (KEY=VAL form) and `--env dev` are accepted.
#
# Required env vars:
#   IMAGE_REF                   Immutable image ref (digest or sha7-tag).
#                               *-latest forms are rejected.
#   TARGET_KUBECONFIG_B64       Base64-encoded kubeconfig.
#                               OR: KUBECONFIG points at an existing file.
#                               OR: --kubeconfig <path> on the CLI.
#
# Optional env vars / flags:
#   --namespace NS              k8s namespace (default: wm-svc-<env>)
#   --release NAME              helm release name (default: wm-svc-<env>)
#   --chart-dir DIR             helm chart path
#                               (default: <repo>/helm/wm-microservice)
#   --values-file PATH          per-env overrides
#                               (default: <chart-dir>/values-<env>.yaml)
#   --kubeconfig PATH           kubeconfig file path
#   --timeout DURATION          helm + rollout timeout (default 5m)
#   --skip-apply-config         skip post-rollout apply-config step
#   --skip-rollout-check        skip the kubectl rollout status step
#                               (helm --wait already validates readiness)
#   --dry-run                   print plan, run helm template only,
#                               do NOT install / apply-config
#   --set-config-from FILE      load extra ConfigMap entries from a
#                               java.properties file (each KEY=VAL line
#                               becomes --set-string config.data.KEY=VAL).
#                               Defaults to reports/config/effective.<env>.properties
#                               if it exists; pass /dev/null to disable.
#
#   MSR_ADMIN_USER              defaults to Administrator
#   MSR_ADMIN_PASSWORD          for apply-config
#   <runtime placeholders>      whatever the per-env values references
#
# Exit codes:
#   0  helm upgrade succeeded, all replicas ready, apply-config green
#   1  setup error (bad args, missing tools, kubeconfig unreadable)
#   2  helm upgrade failed OR rollout did not reach ready in --timeout
#   3  apply-config failed (deployment is up but configuration didn't
#      land; operator decides to retry or roll back via `helm rollback`)

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)

# ---------------------------------------------------------------------
# Defaults / CLI parsing
# ---------------------------------------------------------------------
ENV=""
NAMESPACE=""
RELEASE=""
CHART_DIR="${REPO_ROOT}/helm/wm-microservice"
VALUES_FILE=""
KUBECONFIG_OVERRIDE=""
TIMEOUT="5m"
IMAGE_REF="${IMAGE_REF:-}"
SKIP_APPLY_CONFIG=0
SKIP_ROLLOUT_CHECK=0
DRY_RUN=0
SET_CONFIG_FROM=""
APPLY_CONFIG_SH="${REPO_ROOT}/scripts/apply-config.sh"
WM_MCP_USER="${MSR_ADMIN_USER:-Administrator}"
WM_MCP_PASSWORD="${MSR_ADMIN_PASSWORD:-manage}"

usage() {
    sed -n 's/^# \{0,1\}//p' "$0" | sed -n '2,90p'
}

while (( $# > 0 )); do
    case "$1" in
        ENV=*)               ENV="${1#ENV=}"; shift ;;
        IMAGE_REF=*)         IMAGE_REF="${1#IMAGE_REF=}"; shift ;;
        --env)               ENV=$2; shift 2 ;;
        --image-ref)         IMAGE_REF=$2; shift 2 ;;
        --namespace|-n)      NAMESPACE=$2; shift 2 ;;
        --release)           RELEASE=$2; shift 2 ;;
        --chart-dir)         CHART_DIR=$2; shift 2 ;;
        --values-file)       VALUES_FILE=$2; shift 2 ;;
        --kubeconfig)        KUBECONFIG_OVERRIDE=$2; shift 2 ;;
        --timeout)           TIMEOUT=$2; shift 2 ;;
        --skip-apply-config) SKIP_APPLY_CONFIG=1; shift ;;
        --skip-rollout-check) SKIP_ROLLOUT_CHECK=1; shift ;;
        --set-config-from)   SET_CONFIG_FROM=$2; shift 2 ;;
        --dry-run)           DRY_RUN=1; shift ;;
        -h|--help)           usage; exit 0 ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage >&2
            exit 1 ;;
    esac
done

if [[ -z "${ENV}" ]]; then
    echo "ERROR: ENV=<env> (or --env <env>) is required" >&2
    exit 1
fi
if [[ -z "${IMAGE_REF}" ]]; then
    echo "ERROR: IMAGE_REF (env var or --image-ref) is required" >&2
    exit 1
fi
# Reject mutable tags. Same rationale as docker-ssh.sh: a typo'd
# `latest` should fail loud, not silently roll the cluster onto
# whatever happens to be at HEAD of that tag today.
case "${IMAGE_REF}" in
    *:latest|*-latest|*-latest-*)
        echo "ERROR: IMAGE_REF must be an immutable tag/digest, not '${IMAGE_REF}'" >&2
        echo "       use a SHA-pinned tag (e.g. ...:11.1.0-svc-abc1234) or @sha256:... digest" >&2
        exit 1 ;;
esac

# Apply env-derived defaults.
NAMESPACE=${NAMESPACE:-wm-svc-${ENV}}
RELEASE=${RELEASE:-wm-svc-${ENV}}
VALUES_FILE=${VALUES_FILE:-${CHART_DIR}/values-${ENV}.yaml}
EFFECTIVE_PROPERTIES_DEFAULT="${REPO_ROOT}/reports/config/effective.${ENV}.properties"
if [[ -z "${SET_CONFIG_FROM}" ]] && [[ -f "${EFFECTIVE_PROPERTIES_DEFAULT}" ]]; then
    SET_CONFIG_FROM="${EFFECTIVE_PROPERTIES_DEFAULT}"
fi

if [[ ! -d "${CHART_DIR}" ]]; then
    echo "ERROR: chart directory not found: ${CHART_DIR}" >&2
    exit 1
fi
if [[ ! -f "${VALUES_FILE}" ]]; then
    echo "ERROR: values file not found: ${VALUES_FILE}" >&2
    exit 1
fi

# Image-repo / IMAGE_REF split. Helm needs image.repository + image.tag
# separately so `helm template` can render the deployment without
# string-eval on a single ref. We accept the <repo>:<tag> form only;
# digest pinning (<repo>@sha256:...) is not yet wired through the
# chart's image template -- the chart joins repo + tag with ":" which
# would produce an invalid `repo:sha256:abcd` ref. Until the chart is
# extended to support a separate image.digest field, the deploy script
# rejects digest refs and asks for a sha7-tagged ref instead.
HELM_IMAGE_REPO=""
HELM_IMAGE_TAG=""
case "${IMAGE_REF}" in
    *@sha256:*)
        echo "ERROR: digest-pinned IMAGE_REF not yet supported by k8s-helm.sh" >&2
        echo "       use a sha7-tagged ref like ...:11.1.0-svc-abc1234" >&2
        exit 1 ;;
    *:*)
        HELM_IMAGE_REPO="${IMAGE_REF%:*}"
        HELM_IMAGE_TAG="${IMAGE_REF##*:}"
        ;;
    *)
        echo "ERROR: IMAGE_REF must be <repo>:<tag>, got '${IMAGE_REF}'" >&2
        exit 1 ;;
esac

# Prerequisite tools.
require_tools() {
    local missing=()
    for tool in helm kubectl; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if (( ${#missing[@]} > 0 )); then
        printf 'ERROR: required tool(s) not found: %s\n' "${missing[*]}" >&2
        return 1
    fi
}
require_tools || exit 1

# ---------------------------------------------------------------------
# KUBECONFIG resolution. Order:
#   1. --kubeconfig <path>           (CLI flag)
#   2. KUBECONFIG env var            (already-set, reuse it)
#   3. TARGET_KUBECONFIG_B64 env var (decode to tmpfile, export KUBECONFIG)
# We never touch ~/.kube/config -- that file is the operator's
# personal context and a CI run mutating it would be a foot-gun.
# ---------------------------------------------------------------------
KUBECONFIG_TMPFILE=""
if [[ -n "${KUBECONFIG_OVERRIDE}" ]]; then
    if [[ ! -r "${KUBECONFIG_OVERRIDE}" ]]; then
        echo "ERROR: --kubeconfig file not readable: ${KUBECONFIG_OVERRIDE}" >&2
        exit 1
    fi
    export KUBECONFIG="${KUBECONFIG_OVERRIDE}"
elif [[ -n "${KUBECONFIG:-}" ]] && [[ -r "${KUBECONFIG}" ]]; then
    : # already set; keep it
elif [[ -n "${TARGET_KUBECONFIG_B64:-}" ]]; then
    KUBECONFIG_TMPFILE=$(mktemp -t wmcicd-kubeconfig.XXXXXX)
    chmod 600 "${KUBECONFIG_TMPFILE}"
    # base64 -d is GNU; macOS uses base64 -D. Try both.
    if ! printf '%s' "${TARGET_KUBECONFIG_B64}" | base64 -d > "${KUBECONFIG_TMPFILE}" 2>/dev/null; then
        if ! printf '%s' "${TARGET_KUBECONFIG_B64}" | base64 -D > "${KUBECONFIG_TMPFILE}" 2>/dev/null; then
            echo "ERROR: failed to base64-decode TARGET_KUBECONFIG_B64" >&2
            exit 1
        fi
    fi
    if [[ ! -s "${KUBECONFIG_TMPFILE}" ]]; then
        echo "ERROR: decoded TARGET_KUBECONFIG_B64 is empty" >&2
        exit 1
    fi
    export KUBECONFIG="${KUBECONFIG_TMPFILE}"
else
    echo "ERROR: no kubeconfig: pass --kubeconfig, set KUBECONFIG, or set TARGET_KUBECONFIG_B64" >&2
    exit 1
fi

# Quick sanity check: cluster reachable?
if (( DRY_RUN == 0 )); then
    if ! kubectl version --output=json >/dev/null 2>&1; then
        echo "ERROR: kubectl cannot reach the cluster (KUBECONFIG=${KUBECONFIG})" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------
# Cleanup. Tear down any lingering port-forward we own; scrub the
# kubeconfig tmpfile.
# ---------------------------------------------------------------------
PORT_FORWARD_PID=""
final_cleanup() {
    local rc=$?
    if [[ -n "${PORT_FORWARD_PID}" ]]; then
        kill "${PORT_FORWARD_PID}" 2>/dev/null || true
        wait "${PORT_FORWARD_PID}" 2>/dev/null || true
    fi
    if [[ -n "${KUBECONFIG_TMPFILE}" ]]; then
        rm -f -- "${KUBECONFIG_TMPFILE}"
    fi
    return $rc
}
trap final_cleanup EXIT

# ---------------------------------------------------------------------
# Build extra `--set-string config.data.<K>=<V>` args from the merged
# effective.<env>.properties when present. Skips comments and blanks.
# We use --set-string (never --set) so values are always treated as
# strings -- a bare "true" or numeric port becomes a quoted string in
# the ConfigMap, matching how docker --env-file would treat it.
# ---------------------------------------------------------------------
HELM_EXTRA_SET=()
if [[ -n "${SET_CONFIG_FROM}" ]] && [[ "${SET_CONFIG_FROM}" != "/dev/null" ]]; then
    if [[ ! -f "${SET_CONFIG_FROM}" ]]; then
        echo "ERROR: --set-config-from file not found: ${SET_CONFIG_FROM}" >&2
        exit 1
    fi
    while IFS= read -r line; do
        # Skip blanks + comment lines.
        case "${line}" in
            ''|'#'*) continue ;;
        esac
        # KEY=VALUE, only split on the first '='.
        if [[ "${line}" != *'='* ]]; then
            continue
        fi
        key=${line%%=*}
        val=${line#*=}
        # Helm --set parses commas/dots/equals specially; escape them.
        # --set-string still interprets ',' and '\\', so backslash-escape.
        esc_val=${val//\\/\\\\}
        esc_val=${esc_val//,/\\,}
        HELM_EXTRA_SET+=(--set-string "config.data.${key}=${esc_val}")
    done < "${SET_CONFIG_FROM}"
fi

# ---------------------------------------------------------------------
# Plan summary (always printed -- audit trail in CI logs)
# ---------------------------------------------------------------------
echo
echo "============================================================"
echo " kubernetes-helm deploy plan"
echo "============================================================"
echo "  env             : ${ENV}"
echo "  release         : ${RELEASE}"
echo "  namespace       : ${NAMESPACE}"
echo "  chart           : ${CHART_DIR}"
echo "  values          : ${VALUES_FILE}"
echo "  image           : ${HELM_IMAGE_REPO}:${HELM_IMAGE_TAG}"
echo "  kubeconfig      : ${KUBECONFIG}"
echo "  timeout         : ${TIMEOUT}"
echo "  config overrides: ${SET_CONFIG_FROM:-(none)}  -> ${#HELM_EXTRA_SET[@]} entries"
echo "  apply-config    : $( ((SKIP_APPLY_CONFIG==1)) && echo skipped || echo enabled )"
echo "  rollout check   : $( ((SKIP_ROLLOUT_CHECK==1)) && echo skipped || echo enabled )"
echo "============================================================"
echo

# ---------------------------------------------------------------------
# Step 1: helm upgrade --install (or template in --dry-run mode)
# ---------------------------------------------------------------------
helm_args=(
    upgrade --install "${RELEASE}" "${CHART_DIR}"
    --namespace "${NAMESPACE}"
    --create-namespace
    -f "${VALUES_FILE}"
    --set-string "image.repository=${HELM_IMAGE_REPO}"
    --set-string "image.tag=${HELM_IMAGE_TAG}"
    --wait
    --atomic
    --timeout "${TIMEOUT}"
)
if (( ${#HELM_EXTRA_SET[@]} > 0 )); then
    helm_args+=("${HELM_EXTRA_SET[@]}")
fi

if (( DRY_RUN == 1 )); then
    echo "==> [DRY-RUN] helm template ${RELEASE} ${CHART_DIR} ..."
    helm template "${RELEASE}" "${CHART_DIR}" \
        --namespace "${NAMESPACE}" \
        -f "${VALUES_FILE}" \
        --set-string "image.repository=${HELM_IMAGE_REPO}" \
        --set-string "image.tag=${HELM_IMAGE_TAG}" \
        "${HELM_EXTRA_SET[@]}" >/dev/null
    echo "OK: helm template rendered without errors"
    echo "==> [DRY-RUN] would run: helm ${helm_args[*]}"
    exit 0
fi

echo "==> helm upgrade --install ${RELEASE} (timeout ${TIMEOUT})"
if ! helm "${helm_args[@]}"; then
    echo "ERROR: helm upgrade failed; --atomic should have rolled back" >&2
    exit 2
fi

# ---------------------------------------------------------------------
# Step 2: kubectl rollout status. helm --wait already validates that
# the Deployment hits its readyReplicas count, but rollout status is
# more verbose and surfaces ProgressDeadlineExceeded faster.
# ---------------------------------------------------------------------
DEPLOYMENT_NAME=$(kubectl get deployment \
    -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${RELEASE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "${DEPLOYMENT_NAME}" ]]; then
    echo "ERROR: could not find Deployment with label app.kubernetes.io/instance=${RELEASE}" >&2
    kubectl get all -n "${NAMESPACE}" >&2 || true
    exit 2
fi
echo "==> rollout deployment: ${DEPLOYMENT_NAME}"

if (( SKIP_ROLLOUT_CHECK == 0 )); then
    if ! kubectl rollout status deployment/"${DEPLOYMENT_NAME}" \
            -n "${NAMESPACE}" \
            --timeout="${TIMEOUT}"; then
        echo "ERROR: rollout did not complete within ${TIMEOUT}" >&2
        kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE}" >&2 || true
        exit 2
    fi
fi

# ---------------------------------------------------------------------
# Step 3: apply-config via port-forward. We pick a free local port,
# launch `kubectl port-forward svc/<svc> <local>:5555` in the
# background, wait for the local socket to bind, then run
# scripts/apply-config.sh against http://localhost:<local>.
#
# Note: apply-config.sh's --container flag is for `docker exec` mode
# (used by docker-ssh.sh). Here we go via port-forward + HTTP, which is
# the default mode -- wm-mcp talks to the IS HTTP listener directly.
# ---------------------------------------------------------------------
SVC_NAME=$(kubectl get svc \
    -n "${NAMESPACE}" \
    -l "app.kubernetes.io/instance=${RELEASE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -z "${SVC_NAME}" ]]; then
    echo "ERROR: could not find Service with label app.kubernetes.io/instance=${RELEASE}" >&2
    exit 2
fi

if (( SKIP_APPLY_CONFIG == 1 )); then
    echo "==> apply-config skipped (--skip-apply-config)"
    echo
    echo "Deploy succeeded. release=${RELEASE} namespace=${NAMESPACE} svc=${SVC_NAME}"
    exit 0
fi

# Find a free local port. ss -ltn lists listening tcp ports; we try
# 15555 first (mnemonic: 1 + 5555) and walk upward until one is free.
pick_local_port() {
    local p
    for p in $(seq 15555 15600); do
        if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"; then
            echo "$p"
            return 0
        fi
    done
    echo "ERROR: no free local port in 15555-15600" >&2
    return 1
}
LOCAL_PORT=$(pick_local_port) || exit 1

echo "==> kubectl port-forward svc/${SVC_NAME} ${LOCAL_PORT}:5555 (background)"
PORT_FORWARD_LOG=$(mktemp -t wmcicd-port-forward.XXXXXX.log)
kubectl port-forward -n "${NAMESPACE}" \
    "svc/${SVC_NAME}" \
    "${LOCAL_PORT}:5555" \
    >"${PORT_FORWARD_LOG}" 2>&1 &
PORT_FORWARD_PID=$!

# Wait up to 30s for the port-forward to bind. kubectl prints
# "Forwarding from 127.0.0.1:<port>" on success, "error:" on failure.
deadline=$(( $(date +%s) + 30 ))
while :; do
    if grep -q "Forwarding from " "${PORT_FORWARD_LOG}" 2>/dev/null; then
        break
    fi
    if ! kill -0 "${PORT_FORWARD_PID}" 2>/dev/null; then
        echo "ERROR: kubectl port-forward exited early:" >&2
        cat "${PORT_FORWARD_LOG}" >&2
        exit 3
    fi
    if [[ $(date +%s) -ge ${deadline} ]]; then
        echo "ERROR: kubectl port-forward did not bind within 30s" >&2
        cat "${PORT_FORWARD_LOG}" >&2
        exit 3
    fi
    sleep 1
done

# Quick liveness ping through the forward to fail fast if the service
# isn't actually reachable yet (probes might pass on the kubelet side
# while the port-forward path has stale endpoints).
if ! curl -fs -o /dev/null --max-time 5 "http://localhost:${LOCAL_PORT}/invoke/wm.server:ping"; then
    echo "WARN: ping over port-forward failed; proceeding anyway -- apply-config will surface the real error" >&2
fi

echo "==> apply-config --env ${ENV} --target http://localhost:${LOCAL_PORT}"
if ! "${APPLY_CONFIG_SH}" \
        --env "${ENV}" \
        --target "http://localhost:${LOCAL_PORT}" \
        --user "${WM_MCP_USER}" \
        --password "${WM_MCP_PASSWORD}"; then
    echo "ERROR: apply-config failed; deployment is up but configuration did not land" >&2
    echo "       to roll back:  helm rollback ${RELEASE} -n ${NAMESPACE}" >&2
    rm -f "${PORT_FORWARD_LOG}"
    exit 3
fi

rm -f "${PORT_FORWARD_LOG}"

echo
echo "Deploy succeeded."
echo "  release   : ${RELEASE}"
echo "  namespace : ${NAMESPACE}"
echo "  service   : ${SVC_NAME}  (ClusterIP :5555 / :5443)"
echo "  pods      : $(kubectl get pods -n "${NAMESPACE}" -l "app.kubernetes.io/instance=${RELEASE}" --no-headers 2>/dev/null | wc -l) ready"
exit 0
