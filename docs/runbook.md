# Operator Runbook — wm-microservice CI/CD

The reference page when something is on fire (or just needs doing).
Audience: on-call platform engineer with `gh` CLI access and the
required `prod` reviewer permission.

> See [`docs/troubleshooting.md`](troubleshooting.md) for the
> failure-mode catalogue (symptom → root cause → fix). This page is
> task-oriented; troubleshooting is symptom-oriented.

---

## 0. Pager response — "deploy failed in prod, what do I do?"

You were paged because a `cd` workflow run failed. Work through this
ladder; stop as soon as one step succeeds.

| # | Action | Time |
|---|--------|------|
| 1 | Open the failed run in the **Actions** tab and identify which job failed: `deploy-prod`, `smoke-prod`, or `rollback-prod`. | 30s |
| 2 | If `rollback-prod` ran and finished green, prod is back on the previous image. **Stop**, write a postmortem, do not roll forward without a new fix. | — |
| 3 | If `deploy-prod` failed mid-rollout, helm `--atomic` already rolled the release back. Verify with `helm history wm-svc-prod -n wm-svc-prod` (top entry should be `superseded`/`rolled back`). | 1m |
| 4 | If `smoke-prod` failed but `rollback-prod` did NOT auto-fire (e.g. you cancelled the run), trigger the manual rollback: `gh workflow run rollback.yml -f env=prod -f to_sha=<previous-good-sha>`. See §1. | 2m |
| 5 | If apply-config failed (deploy was green but config drift killed the pod) the rollback default `--skip-apply-config` will restore service. Triage the offending overlay afterwards (§4 of troubleshooting.md). | 2m |
| 6 | Confirm the rolled-back service is healthy: `kubectl rollout status deployment/wm-svc-prod -n wm-svc-prod` and the smoke-rollback-prod artefact in the rollback run. | 1m |
| 7 | Page release-engineering ONLY if rollback itself failed (`rollback-prod` job red). At that point you are in "manual surgery" territory — see §6. | — |

The total time budget for steps 1–6 is under 10 minutes. If you are
past that and still red, escalate.

---

## 1. Roll back a deploy

### 1a. Auto-rollback (no operator action required)

`cd.yml` already runs `rollback-<env>` automatically when the
post-deploy smoke check fails. Each smoke job has a sibling
`rollback-<env>` gated on
`if: failure() && needs.smoke-<env>.result == 'failure'`. The auto
path uses the GitHub Deployments API to find the last successful
`image_ref` for the env and redeploys it with `--skip-apply-config`
(see [`scripts/deploy/rollback.sh`](../scripts/deploy/rollback.sh)).

### 1b. Manual rollback

Use this when:

- a regression surfaced *after* smoke went green, or
- you cancelled the auto-rollback and need to retry, or
- you want to roll prod to a specific older SHA, not just the
  one-before-current.

```sh
# Roll prod back to a known-good SHA. `to_sha` accepts full or 7-char.
gh workflow run rollback.yml \
  -f env=prod \
  -f to_sha=<previous-good-sha>
```

The workflow:

1. Resolves `to_sha` to an immutable image ref by walking the same
   tag candidates `cd.yml` uses (`main-<sha7>-<full>`, then
   `<MSR_VERSION>-svc-<sha7>`). Fails fast if neither exists.
2. Hits the GitHub Environment gate (prod = required reviewer +
   10-minute wait timer + `branch=main` policy — same as a forward
   deploy).
3. Calls `scripts/deploy/rollback.sh --env prod --image-ref <ref>`
   which dispatches to the right backend
   (`docker-ssh.sh` for dev/test, `k8s-helm.sh` for prod).
4. Re-runs the same `tests/integration/smoke/run.sh` after the
   rollback finishes.

Useful options:

```sh
# Don't pass to_sha -- rollback.sh falls back to "last successful
# deploy from the GitHub Deployments API". Equivalent to the
# auto-rollback path.
gh workflow run rollback.yml -f env=prod

# Re-apply current config tree against the rolled-back image. Off by
# default because the previous container ran against its previous
# config; opting in only makes sense when you've reverted the config
# change too and want it on the box.
gh workflow run rollback.yml -f env=prod -f to_sha=<sha> -f apply_config=true

# Tell rollback.sh which image is currently broken so the gh-api
# fallback skips past it.
gh workflow run rollback.yml -f env=prod \
   -f failed_image_ref=ghcr.io/<owner>/wm-svc:main-<bad-sha7>-<full>
```

