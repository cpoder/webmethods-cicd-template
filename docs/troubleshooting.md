# Troubleshooting catalogue — wm-microservice CI/CD

Failure-mode catalogue. Symptom → likely cause → fix. The runbook
[`docs/runbook.md`](runbook.md) is the task-oriented page; this is
the symptom-oriented one. New entries land here whenever an incident
turns up a recipe future-on-call should not have to re-derive.

## How to use this page

1. Find the symptom that matches the failure (job name + first error
   line is usually enough).
2. Read **Likely cause** before you start changing things.
3. Apply **Fix**.
4. If none of the entries match, the failure is novel — add an entry
   when you've solved it.

---

## §1. Package install fails

### 1a. `wm-mcp package_install` exits non-zero with `ClassNotFoundException`

**Symptom (CI log):**

```
[lint-packages] wm-mcp package_install --file /tmp/MyPkg-1.0.0.zip
... ClassNotFoundException: org.postgresql.Driver
... package start failed
exit 1
```

The same shape appears in `cd.yml`'s deploy logs as a startup error
on the new container.

**Likely cause:**
The package needs a JDBC driver that is not in the base image's
`packages/WmJDBCAdapter/code/jars/` directory. **Per-package JDBC
drivers are wrong** — `WmJDBCAdapter` only loads from one well-known
path, so duplicating drivers under `packages/MyPkg/code/jars/` is
silently ignored.

**Fix:**

```sh
# Drop the driver into the base image's shared dir.
cp postgresql-42.7.3.jar docker/base/jars/

# *.jar is gitignored at repo root; force-add this one.
git add -f docker/base/jars/postgresql-42.7.3.jar
git commit -m "chore(base): add postgres jdbc 42.7.3"
```

Push → `base-image.yml` triggers (the workflow watches
`docker/base/**`). Wait for the new base image to publish, then
re-run CI on the package PR.

**Verify on a running container:**

```sh
docker exec wm-svc-dev ls /opt/softwareag/IntegrationServer/instances/default/packages/WmJDBCAdapter/code/jars | grep -i postgres
```

### 1b. `package_install` reports `MissingDependency`

**Symptom:**

```
... MissingDependency: WmPublic >=10.15
... package start failed
```

**Likely cause:**
The package's `manifest.v3` declares a dependency on a package that
isn't in the base image (or that's pinned to a higher version than
the base image carries).

**Fix:**
Open `manifest.v3` and check `<requires>`. Either widen the version
constraint to `^10.x`, or add the missing dependency package under
`packages/<dep>/`. The MSR built-in whitelist lives in
`scripts/lib/manifest.sh`'s `WM_BUILTIN_PACKAGES` and can be extended
at CI time via the `WM_BUILTIN_PACKAGES_EXTRA` env var (in
`.github/workflows/ci.yml`).

### 1c. Package zip layout is wrong

**Symptom:**

```
... package_install: archive root must contain <PackageName>/manifest.v3
```

**Likely cause:**
You produced the zip outside `scripts/build-packages.sh`. The script
emits the spec layout (`<PackageName>/manifest.v3` at archive root);
hand-rolled zips that include a leading `packages/` path will fail.

**Fix:** rebuild via `bash scripts/build-packages.sh`.

---

## §2. Config apply fails

### 2a. `apply-config.sh` aborts on a `${SECRET:NAME}` placeholder

**Symptom (deploy log):**

```
[apply-config] resolving secrets in effective.dev.json
ERROR: unresolved secret placeholder: ${SECRET:DB_PASSWORD_ORDERS_DB}
exit 1
```

**Likely cause:**
A YAML overlay references a secret name that wasn't injected into
the runner's environment. This is by far the most common
`apply-config` failure. There are three common variants:

1. The secret simply isn't set in the GitHub Environment for that
   env (`gh secret list --env <env>` → not present).
2. The secret IS set but the workflow job's `env:` block doesn't
   forward it (the workflow only forwards what it explicitly names —
   it does NOT auto-broadcast every `secrets.*`).
3. The secret name in `docs/secrets.md` was renamed without updating
   the YAML or the workflow.

**Fix:**

```sh
# (1) Audit which secrets are missing in env <env>.
ENVIRONMENTS="<env>" scripts/setup-environments.sh --check

# (2) Set the missing one.
gh secret set DB_PASSWORD_ORDERS_DB --env <env> --body "<from-vault>"

# (3) If the workflow doesn't forward it, add it under env: in the
#     deploy-<env> job in cd.yml AND under env: in the rollback-<env>
#     job in cd.yml + rollback.yml.
```

Re-run the failed deploy with `gh run rerun <run-id> --failed`.

### 2b. `*_secret_ref: vault://...` reports "vault not configured"

**Symptom:**

```
[wm-mcp] secret_ref vault://kv/data/db/orders → ERROR: vault address not set
```

**Likely cause:**
The runtime side of secret resolution (Vault / k8s `ExternalSecret`)
isn't wired. `${SECRET:NAME}` placeholders are resolved at
**apply time** by `scripts/lib/secret-resolver.sh` — they need an
env var. `*_secret_ref` URIs are resolved by **wm-mcp at runtime**
inside the container — they need Vault/k8s plumbing.

