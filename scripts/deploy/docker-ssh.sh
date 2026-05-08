#!/usr/bin/env bash
# scripts/deploy/docker-ssh.sh
#
# Deploy a built service image to a single-VM Docker host over SSH.
# This is the `target.kind: docker-ssh` deploy backend; Kubernetes
# (helm) lives in a sibling script.
#
# Pipeline:
#   1. Read config/<env>/deploy.yaml (target host/user/port, container
#      name, port mappings, smoke endpoint).
#   2. Render config/<env>/runtime.env.tmpl -> runtime.env via
#      scripts/lib/render-properties.sh. ${NAME} placeholders get the
#      value of env var NAME (CI populates from GitHub Environment
#      Secrets); unset/empty placeholders abort the deploy.
#   3. SCP the rendered env file to the host (or no-op in --local
#      mode) and SSH-execute the docker steps:
#        a. docker pull <image>@<digest>
#        b. rename existing wm-svc-<env> to wm-svc-<env>-prev (after
#           stopping it, so canonical ports become free); cleanup any
#           prior leftover -prev
#        c. docker run -d --name wm-svc-<env> --restart=always \
#               -p <publish>... --env-file <runtime.env> <image>
#        d. wait up to smoke.timeout_seconds for
#               docker exec wm-svc-<env> curl http://localhost:5555<smoke.path>
#           to return 2xx (default 120s; matches base image healthcheck)
#   4. scripts/apply-config.sh --env <env> --container wm-svc-<env>
#      (so wm-mcp runs inside the container against localhost:5555 --
#      no host-side admin port required).
#   5. On success: docker rm wm-svc-<env>-prev (frees the renamed old).
#      On failure: leave wm-svc-<env> (new, possibly unhealthy) and
#      wm-svc-<env>-prev (old, stopped) in `docker ps -a` for the
#      operator and exit non-zero.
#
# Acceptance criterion (Task 7.1):
#   Targeting a local Docker-on-WSL host with target.kind: docker-ssh,
#   a green PR merge deploys the image, applies dev config, and serves
#   a smoke endpoint within 3 min.
#
# Usage (CI, via appleboy/ssh-action -- the action SSHes to the host
# and the script runs there with --local because it's already there):
#   IMAGE_REF=ghcr.io/cpoder/wm-svc@sha256:...   \
#   MSR_ADMIN_PASSWORD=...                       \
#   SAG_LICENSE_KEY_DEV=...                      \
#       scripts/deploy/docker-ssh.sh ENV=dev --local
#
# Usage (operator on workstation, SSHes itself):
#   IMAGE_REF=ghcr.io/cpoder/wm-svc:11.1.0-svc-abc1234  \
#   TARGET_HOST=10.0.0.5  TARGET_SSH_KEY_FILE=~/.ssh/dep \
#   MSR_ADMIN_PASSWORD=...                              \
#       scripts/deploy/docker-ssh.sh ENV=dev
#
# Both `ENV=dev` (KEY=VAL form) and `--env dev` are accepted -- the
# task spec uses the former, common shell tooling uses the latter.
#
# Required env vars:
#   IMAGE_REF                  Immutable image ref. *-latest is rejected.
#   MSR_ADMIN_USER             Defaults to Administrator.
#   MSR_ADMIN_PASSWORD         For apply-config.
#   <runtime.env.tmpl placeholders>  Whatever the template references.
#
# Optional env vars:
#   TARGET_HOST                Override deploy.yaml target.host.
#   TARGET_USER                Override deploy.yaml target.user.
#   TARGET_PORT                Override deploy.yaml target.port.
#   TARGET_SSH_KEY             Raw private-key content. If set, the
#                              script writes it to a 0600 temp file.
#                              Mutually exclusive with TARGET_SSH_KEY_FILE.
#   TARGET_SSH_KEY_FILE        Path to private-key file.
#   REGISTRY_USER / _TOKEN     If set, the script logs into the registry
#                              before pulling. Skipped otherwise.
#
# Exit codes:
#   0  deploy succeeded; new container is serving the smoke endpoint
#      and apply-config returned green.
#   1  setup error (bad args, missing tools, deploy.yaml unreadable).
#   2  deploy failed -- old container is stopped & renamed, new is
#      present but unhealthy or apply-config failed; operator decides.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/../.." >/dev/null 2>&1 && pwd)