### 1c. Rollback from a workstation (no Actions available)

If GitHub Actions is itself down:

```sh
export GITHUB_REPOSITORY=<owner>/<repo>
export GITHUB_TOKEN=<a PAT with deployments:write>
export TARGET_KUBECONFIG_B64=<base64 of kubeconfig.yaml>
export MSR_ADMIN_USER=Administrator
export MSR_ADMIN_PASSWORD=<from vault>

bash scripts/deploy/rollback.sh \
  --env prod \
  --image-ref ghcr.io/<owner>/wm-svc:main-<sha7>-<full>
```

Same exit codes as the workflow:
`0` rollback succeeded, `1` setup/lookup error, `2` redeploy failed.

---

## 2. Bump the MSR version

The MSR runtime version is pinned in
[`versions.env`](../versions.env) as `MSR_VERSION`. Bumping it is a
two-PR ladder.

```text
versions.env (PR)  ──►  base-image.yml builds new wm-msr-base
                                │
                                ▼
                       PR #2 (touches packages/ or
                       a no-op file under docker/service/)
                                │
                                ▼
                            ci.yml builds wm-svc on the new base
                                │
                                ▼
                            cd.yml deploys to dev → test → prod
```

Step-by-step:

1. **PR #1: bump `MSR_VERSION`.**
   ```sh
   git checkout -b feat/bump-msr-11.1.1
   sed -i 's/^MSR_VERSION=.*/MSR_VERSION=11.1.1/' versions.env
   git commit -am "chore: bump MSR_VERSION to 11.1.1"
   gh pr create --fill
   ```
   On merge, `base-image.yml` rebuilds and pushes
   `ghcr.io/<owner>/wm-msr-base:11.1.1-base*` (the workflow's `paths:`
   filter triggers on `versions.env`). It also signs with `cosign`
   and attaches an SPDX SBOM via `cosign attest`.

2. **Verify the new base image is signed and available.**
   ```sh
   cosign verify \
     --certificate-identity \
       "https://github.com/<owner>/<repo>/.github/workflows/base-image.yml@refs/heads/main" \
     --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
     ghcr.io/<owner>/wm-msr-base:11.1.1-base-latest
   ```

3. **PR #2: pull the new base into the service image.**
   The service Dockerfile reads `${BASE_IMAGE}` at build time and the
   CI workflow defaults it to `ghcr.io/<owner>/wm-msr-base:${MSR_VERSION}-base-latest`.
   So PR #2 can be empty (`git commit --allow-empty`) on `main`, or
   any normal change — `ci.yml` will rebuild the service image
   against the new base automatically.

4. **Deploy with `cd.yml`.** A merge to `main` auto-deploys to dev.
   Promote test/prod via `gh workflow run cd.yml -f target_env=test`
   and then `prod`.

Failure modes specific to MSR bumps:

| Symptom | Likely cause |
|---------|--------------|
| `base-image.yml` fails on `microdnf update` with HTTP 404 from UBI | New MSR tag not yet published to corporate mirror; wait or pin upstream. |
| `cosign verify` fails with `no matching certificate` | The base image was rebuilt off a feature branch — the prod identity is hard-pinned to `refs/heads/main` (see `image-security.yml`). Re-run `base-image.yml` from main. |
| `unit-tests` job fails with "Test Suite installer not found" | New `MSR_VERSION` needs a matching `WM_TEST_SUITE_INSTALLER_URL` in `versions.env`. |
| Smoke fails with `ConnectException` on a previously-green env | Liveness `initialDelaySeconds` is too short for the new MSR. Bump `probes.liveness.initialDelaySeconds` in `helm/wm-microservice/values-<env>.yaml`. |

---

## 3. Add a new IS package

Workflow contract: anything under `packages/<PackageName>/` is built
into a zip by `scripts/build-packages.sh`, baked into the service
image by `docker/service/Dockerfile`, and applied by the runtime on
boot. **No CI workflow edits are needed** — `ci.yml`'s `setup` job
emits the package matrix dynamically.