**Fix:**

- For Kubernetes: `externalSecrets.enabled=true` in
  `helm/wm-microservice/values-<env>.yaml` and `ExternalSecret` CRDs
  installed in the cluster.
- Set the optional bootstrap secrets `VAULT_ADDR`, `VAULT_ROLE_ID`,
  `VAULT_SECRET_ID` in the env (see `docs/secrets.md`).
- Or convert the YAML to use `${SECRET:NAME}` placeholders + a
  `gh secret set NAME` (the simpler path for envs without Vault).

### 2c. `validate-config` rejects a sparse overlay

**Symptom (PR check):**

```
[config-validate] config/dev/jdbc-pools.yaml: pools[0]: 'driver' is required
```

**Likely cause:**
The schema in `schemas/config.schema.json` requires multiple fields
per list item; an overlay that only sets the URL fails because it
omits `driver`. (Documented as a latent gotcha in Task 3.1 —
overlays are currently full-form, not patch-form.)

**Fix:**
Carry the full pool object in the overlay even if you only intend
to override one field. The list-merge in `scripts/lib/yaml-merge.sh`
identifies items by `pools[].alias`; matching aliases are
deep-merged.

### 2d. `apply-config` is idempotent — but config drifts back

**Symptom:**
A change you applied via `wm-mcp` directly on the box is
"forgotten" on the next deploy.

**Likely cause:**
`apply-config.sh` re-asserts the YAML overlay tree on every deploy.
Manual changes inside the container do not round-trip into the repo
and get overwritten.

**Fix:**
Encode the change in `config/<env>/<file>.yaml`, PR it, and let CD
roll it forward. **Manual `wm-mcp` calls are for triage only.**

---

## §3. Smoke fails

### 3a. `wm.server:ping` returns 200 but `getServerVersion` is 401

**Symptom (smoke log):**

```
[smoke] /invoke/wm.server:ping        → 200 OK
[smoke] /invoke/wm.server:getServerVersion → 401 Unauthorized
exit 2
```

**Likely cause:**
Anonymous ping works, so MSR is up; admin-auth fails, so the
`MSR_ADMIN_PASSWORD` the smoke job is using and the password in
the freshly applied config disagree. Common variants:

1. The secret was rotated in vault but the GitHub Environment
   secret wasn't updated.
2. `apply-config` set a different password than the smoke job
   reads, because the YAML uses `${SECRET:USER_PASSWORD_ADMINISTRATOR}`
   and the secret name in `docs/secrets.md` was renamed.

**Fix:**

```sh
# Confirm the ping works -- baseline is fine.
curl -fs https://${ENV_URL}/invoke/wm.server:ping

# Re-set the password from vault.
gh secret set MSR_ADMIN_PASSWORD --env <env> --body "<from-vault>"
gh workflow run cd.yml -f target_env=<env>
```

### 3b. Smoke 200s but a downstream flow fails on first call

**Symptom (post-rollout, application logs):**

```
... GreetingService: lookup of GV 'API_TOKEN' returned null
... NullPointerException at com.acme.greet.invoke
```

**Likely cause:**
A new global variable required by your package is referenced in
code but not declared in `config/base/global-variables.yaml`.
`apply-config` only sets variables it knows about; the runtime
returns null for the rest.

**Fix:**

```yaml
# config/base/global-variables.yaml
variables:
  - key: API_TOKEN
    type: PASSWORD
    value: ${SECRET:GV_API_TOKEN}
    description: External API token used by GreetingService
```

Add `GV_API_TOKEN` to `SECRETS_COMMON` in
`scripts/setup-environments.sh` and to `docs/secrets.md`. PR + merge
+ re-deploy.

### 3c. Smoke times out on prod after a green dev/test rollout

**Symptom:**

```
[smoke] waited 360s for /invoke/wm.server:ping; last status: connection refused
exit 2
```

**Likely cause:**
Pod is starting but slowly. IS cold-start on prod-sized JVM heaps
+ external connections (LDAP, Vault, JDBC) can blow past the
liveness `initialDelaySeconds`. The container goes into CrashLoop
and the kubelet never gets a healthy pod.

**Fix:**

1. Confirm: `kubectl logs -n wm-svc-prod <pod> --previous` ends in
   `IS instance startup complete` (good, kubelet just killed it
   too early) or in `OutOfMemoryError` (bad, see §4 below).
2. Bump `probes.liveness.initialDelaySeconds` in
   `helm/wm-microservice/values-prod.yaml` to e.g. `420`.
3. Re-deploy.

### 3d. Smoke fails right after a port-forward cleanup

**Symptom (post-deploy on the runner, k8s backend):**

```
[k8s-helm] tearing down port-forward
[smoke]     curl: (7) Failed to connect to localhost:15555
```

**Likely cause:**
The smoke job runs against `${{ vars.<ENV>_URL }}` (the public
URL), not via the runner's port-forward. If `<ENV>_URL` isn't set
as a GitHub Environment **variable** (note: variable, not secret),
`SMOKE_TARGET` is empty and `tests/integration/smoke/run.sh` fails
on the first hop.