# shellcheck source=../lib/render-properties.sh
. "${REPO_ROOT}/scripts/lib/render-properties.sh"

# ---------------------------------------------------------------------
# Defaults / CLI parsing
# ---------------------------------------------------------------------
ENV=""
DEPLOY_YAML=""
RUNTIME_ENV_TMPL=""
IMAGE_REF="${IMAGE_REF:-}"
LOCAL=0
DRY_RUN=0
SKIP_APPLY_CONFIG=0
SKIP_PULL=0
SSH_KEY_FILE="${TARGET_SSH_KEY_FILE:-}"
APPLY_CONFIG_SH="${REPO_ROOT}/scripts/apply-config.sh"
WM_MCP_USER="${MSR_ADMIN_USER:-Administrator}"
WM_MCP_PASSWORD="${MSR_ADMIN_PASSWORD:-manage}"

usage() {
    sed -n 's/^# \{0,1\}//p' "$0" | sed -n '2,80p'
}

while (( $# > 0 )); do
    case "$1" in
        ENV=*)             ENV="${1#ENV=}"; shift ;;
        IMAGE_REF=*)       IMAGE_REF="${1#IMAGE_REF=}"; shift ;;
        --env)             ENV=$2; shift 2 ;;
        --image-ref)       IMAGE_REF=$2; shift 2 ;;
        --deploy-yaml)     DEPLOY_YAML=$2; shift 2 ;;
        --runtime-env-tmpl) RUNTIME_ENV_TMPL=$2; shift 2 ;;
        --ssh-key-file)    SSH_KEY_FILE=$2; shift 2 ;;
        --local)           LOCAL=1; shift ;;
        --dry-run)         DRY_RUN=1; shift ;;
        --skip-apply-config) SKIP_APPLY_CONFIG=1; shift ;;
        --skip-pull)       SKIP_PULL=1; shift ;;
        -h|--help)         usage; exit 0 ;;
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
# Reject mutable tags. Immutable refs are either pinned by digest
# (@sha256:...) or include a sha7-suffixed tag like "-svc-<sha7>". The
# task spec is explicit: "pulls the image SHA we just built (immutable
# tag, never `latest`)". A typo'd `latest` should fail loud, not
# silently deploy whatever happens to be at the head of that tag today.
case "${IMAGE_REF}" in
    *:latest|*-latest|*-latest-*)
        echo "ERROR: IMAGE_REF must be an immutable tag/digest, not '${IMAGE_REF}'" >&2
        echo "       use a SHA-pinned tag (e.g. ...:11.1.0-svc-abc1234) or @sha256:... digest" >&2
        exit 1 ;;
esac

DEPLOY_YAML=${DEPLOY_YAML:-${REPO_ROOT}/config/${ENV}/deploy.yaml}
RUNTIME_ENV_TMPL=${RUNTIME_ENV_TMPL:-${REPO_ROOT}/config/${ENV}/runtime.env.tmpl}

if [[ ! -f "${DEPLOY_YAML}" ]]; then
    echo "ERROR: deploy descriptor not found: ${DEPLOY_YAML}" >&2
    exit 1
fi
if [[ ! -f "${RUNTIME_ENV_TMPL}" ]]; then
    echo "ERROR: runtime env template not found: ${RUNTIME_ENV_TMPL}" >&2
    exit 1
fi