```sh
# 1. Create the package skeleton.
mkdir -p packages/MyPkg/ns/com/acme/mypkg
mkdir -p packages/MyPkg/code/{classes,jars,source}

# 2. Author the manifest.
cat > packages/MyPkg/manifest.v3 <<'EOF'
<?xml version="1.0"?>
<Manifest>
  <version>1.0</version>
  <description>My new package</description>
  <requires>
    <package version="^1.0">WmPublic</package>
  </requires>
  <startup_services/>
</Manifest>
EOF

# 3. Add at least one test (CI requires the unit-test scaffold to
#    exercise lint + coverage gates).
mkdir -p tests/unit/MyPkg
# ... write .wmTestSuite per docs/authoring-tests.md ...

# 4. Commit and open a PR.
git add packages/MyPkg tests/unit/MyPkg
git commit -m "feat(packages): add MyPkg"
gh pr create --fill
```

What CI does on your behalf, in order:

1. `setup` discovers `packages/MyPkg/` and adds it to the matrix.
2. `lint-packages` runs `wm-mcp` static checks
   (dependency / namespace / flow-validate / ACL audit).
3. `unit-tests` runs the WM Test Suite against your new package.
4. `build-image` produces `wm-svc:pr-<num>-<sha>` containing the
   package zip.
5. `integration-tests` boots that image with sidecars and runs
   Newman + k6 + REST-assured.
6. `contract-tests` diffs `api/openapi.yaml` against MSR-generated
   specs.
7. `security` runs gitleaks + trivy + the policy gates
   (`scripts/policy/check-*.sh`).
8. `gate` aggregates — green = merge → cd.yml.

**Common gotchas:**

- The package name in `manifest.v3`'s `<Manifest>` must match the
  directory name on disk. `scripts/lib/manifest.sh` reads it from
  the directory.
- A missing `<startup_services/>` element fails
  `scripts/policy/check-manifests.sh`. An empty self-closing element
  is fine.
- New JDBC drivers do NOT belong in `packages/MyPkg/code/jars/` —
  they go in `docker/base/jars/` so every service picks them up. See
  §6 of troubleshooting.md.

---

## 4. Add a new environment

Three layers must move in lockstep: config overlay, GitHub
Environment + secrets, and a `deploy-<new>` job in `cd.yml`.

```sh
NEW=staging       # the new env name, lowercase

# 1. Config overlay. Start from dev (always present) -- it has the
#    smallest, most-recently-touched footprint.
cp -r config/dev config/${NEW}
sed -i "s/dev/${NEW}/g" config/${NEW}/deploy.yaml config/${NEW}/runtime.env.tmpl

# Edit values that should differ per env:
#   - config/${NEW}/deploy.yaml: target.host, container.name,
#     image_repository (rarely), smoke.timeout_seconds
#   - config/${NEW}/global-variables.yaml: GV overrides for the env
#   - any *.yaml overlay you need (jdbc-pools, jms-aliases, etc)

# 2. Helm values file (only if target.kind: kubernetes-helm)
cp helm/wm-microservice/values-test.yaml \
   helm/wm-microservice/values-${NEW}.yaml
# Edit replicas / resources / probes / SAG_LICENSE_KEY_<env> name to
# match the new env.

# 3. Validate the overlays before committing.
bash scripts/validate-config.sh --env ${NEW}
```

Then bootstrap the GitHub Environment + secrets:

```sh
# 4. Add ${NEW} to the ENVIRONMENTS list in
#    scripts/setup-environments.sh, then:
ENVIRONMENTS="${NEW}" scripts/setup-environments.sh --apply \
   --prod-reviewer-team my-org/release-managers
# (For non-prod envs the reviewer is optional.)

# 5. Seed the secrets from docs/secrets.md. NEVER commit values; the
#    setup-environments.sh script does NOT read or set values.
gh secret set MSR_ADMIN_PASSWORD --env ${NEW} --body "<from-vault>"
gh secret set TARGET_KUBECONFIG_B64 --env ${NEW} --body "$(base64 -w0 ./kubeconfig-${NEW}.yaml)"
# ... continue for every name in SECRETS_COMMON ...

# 6. Audit -- this is what the platform team will check on review.
ENVIRONMENTS="${NEW}" scripts/setup-environments.sh --check
```

Finally, wire the new env into `cd.yml`:

```yaml
# .github/workflows/cd.yml
deploy-staging:
  name: deploy-staging
  needs: select-image
  if: needs.select-image.outputs.target_env == 'staging'
  environment:
    name: staging
    url: ${{ vars.STAGING_URL }}
  runs-on: ubuntu-latest
  outputs:
    image_ref: ${{ needs.select-image.outputs.image_ref }}
  steps:
    - uses: actions/checkout@v4
    - run: grep -E '^[A-Z][A-Z0-9_]*=' versions.env >> "$GITHUB_ENV"
    - run: python3 -m pip install --quiet pyyaml
    - name: Deploy
      env:
        ENV: staging
        IMAGE_REF: ${{ needs.select-image.outputs.image_ref }}
        # ... copy the secret-forwarding env block from deploy-test ...
      run: bash scripts/deploy/dispatch.sh
    - name: Record deployment
      if: success()
      env:
        GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        GH_REPO: ${{ github.repository }}
        IMG: ${{ needs.select-image.outputs.image_ref }}
        SHA: ${{ needs.select-image.outputs.sha }}
      run: bash scripts/deploy/record-deployment.sh staging "${SHA}" "${IMG}"
```

Add matching `smoke-staging` and `rollback-staging` jobs (copy from
the dev triplet — they only differ in env name and `vars.<ENV>_URL`).
Add `staging` to the `target_env` choice list at the top of `cd.yml`
and to the rollback workflow:

```yaml
# .github/workflows/rollback.yml
options: [dev, test, prod, staging]
```

(plus a sibling `rollback-staging` job — same shape as `rollback-test`).

Don't forget the GitHub Environment **variable** (not secret)
`STAGING_URL` for the smoke target.

---

## 5. Read MSR logs

### 5a. Docker host (dev / test default)

`config/dev/deploy.yaml` has `target.kind: docker-ssh`; the container
name is `wm-svc-<env>` (see `container.name`).

```sh
# Live tail (last 200 lines + follow).
ssh ${TARGET_USER}@${TARGET_HOST} \
   docker logs --tail 200 -f wm-svc-dev

# Just the IS server.log -- lives inside the instance directory.
ssh ${TARGET_USER}@${TARGET_HOST} \
   docker exec wm-svc-dev tail -f /opt/softwareag/IntegrationServer/instances/default/logs/server.log

# Audit log (transactions, ACL hits, etc.)
ssh ${TARGET_USER}@${TARGET_HOST} \
   docker exec wm-svc-dev tail -200 \
       /opt/softwareag/IntegrationServer/instances/default/logs/audit/AuditLog.log

# Inspect the renamed -prev container after a failed deploy.
ssh ${TARGET_USER}@${TARGET_HOST} docker ps -a | grep wm-svc-dev
ssh ${TARGET_USER}@${TARGET_HOST} docker logs wm-svc-dev-prev | tail -200
```

### 5b. Kubernetes (prod default)

`config/prod/deploy.yaml` has `target.kind: kubernetes-helm`; the
namespace is `wm-svc-prod`.

```sh
# Decode the kubeconfig out of the vault into a local file first:
gh secret get TARGET_KUBECONFIG_B64 --env prod | base64 -d > /tmp/kc
export KUBECONFIG=/tmp/kc

NS=wm-svc-prod
SEL='app.kubernetes.io/instance=wm-svc-prod'

# Aggregate live tail across all replicas.
kubectl logs -n $NS -l $SEL --tail=200 -f --max-log-requests=10

# Single pod, IS server.log.
POD=$(kubectl get pod -n $NS -l $SEL -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n $NS "$POD" -- tail -f \
   /opt/softwareag/IntegrationServer/instances/default/logs/server.log

# Previous container after a crash-loop.
kubectl logs -n $NS "$POD" --previous --tail=500

# Events for the namespace -- catches OOMKills, image pull errors, etc.
kubectl get events -n $NS --sort-by=.lastTimestamp | tail -30

# Helm release history -- shows `superseded` / `rolled back` for
# atomic-rollback runs.
helm history wm-svc-prod -n $NS
```

### 5c. From inside the container (any backend)

When you've already exec'd into a pod / container:

```sh
# All IS log files at a glance.
ls -lt /opt/softwareag/IntegrationServer/instances/default/logs/

# wm-mcp can pull live state without grep:
wm-mcp server_status
wm-mcp package_list
wm-mcp jdbc_pool_list --output json | jq '.[] | {alias, state, available}'
```