**Fix:**

```sh
gh variable set DEV_URL --env dev --body "https://wm-svc-dev.example.com"
```

Repeat for `TEST_URL`, `PROD_URL`, and any new env's
`<ENV>_URL`.

---

## §4. CrashLoop / OOM after deploy

### 4a. Pod restarts every ~3 minutes with `OutOfMemoryError` in `--previous` log

**Likely cause:**
JVM heap too small for the new code path (often a flow that buffers
a Kafka batch, or an audit-logging change).

**Fix (short-term):**

```yaml
# helm/wm-microservice/values-<env>.yaml
resources:
  limits:
    memory: 4Gi    # was 2Gi
  requests:
    memory: 2Gi
```

Pair with a JVM heap bump in
`config/base/extended-settings.properties` (`watt.server.jvm.heap.max=...`)
if your base image doesn't auto-derive heap from cgroup limits.

### 4b. Pod is `Running 0/1` indefinitely

**Likely cause:**
Readiness probe fails because IS is still initialising packages.
Usually transient (180–300s).

**Fix:** wait. If still red after 5 min:

```sh
kubectl exec -n <ns> <pod> -- tail -50 \
  /opt/softwareag/IntegrationServer/instances/default/logs/server.log
```

Look for the package install line that *isn't* followed by
`package successfully started` — that's the offender.

---

## §5. Security gate failures

### 5a. `gitleaks` flags a "secret" that's actually a sample

**Likely cause:**
`gitleaks` runs over the diff with the default rule pack. Sample
keys (`AKIAIOSFODNN7EXAMPLE`) are already in `.gitleaks.toml`'s
allowlist; new docs that introduce a new sample format aren't.

**Fix:**
Add the regex to `[[allowlists]]` in `.gitleaks.toml`. Re-run.

### 5b. `trivy` fails the PR with HIGH/CRITICAL CVEs in a transitive dep

**Likely cause:**
Upstream dep released an advisory; trivy database picked it up.

**Fix:**
Bump the dep, file an exception in `.trivyignore` if the CVE doesn't
apply, or wait for an upstream patch. CRITICAL fails the PR; HIGH
warns. See `docs/security-gates.md` §A2 for the contract.

### 5c. `cosign verify` fails on the base image

**Likely cause:**
Base image was built from a feature branch; the prod identity is
pinned to `refs/heads/main`. `image-security.yml` deliberately
refuses non-main base images.

**Fix:** rebuild `base-image.yml` from `main`.

---

## §6. Rollback itself failed

### 6a. `rollback-prod` job red with "no previous successful deployment"

**Likely cause:**
First deploy ever, or the GitHub Deployments API was wiped.
`scripts/deploy/rollback.sh` looks for a status=success deployment
with `payload.image_ref`. None present → fail-fast.

**Fix:**

```sh
# Find a known-good SHA from git history.
git log --first-parent main --pretty=oneline | head -10

# Pass it explicitly.
gh workflow run rollback.yml -f env=prod -f to_sha=<that-sha>
```

### 6b. `rollback-prod` succeeded but pods are still on the old (broken) image

**Likely cause:**
helm release `superseded` reverted the chart values, but the rolled
image was already mid-rollout when atomic rollback fired. The
`Deployment` reverted; existing pods may not have been terminated.

**Fix:**

```sh
kubectl rollout restart deployment wm-svc-prod -n wm-svc-prod
```

If the issue is that ImagePullBackOff is masking the rolled state:

```sh
kubectl describe pod -n wm-svc-prod -l app.kubernetes.io/instance=wm-svc-prod | grep -A2 Events
```

---

## §7. CI flake (not actually broken)

### 7a. `integration-tests` fails with `connection refused` on a sidecar

**Likely cause:**
`docker compose up -d --wait` raced ahead of the sidecar's actual
readiness — particularly Artemis on a cold cache. The compose `--wait`
flag honours healthcheck windows; some sidecar images don't ship one.

**Fix:** re-run the job. If it flakes more than once a week, add /
tighten the healthcheck in `tests/integration/compose.yml`.

### 7b. `unit-tests` fails with "Test Suite installer not found"

**Likely cause:**
The corporate mirror returned 5xx for the Test Suite installer URL.
`docker/base/Dockerfile` --target test fetches it at build time.

**Fix:** re-run the job (CI's docker/build-push-action will
hit the mirror again). If it persists, page release-engineering —
the mirror or empower URL might be down.

---

## When to escalate

Escalate to release-engineering / platform-team owner when:

- Rollback itself fails (`rollback-<env>` job red), AND
- The redeploy isn't recoverable by re-running the workflow with a
  different `to_sha`.

Escalate to security when:

- `gitleaks` flags real production credentials in the repo
  history (not a false positive).
- `cosign verify` fails on a previously-signed image.
- Secret Scanning / Push Protection alerts you to an inbound push.

Page details for both teams: see `CODEOWNERS`.