# Prerequisite tools. python3+PyYAML for the deploy.yaml parser, jq
# is not required here -- deploy.yaml is small and we use python
# directly. ssh/scp only when remote.
require_tools() {
    local missing=()
    for tool in python3; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if (( LOCAL == 0 )); then
        for tool in ssh scp; do
            command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
        done
    fi
    if (( ${#missing[@]} > 0 )); then
        printf 'ERROR: required tool(s) not found: %s\n' "${missing[*]}" >&2
        return 1
    fi
    if ! python3 -c 'import yaml' 2>/dev/null; then
        echo "ERROR: PyYAML not importable (pip install pyyaml)" >&2
        return 1
    fi
}
require_tools || exit 1
render_properties_require_tools || exit 1

# ---------------------------------------------------------------------
# Read deploy.yaml. We dump the few fields we need into shell vars
# via a single python invocation. Any missing field is fatal.
# ---------------------------------------------------------------------
parse_deploy_yaml() {
    python3 - "$1" <<'PY'
import os, sys, shlex
import yaml

with open(sys.argv[1]) as fh:
    doc = yaml.safe_load(fh)


def need(d, path):
    cur = d
    for key in path.split("."):
        if not isinstance(cur, dict) or key not in cur:
            print(f"ERROR: deploy.yaml missing required field: {path}", file=sys.stderr)
            sys.exit(1)
        cur = cur[key]
    return cur


target = need(doc, "target")
container = need(doc, "container")
smoke = need(doc, "smoke")

target_kind = need(doc, "target.kind")
if target_kind != "docker-ssh":
    print(f"ERROR: deploy.yaml target.kind must be 'docker-ssh', got '{target_kind}'", file=sys.stderr)
    sys.exit(1)

# target.host can be overridden by env var TARGET_HOST -- read it from
# os.environ here so the YAML file can stay source-controlled with a
# placeholder while CI injects the real host.
host = os.environ.get("TARGET_HOST") or need(doc, "target.host")
user = os.environ.get("TARGET_USER") or target.get("user", "deploy")
port = os.environ.get("TARGET_PORT") or str(target.get("port", 22))
ssh_key_file = os.environ.get("TARGET_SSH_KEY_FILE") or target.get("ssh_key_file", "")

name = need(doc, "container.name")
image_repo = need(doc, "container.image_repository")
restart = container.get("restart", "always")
publish = container.get("publish", []) or []
env_file_template = container.get("env_file_template", "")

smoke_path = need(doc, "smoke.path")
smoke_port = str(smoke.get("port", 5555))
smoke_timeout = str(smoke.get("timeout_seconds", 120))
smoke_interval = str(smoke.get("interval_seconds", 3))

apply_cfg = doc.get("apply_config", {}) or {}
apply_enabled = "1" if apply_cfg.get("enabled", True) else "0"
apply_via_exec = "1" if apply_cfg.get("via_docker_exec", True) else "0"


def emit(k, v):
    # shell-safe single-line assignment
    print(f"{k}={shlex.quote(str(v))}")


emit("DY_HOST", host)
emit("DY_USER", user)
emit("DY_PORT", port)
emit("DY_SSH_KEY_FILE", ssh_key_file)
emit("DY_NAME", name)
emit("DY_IMAGE_REPO", image_repo)
emit("DY_RESTART", restart)
emit("DY_PUBLISH", "\n".join(publish))
emit("DY_ENV_FILE_TEMPLATE", env_file_template)
emit("DY_SMOKE_PATH", smoke_path)
emit("DY_SMOKE_PORT", smoke_port)
emit("DY_SMOKE_TIMEOUT", smoke_timeout)
emit("DY_SMOKE_INTERVAL", smoke_interval)
emit("DY_APPLY_ENABLED", apply_enabled)
emit("DY_APPLY_VIA_EXEC", apply_via_exec)
PY
}

deploy_vars=$(parse_deploy_yaml "${DEPLOY_YAML}") || exit 1
eval "${deploy_vars}"

CONTAINER_NAME="${DY_NAME}"
PREV_NAME="${CONTAINER_NAME}-prev"
IMAGE_REPO="${DY_IMAGE_REPO}"
RESTART_POLICY="${DY_RESTART}"
SMOKE_PATH="${DY_SMOKE_PATH}"
SMOKE_PORT="${DY_SMOKE_PORT}"
SMOKE_TIMEOUT="${DY_SMOKE_TIMEOUT}"
SMOKE_INTERVAL="${DY_SMOKE_INTERVAL}"

# Image-repo and ref consistency: if IMAGE_REF includes the registry
# part, it must agree with image_repository. We only WARN, never
# block -- DR scenarios may legitimately deploy from a mirror.
if [[ "${IMAGE_REF}" == */* ]] && [[ "${IMAGE_REF%@*}" != "${IMAGE_REPO}"* ]] && [[ "${IMAGE_REF%:*}" != "${IMAGE_REPO}" ]]; then
    echo "WARN: IMAGE_REF '${IMAGE_REF}' does not match deploy.yaml image_repository '${IMAGE_REPO}'" >&2
fi

# Re-read the publish list (one per line) into an array for
# command construction.
PUBLISH=()
if [[ -n "${DY_PUBLISH}" ]]; then
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        PUBLISH+=("$line")
    done <<<"${DY_PUBLISH}"
fi

# ---------------------------------------------------------------------
# Render runtime.env from the template using render-properties.sh
# (handles ${NAME} -> $NAME from the process env, errors on missing).
# ---------------------------------------------------------------------
RUNTIME_ENV_RENDERED=$(mktemp -t "wmcicd-runtime-${ENV}.XXXXXX.env")
trap '[[ -n "${RUNTIME_ENV_RENDERED:-}" ]] && rm -f -- "${RUNTIME_ENV_RENDERED}"' EXIT

echo "Rendering ${RUNTIME_ENV_TMPL} -> ${RUNTIME_ENV_RENDERED}"
render_properties "${RUNTIME_ENV_TMPL}" "${RUNTIME_ENV_RENDERED}" || {
    echo "ERROR: failed to render ${RUNTIME_ENV_TMPL}" >&2
    exit 1
}

# ---------------------------------------------------------------------
# SSH transport. In --local mode all "remote" commands run via the
# local shell. In remote mode we keep one ControlMaster connection
# for the whole deploy so each step doesn't pay handshake cost.
# ---------------------------------------------------------------------
SSH_HOST="${DY_HOST}"
SSH_USER="${DY_USER}"
SSH_PORT="${DY_PORT}"

# If TARGET_SSH_KEY (raw key content) is set and no key file is set,
# materialise it to a temp file with mode 0600. This is the GHA pattern
# (`secrets.TARGET_SSH_KEY` is the key text).
if [[ -z "${SSH_KEY_FILE}" ]] && [[ -n "${TARGET_SSH_KEY:-}" ]]; then
    SSH_KEY_FILE=$(mktemp -t wmcicd-ssh-key.XXXXXX)
    chmod 600 "${SSH_KEY_FILE}"
    printf '%s\n' "${TARGET_SSH_KEY}" > "${SSH_KEY_FILE}"
    # Extend the EXIT trap to scrub the key. We deliberately don't
    # reset trap; we re-build it.
    trap 'rm -f -- "${RUNTIME_ENV_RENDERED:-/dev/null}" "${SSH_KEY_FILE:-/dev/null}"' EXIT
fi
if [[ -z "${SSH_KEY_FILE}" ]]; then
    SSH_KEY_FILE="${DY_SSH_KEY_FILE}"
fi
# Expand a leading ~ since deploy.yaml may use it.
if [[ "${SSH_KEY_FILE}" == "~/"* ]]; then
    SSH_KEY_FILE="${HOME}/${SSH_KEY_FILE#~/}"
fi

# Build the ssh / scp invocations. ControlMaster removes per-call
# handshakes; StrictHostKeyChecking=accept-new avoids interactive
# prompts in CI without TOFU-bypassing the first connection.
SSH_CTL_PATH=""
SSH_CMD=()
SCP_CMD=()
if (( LOCAL == 0 )); then
    SSH_CTL_PATH=$(mktemp -u -t wmcicd-ssh-ctl.XXXXXX)
    SSH_OPTS=(
        -o "StrictHostKeyChecking=accept-new"
        -o "BatchMode=yes"
        -o "ConnectTimeout=10"
        -o "ControlMaster=auto"
        -o "ControlPath=${SSH_CTL_PATH}"
        -o "ControlPersist=600"
        -p "${SSH_PORT}"
    )
    if [[ -n "${SSH_KEY_FILE}" ]]; then
        if [[ ! -f "${SSH_KEY_FILE}" ]]; then
            echo "ERROR: SSH key file not found: ${SSH_KEY_FILE}" >&2
            exit 1
        fi
        SSH_OPTS+=(-i "${SSH_KEY_FILE}" -o "IdentitiesOnly=yes")
    fi
    SSH_CMD=(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}")
    # scp uses -P for port (uppercase). Other options pass through.
    SCP_CMD=(scp -P "${SSH_PORT}" -o "StrictHostKeyChecking=accept-new" -o "BatchMode=yes" -o "ControlPath=${SSH_CTL_PATH}")
    if [[ -n "${SSH_KEY_FILE}" ]]; then
        SCP_CMD+=(-i "${SSH_KEY_FILE}" -o "IdentitiesOnly=yes")
    fi
fi

# Run a command "on the host". In local mode just exec it via bash -c;
# in remote mode, ssh it. Stdin can be piped in either case.
remote_exec() {
    if (( DRY_RUN == 1 )); then
        echo "[DRY-RUN remote] $*" >&2
        return 0
    fi
    if (( LOCAL == 1 )); then
        bash -c "$*"
    else
        "${SSH_CMD[@]}" -- "$@"
    fi
}

# Copy a file to the host. In local mode just cp; in remote mode scp.
remote_put() {
    local src=$1
    local dst=$2
    if (( DRY_RUN == 1 )); then
        echo "[DRY-RUN copy] ${src} -> ${dst}" >&2
        return 0
    fi
    if (( LOCAL == 1 )); then
        # Same host. Copy via plain cp; the destination dir might be
        # the same as src (tmpfile) so guard.
        if [[ "${src}" != "${dst}" ]]; then
            cp -- "${src}" "${dst}"
        fi
    else
        "${SCP_CMD[@]}" -- "${src}" "${SSH_USER}@${SSH_HOST}:${dst}"
    fi
}

cleanup_ssh_master() {
    if (( LOCAL == 0 )) && [[ -n "${SSH_CTL_PATH}" ]] && [[ -e "${SSH_CTL_PATH}" ]]; then
        ssh -o "ControlPath=${SSH_CTL_PATH}" -O exit "${SSH_USER}@${SSH_HOST}" 2>/dev/null || true
    fi
}

# Compose final cleanup. We chain trap actions: render-env tmpfile,
# optional key file, optional ssh control path.
final_cleanup() {
    local rc=$?
    cleanup_ssh_master
    [[ -n "${RUNTIME_ENV_RENDERED:-}" ]] && rm -f -- "${RUNTIME_ENV_RENDERED}"
    if [[ -n "${TARGET_SSH_KEY:-}" ]] && [[ -n "${SSH_KEY_FILE:-}" ]]; then
        rm -f -- "${SSH_KEY_FILE}"
    fi
    return $rc
}
trap final_cleanup EXIT

# ---------------------------------------------------------------------
# Plan summary (always printed -- audit trail in CI logs)
# ---------------------------------------------------------------------
echo
echo "============================================================"
echo " docker-ssh deploy plan"
echo "============================================================"
echo "  env             : ${ENV}"
echo "  target          : ${SSH_USER}@${SSH_HOST}:${SSH_PORT}$( ((LOCAL==1)) && echo "  (--local)" )"
echo "  container       : ${CONTAINER_NAME}  (prev=${PREV_NAME})"
echo "  image           : ${IMAGE_REF}"
echo "  publish         : ${PUBLISH[*]:-(none)}"
echo "  smoke           : http://localhost:${SMOKE_PORT}${SMOKE_PATH}  (${SMOKE_TIMEOUT}s)"
echo "  apply-config    : enabled=${DY_APPLY_ENABLED}  via_docker_exec=${DY_APPLY_VIA_EXEC}"
echo "  runtime env     : ${RUNTIME_ENV_TMPL} -> ${RUNTIME_ENV_RENDERED}"
echo "============================================================"
echo

# ---------------------------------------------------------------------
# Step 1: registry login (only if creds are supplied)
# ---------------------------------------------------------------------
if [[ -n "${REGISTRY_USER:-}" ]] && [[ -n "${REGISTRY_TOKEN:-}" ]]; then
    # Derive registry host from IMAGE_REF (everything before the first /).
    registry_host="${IMAGE_REF%%/*}"
    if [[ "${registry_host}" != *.* ]] && [[ "${registry_host}" != *:* ]]; then
        registry_host="docker.io"
    fi
    echo "==> docker login ${registry_host}"
    remote_exec "echo '${REGISTRY_TOKEN}' | docker login '${registry_host}' --username '${REGISTRY_USER}' --password-stdin"
fi

# ---------------------------------------------------------------------
# Step 2: docker pull (the new image, by immutable ref)
# ---------------------------------------------------------------------
if (( SKIP_PULL == 1 )); then
    echo "==> skip docker pull (--skip-pull); assuming ${IMAGE_REF} is already on the host"
else
    echo "==> docker pull ${IMAGE_REF}"
    remote_exec "docker pull ${IMAGE_REF}"
fi

# ---------------------------------------------------------------------
# Step 3: copy rendered runtime.env to the host. Default to a
# user-writable path under $HOME so the deploy user doesn't need sudo
# to manage state. Override via STATE_DIR env var when a system path
# is preferred (e.g. /var/lib/wmcicd/<env>) -- in that case the deploy
# user must already have write permission to the parent.
# ---------------------------------------------------------------------
REMOTE_STATE_DIR="${STATE_DIR:-\$HOME/.wmcicd/${ENV}}"
REMOTE_ENV_FILE="${REMOTE_STATE_DIR}/runtime.env"
echo "==> install env file -> ${REMOTE_ENV_FILE}"
remote_exec "install -d -m 0750 ${REMOTE_STATE_DIR}"
if (( LOCAL == 1 )); then
    if (( DRY_RUN == 1 )); then
        echo "[DRY-RUN copy] ${RUNTIME_ENV_RENDERED} -> ${REMOTE_ENV_FILE}" >&2
    else
        # In local mode REMOTE_STATE_DIR may include a literal $HOME
        # (we deferred expansion so the path quotes correctly through
        # ssh in remote mode). Expand it once for the local install.
        local_state_dir=$(eval echo "${REMOTE_STATE_DIR}")
        local_env_file="${local_state_dir}/runtime.env"
        install -d -m 0750 "${local_state_dir}"
        install -m 0600 -- "${RUNTIME_ENV_RENDERED}" "${local_env_file}"
        REMOTE_ENV_FILE="${local_env_file}"
    fi
else
    REMOTE_TMP="/tmp/wmcicd-runtime-${ENV}.$$.env"
    remote_put "${RUNTIME_ENV_RENDERED}" "${REMOTE_TMP}"
    remote_exec "install -m 0600 ${REMOTE_TMP} ${REMOTE_ENV_FILE} && rm -f ${REMOTE_TMP}"
fi

# ---------------------------------------------------------------------
# Step 4: container swap.
#   - If <name>-prev exists, remove it (only one rollback slot kept).
#   - If <name> exists: stop it, rename to <name>-prev. This frees
#     the canonical port mappings so the new run can grab them.
#   - docker run new container with canonical name + ports.
# ---------------------------------------------------------------------
echo "==> swap container ${CONTAINER_NAME} (rename old, start new)"
swap_script=$(cat <<EOF
set -eu
exists() { docker inspect "\$1" >/dev/null 2>&1; }
if exists "${PREV_NAME}"; then
  docker rm -f "${PREV_NAME}" >/dev/null
fi
if exists "${CONTAINER_NAME}"; then
  docker stop "${CONTAINER_NAME}" >/dev/null || true
  docker rename "${CONTAINER_NAME}" "${PREV_NAME}"
fi
EOF
)
remote_exec "${swap_script}"

# Build the docker run command. Quoted/escaped so it survives
# transport through ssh + bash -c.
docker_run_args=()
docker_run_args+=(-d)
docker_run_args+=(--name "${CONTAINER_NAME}")
docker_run_args+=(--restart="${RESTART_POLICY}")
docker_run_args+=(--env-file "${REMOTE_ENV_FILE}")
for p in "${PUBLISH[@]}"; do
    docker_run_args+=(-p "${p}")
done
docker_run_args+=("${IMAGE_REF}")

# Render the run command as a single string for remote_exec. shlex
# in python is overkill here; we control every arg, so manual quoting
# of the values that may contain spaces is sufficient.
build_run_cmd() {
    local out="docker run"
    local a
    for a in "${docker_run_args[@]}"; do
        # Quote with single quotes; escape any embedded single quote.
        local esc=${a//\'/\'\\\'\'}
        out="${out} '${esc}'"
    done
    printf '%s' "${out}"
}
RUN_CMD=$(build_run_cmd)
echo "==> ${RUN_CMD}"
remote_exec "${RUN_CMD}"

# ---------------------------------------------------------------------
# Step 5: smoke wait. We poll docker-exec into the new container so
# we don't depend on a host-side port being reachable yet (and we
# match exactly the path/port of the base image's HEALTHCHECK).
# ---------------------------------------------------------------------
echo "==> waiting for ${CONTAINER_NAME} smoke (timeout ${SMOKE_TIMEOUT}s)"
smoke_script=$(cat <<EOF
set -eu
deadline=\$(( \$(date +%s) + ${SMOKE_TIMEOUT} ))
while :; do
  status=\$(docker inspect -f '{{.State.Status}}' "${CONTAINER_NAME}" 2>/dev/null || echo missing)
  case "\${status}" in
    exited|dead|removing|missing)
      # The container is not coming back. Don't wait the full
      # timeout; surface logs immediately so the operator sees what
      # killed it.
      echo "FAIL: ${CONTAINER_NAME} status=\${status} (terminal); not waiting further" >&2
      docker logs --tail=80 "${CONTAINER_NAME}" >&2 || true
      exit 1 ;;
    running) ;;
    *)
      # created / restarting / paused -- transient, give it more time.
      if [ \$(date +%s) -ge \${deadline} ]; then
        echo "FAIL: ${CONTAINER_NAME} status=\${status} after ${SMOKE_TIMEOUT}s" >&2
        docker logs --tail=80 "${CONTAINER_NAME}" >&2 || true
        exit 1
      fi
      sleep ${SMOKE_INTERVAL}
      continue ;;
  esac
  if docker exec "${CONTAINER_NAME}" curl -fs -o /dev/null \
       "http://localhost:${SMOKE_PORT}${SMOKE_PATH}"; then
    echo "OK: ${CONTAINER_NAME} ${SMOKE_PATH} returned 2xx"
    exit 0
  fi
  if [ \$(date +%s) -ge \${deadline} ]; then
    echo "FAIL: ${SMOKE_PATH} did not return 2xx within ${SMOKE_TIMEOUT}s" >&2
    docker logs --tail=80 "${CONTAINER_NAME}" >&2 || true
    exit 1
  fi
  sleep ${SMOKE_INTERVAL}
done
EOF
)
if ! remote_exec "${smoke_script}"; then
    echo "ERROR: smoke check failed; old (${PREV_NAME}) and new (${CONTAINER_NAME}) both kept" >&2
    exit 2
fi

# ---------------------------------------------------------------------
# Step 6: apply-config against the new container. We invoke
# scripts/apply-config.sh with --container <new-name>; it docker-execs
# wm-mcp inside, so no host-side admin port is required.
#
# In remote mode the apply runs ON THE TARGET HOST, so apply-config.sh
# (and its lib/ helpers) must be present there. In CI this is solved
# by checking out the repo on the target during the appleboy/ssh-action
# step; for the WSL acceptance test (--local) the script is already
# at REPO_ROOT.
# ---------------------------------------------------------------------
if (( SKIP_APPLY_CONFIG == 0 )) && [[ "${DY_APPLY_ENABLED}" == "1" ]]; then
    echo "==> apply-config --env ${ENV} --container ${CONTAINER_NAME}"
    # apply-config.sh takes --user/--password as CLI args and resolves
    # ${SECRET:NAME} placeholders from the process environment. We
    # inherit the parent env so any DB_PASSWORD_* / GV_* the operator
    # exported (or that CI loaded from GitHub Environment Secrets)
    # flow through to apply-config without us enumerating them.
    qpass=$(printf '%q' "${WM_MCP_PASSWORD}")
    qenv=$(printf '%q' "${ENV}")
    qcontainer=$(printf '%q' "${CONTAINER_NAME}")
    quser=$(printf '%q' "${WM_MCP_USER}")
    if (( LOCAL == 1 )); then
        if (( DRY_RUN == 1 )); then
            echo "[DRY-RUN local] ${APPLY_CONFIG_SH} --env ${qenv} --container ${qcontainer} --user ${quser} --password <redacted>"
        elif ! "${APPLY_CONFIG_SH}" --env "${ENV}" --container "${CONTAINER_NAME}" --user "${WM_MCP_USER}" --password "${WM_MCP_PASSWORD}"; then
            echo "ERROR: apply-config failed; old (${PREV_NAME}) and new (${CONTAINER_NAME}) both kept" >&2
            exit 2
        fi
    else
        # Remote: apply-config.sh on the target is assumed to be at
        # the same repo path the CI workflow checked out. Override
        # via APPLY_CONFIG_REMOTE if the on-host layout differs.
        # The appleboy/ssh-action `envs:` field is responsible for
        # forwarding any ${SECRET:NAME} env vars the apply step needs.
        remote_apply_sh="${APPLY_CONFIG_REMOTE:-${APPLY_CONFIG_SH}}"
        if ! remote_exec "${remote_apply_sh} --env ${qenv} --container ${qcontainer} --user ${quser} --password ${qpass}"; then
            echo "ERROR: apply-config failed; old (${PREV_NAME}) and new (${CONTAINER_NAME}) both kept" >&2
            exit 2
        fi
    fi
else
    echo "==> apply-config skipped (SKIP_APPLY_CONFIG=${SKIP_APPLY_CONFIG} or deploy.yaml apply_config.enabled=false)"
fi

# ---------------------------------------------------------------------
# Step 7: finalize. Remove the renamed-old container so only the new
# canonical container remains.
# ---------------------------------------------------------------------
echo "==> finalize: rm ${PREV_NAME}"
remote_exec "if docker inspect ${PREV_NAME} >/dev/null 2>&1; then docker rm -f ${PREV_NAME} >/dev/null; fi"

echo
echo "Deploy succeeded. ${CONTAINER_NAME} is serving on:"
for p in "${PUBLISH[@]}"; do
    echo "  -p ${p}"
done
exit 0