---

## 6. Quick reference

### Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| [`base-image.yml`](../.github/workflows/base-image.yml) | push `docker/base/**` or `versions.env`; weekly Mon 03:00 | Build/push/sign `wm-msr-base` |
| [`ci.yml`](../.github/workflows/ci.yml) | PR + push:main | Build/test/scan service image |
| [`cd.yml`](../.github/workflows/cd.yml) | push:main; `release:published`; manual | Promote dev → test → prod |
| [`rollback.yml`](../.github/workflows/rollback.yml) | manual only | `gh workflow run rollback.yml -f env=<env> -f to_sha=<sha>` |
| [`security.yml`](../.github/workflows/security.yml) | PR + weekly | gitleaks + trivy fs |
| [`image-security.yml`](../.github/workflows/image-security.yml) | PR + push:main + weekly | trivy image + cosign verify/sign + SBOM |
| [`policy.yml`](../.github/workflows/policy.yml) | PR + push:main | size / naming / ACL / manifest / extended-settings gates |

### Scripts

| Script | What it does |
|--------|--------------|
| [`scripts/deploy/dispatch.sh`](../scripts/deploy/dispatch.sh) | Reads `target.kind` and execs the right backend |
| [`scripts/deploy/docker-ssh.sh`](../scripts/deploy/docker-ssh.sh) | Docker host backend — blue/green container swap |
| [`scripts/deploy/k8s-helm.sh`](../scripts/deploy/k8s-helm.sh) | Kubernetes backend — `helm upgrade --atomic --wait` |
| [`scripts/deploy/rollback.sh`](../scripts/deploy/rollback.sh) | Lookup-or-explicit rollback driver |
| [`scripts/deploy/record-deployment.sh`](../scripts/deploy/record-deployment.sh) | POSTs the deployment record that rollback queries |
| [`scripts/deploy/db-snapshot.sh`](../scripts/deploy/db-snapshot.sh) | Pre-prod-deploy schema snapshot via `wm-mcp jdbc_pool_export_schema` |
| [`scripts/apply-config.sh`](../scripts/apply-config.sh) | Merges base + env overlays, drives `wm-mcp` upserts |
| [`scripts/setup-environments.sh`](../scripts/setup-environments.sh) | Idempotent GitHub Environment / secret bootstrap |
| [`scripts/setup/branch-protection.sh`](../scripts/setup/branch-protection.sh) | Idempotent `main`-branch protection bootstrap |

### Config files (per env)

| File | Required | What lives here |
|------|----------|-----------------|
| `config/<env>/deploy.yaml` | yes | `target.kind`, container/namespace name, smoke endpoint |
| `config/<env>/runtime.env.tmpl` | docker-ssh only | `${NAME}` placeholders rendered into the container env-file |
| `config/<env>/global-variables.yaml` | optional | GV overrides |
| `config/<env>/jdbc-pools.yaml` | optional | JDBC pool overlays |
| `config/<env>/jms-aliases.yaml` | optional | JMS alias overlays |
| `config/<env>/kafka-connections.yaml` | optional | Kafka connection overlays |
| `config/<env>/mqtt-connections.yaml` | optional | MQTT connection overlays |
| `helm/wm-microservice/values-<env>.yaml` | k8s-helm only | replicas/resources/probes per env |

See [`docs/config-merge.md`](config-merge.md) for the precedence
rules and identity fields used by list-merge.

### Other docs you'll need on a bad day

- [`docs/troubleshooting.md`](troubleshooting.md) — failure modes (start here for "X is broken")
- [`docs/secrets.md`](secrets.md) — canonical secret matrix
- [`docs/branch-protection.md`](branch-protection.md) — `main` protection rules
- [`docs/security-gates.md`](security-gates.md) — gitleaks/trivy/cosign acceptance tests
- [`docs/observability/README.md`](observability/README.md) — Prometheus + Grafana scrape paths
- [`docs/authoring-tests.md`](authoring-tests.md) — UTF / WM Test Suite authoring

---

## 7. Sign-off

This runbook is owned by the platform team
(see [`CODEOWNERS`](../CODEOWNERS)). Material changes require a PR
and platform-team approval. Please update it whenever you discover
a step missing from §0 — the next on-call will thank you.
