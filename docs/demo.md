# End-to-End Demo & Sign-Off

This document walks through the **pipeline acceptance test** for the
webMethods Microservice CI/CD pipeline: a single PR adds the
[`HelloWorld`](../packages/HelloWorld/) sample package, goes from open
→ green CI → merged → auto-dev-deploy → manual-test-promote →
manual-prod-promote, with each env's deployed `hello.world:greet`
service returning a greeting that mentions that env's name.

> If everything below is green, the pipeline ships. If anything below
> is red, the pipeline is the bug — the demo PR is the canary.

---

## TL;DR

| Stage | Trigger | Expected outcome |
|-------|---------|------------------|
| Open PR `feat(packages): add HelloWorld demo` | GitHub UI | `ci.yml` runs the 8 jobs; **gate** turns green within ~12 min |
| Merge to `main` | UI "Merge pull request" | `cd.yml` auto-deploys to **dev**, smoke green, response says `(env: dev)` |
| `gh workflow run cd.yml -f target_env=test` | Operator | Reviewer approves; deploy to **test**, smoke green, response says `(env: test)` |
| `gh workflow run cd.yml -f target_env=prod` | Operator | Reviewer approves; 10-min wait timer; deploy to **prod**, smoke green, response says `(env: prod)` |

Total wall-clock from PR open → prod green: roughly **45 minutes**,
most of which is the prod 10-minute wait timer plus the parallel CI
jobs.

---

## What the demo package does

`hello.world:greet` reads the `ENV_NAME` global variable, and returns:

```json
{
  "greeting": "Hello, ${name}! (env: ${ENV_NAME})",
  "envName":  "${ENV_NAME}"
}
```

The variable is set per environment in
[`config/<env>/global-variables.yaml`](../config/):

| env  | `ENV_NAME` value |
|------|------------------|
| base | `unknown`        |
| dev  | `dev`            |
| test | `test`           |
| prod | `prod`           |

The smoke test asserts the deployed service returns the expected
env tag — that is the assertion that proves promotion worked.

---

## 1. Open the PR

```sh
git checkout -b feat/helloworld-demo
git add packages/HelloWorld tests/unit/HelloWorldTest \
        tests/integration/postman/HelloWorld.json \
        tests/integration/smoke/HelloWorld.smoke.sh \
        config/base/global-variables.yaml \
        config/dev/global-variables.yaml \
        config/test/global-variables.yaml \
        config/prod/global-variables.yaml \
        docs/demo.md
git commit -m "feat(packages): add HelloWorld demo and sign-off"
git push -u origin feat/helloworld-demo
gh pr create --fill
```

[`ci.yml`](../.github/workflows/ci.yml) fires on `pull_request` and
runs the 8-job graph documented in the file header. The PR sees one
required check, **gate**, plus inline JUnit reports from
`dorny/test-reporter` for each report-emitting job (lint, unit,
integration, contracts, security). All 8 must succeed (or skip) for
gate to go green.

### What runs

| Job                | What it covers                                                                  |
|--------------------|--------------------------------------------------------------------------------|
| `setup`            | Computes the package matrix; pins `MSR_VERSION`; emits the PR-scoped image tag |
| `lint-packages`    | `wm-mcp` package_dependency_check + namespace_unused_services + flow_validate + acl_audit |
| `build-image`      | `docker/service/Dockerfile` — bakes `dist/HelloWorld-1.0.0.zip` into the image |
| `unit-tests`       | UTF runner; `HappyPath.wmTestCase` + `EmptyName.wmTestCase` (both pass)        |
| `integration-tests`| Postman + k6 + REST-assured against the `compose.yml` sidecar stack            |
| `contract-tests`   | OpenAPI/WSDL diffs against the previous main                                    |
| `security`         | gitleaks + trivy fs + 4 of 5 Phase-5.3 policy gates (size/naming/ACL/manifests)|
| `gate`             | Aggregates `needs.*.result` — single required check on `main`                  |

### Capture for the demo

- Screenshot of the PR Checks tab with all 8 jobs green.
- Screenshot of one of the inline test-reporter sections expanding to
  show the two HelloWorld unit cases.
- Save the PR URL — it is the audit-trail entry pointed at by the
  deployment records.

> **Loom suggestion:** record from "PR opened" through gate-green; ~5
> minutes of footage with cuts to the slowest few jobs.

---

## 2. Merge

```sh
gh pr merge --squash --delete-branch
```

The squash commit on `main` triggers `cd.yml` (event:
`push: main`). `cd.yml`'s `select-image` job resolves the new commit
SHA to the PR-quality service image tag
`ghcr.io/<owner>/wm-svc:main-<sha7>-<sha>` published by `ci.yml`'s
`build-image`.

---

## 3. Auto-deploy to dev

`cd.yml` proceeds through:

1. `select-image` — picks the `main-<sha7>-<sha>` tag.
2. `deploy-dev` — runs in the GitHub `dev` environment (audit boundary
   only, no required reviewer). Calls
   [`scripts/deploy/dispatch.sh`](../scripts/deploy/dispatch.sh) which
   reads `config/dev/deploy.yaml` (`target.kind: docker-ssh`) and
   delegates to
   [`scripts/deploy/docker-ssh.sh`](../scripts/deploy/docker-ssh.sh).
   The container blue/greens — old `wm-svc-dev` becomes
   `wm-svc-dev-prev`, new one takes the canonical name; on success
   the prev is removed; on failure both stay around for forensics.
3. `apply-config.sh --env dev --container wm-svc-dev` runs through
   `docker exec`, sets `ENV_NAME=dev` (alongside the rest of the dev
   overlay).
4. `record-deployment.sh dev <sha> <image_ref>` POSTs an audit
   record so `rollback.sh` can find it later.
5. `smoke-dev` runs **two** smoke runners against `${{ vars.DEV_URL }}`:
   - `tests/integration/smoke/run.sh` — canonical `wm.server:ping`
     + `getServerVersion` checks.
   - `tests/integration/smoke/HelloWorld.smoke.sh` —
     `EXPECTED_ENV_NAME=dev`. POSTs to `/invoke/hello.world:greet`
     and asserts the response contains `(env: dev)`.

### Verify by hand

```sh
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"name": "Cyril"}' \
  "$(gh variable get DEV_URL)/invoke/hello.world:greet" | jq .
```

Expected:

```json
{
  "greeting": "Hello, Cyril! (env: dev)",
  "envName":  "dev"
}
```

### Capture for the demo

- Screenshot of the `cd` workflow run with `deploy-dev` + `smoke-dev`
  green.
- Terminal screenshot of the manual `curl` returning `(env: dev)`.
- Grafana panel: `sag_is_flow_invocations_total{service="hello.world:greet"}`
  ticking up after the curl.

---

## 4. Manual promote to test

```sh
gh workflow run cd.yml -f target_env=test
```

The `test` GitHub environment requires a reviewer (configured by
[`scripts/setup-environments.sh`](../scripts/setup-environments.sh) in
Phase 3.3). The workflow blocks at `deploy-test` until a reviewer
approves through the GitHub UI. Approval flow:

1. Reviewer clicks **Review pending deployments** on the workflow run.
2. Selects `test`, optionally adds a comment, clicks **Approve and
   deploy**.
3. `deploy-test` proceeds through the same 5 steps as `deploy-dev`,
   but against `config/test/`.
4. `smoke-test` runs `HelloWorld.smoke.sh` with `EXPECTED_ENV_NAME=test`.

### Verify by hand

```sh
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"name": "Cyril"}' \
  "$(gh variable get TEST_URL)/invoke/hello.world:greet" | jq .
```

Expected:

```json
{
  "greeting": "Hello, Cyril! (env: test)",
  "envName":  "test"
}
```

### Capture for the demo

- Screenshot of the **Review pending deployments** modal.
- Screenshot of the workflow run with the test env gate cleared and
  `smoke-test` green.
- Terminal screenshot of the manual `curl` returning `(env: test)`.

---

## 5. Manual promote to prod

```sh
gh workflow run cd.yml -f target_env=prod
```

The `prod` environment carries the heaviest gates:

- **Required reviewer** (different from the test reviewer if your
  policy enforces separation of duties).
- **10-minute wait timer** — even after approval, the workflow holds
  for 10 minutes before running. This is deliberate; it gives the
  reviewer a chance to abort if they noticed something during the
  approval click.
- **Branch policy: `main` only** — workflows from feature branches
  cannot reach prod, period.

The `deploy-prod` job adds two additional steps before the rollout:

1. **Tooling install** — Helm + kubectl (prod uses
   `target.kind: kubernetes-helm`).
2. **Pre-deploy DB snapshot** — runs
   [`scripts/deploy/db-snapshot.sh`](../scripts/deploy/db-snapshot.sh)
   inside one of the live prod pods to capture pre-rollout schema
   state, uploaded as the `db-snapshot-<sha>` artifact (90-day
   retention, for emergency forensics).

After approval clears and the wait timer elapses:

3. `deploy-prod` calls
   [`scripts/deploy/k8s-helm.sh`](../scripts/deploy/k8s-helm.sh) which
   does `helm upgrade --install --wait --atomic --timeout 5m` against
   the prod cluster, then port-forwards to the new pod and runs
   `apply-config.sh --target http://localhost:<port>`.
4. `record-deployment.sh prod <sha> <image_ref>` POSTs the audit
   record.
5. `smoke-prod` runs `HelloWorld.smoke.sh` with `EXPECTED_ENV_NAME=prod`.

### Verify by hand

```sh
curl -s -X POST -H "Content-Type: application/json" \
  -d '{"name": "Cyril"}' \
  "$(gh variable get PROD_URL)/invoke/hello.world:greet" | jq .
```

Expected:

```json
{
  "greeting": "Hello, Cyril! (env: prod)",
  "envName":  "prod"
}
```

### Capture for the demo

- Screenshot of the prod approval modal showing the 10-min timer.
- Screenshot of the workflow run after `smoke-prod` is green.
- Terminal screenshot of the manual `curl` returning `(env: prod)`.
- Screenshot of the [`docs/observability/dashboard.json`](observability/README.md)
  Grafana panel showing prod traffic landing on the new image.

---

## 6. The proof

The acceptance criterion is simple and provable from a terminal:

```sh
for env in dev test prod; do
    case "${env}" in
        dev)  url=$(gh variable get DEV_URL)  ;;
        test) url=$(gh variable get TEST_URL) ;;
        prod) url=$(gh variable get PROD_URL) ;;
    esac
    body=$(curl -s -X POST -H "Content-Type: application/json" \
                 -d '{"name": "demo"}' \
                 "${url}/invoke/hello.world:greet")
    printf '%s -> %s\n' "${env}" "${body}"
done
```

Expected (one per env):

```
dev  -> {"greeting":"Hello, demo! (env: dev)","envName":"dev"}
test -> {"greeting":"Hello, demo! (env: test)","envName":"test"}
prod -> {"greeting":"Hello, demo! (env: prod)","envName":"prod"}
```

Three different env tags from three different MSR instances, one
shared service binary — that is the pipeline working end-to-end.

---

## Loom outline

If you record one demo Loom, follow this beat sheet (~10 minutes):

1. **00:00 — Intro** (15s). "Single PR through CI/CD, dev → test →
   prod. Each env's response carries its own env tag."
2. **00:15 — Show the package** (60s). `tree packages/HelloWorld`,
   read the manifest, walk through `flow.xml` highlighting the GV
   lookup + greeting concat.
3. **01:15 — Open PR + watch CI** (90s). Skip ahead to gate green.
4. **02:45 — Merge + auto-dev-deploy** (90s). Watch `cd.yml` run
   `select-image` → `deploy-dev` → `smoke-dev`. Curl `dev` URL.
5. **04:15 — Promote to test** (90s). Show the `Review pending
   deployments` UI, approve, watch deploy + smoke. Curl `test`.
6. **05:45 — Promote to prod** (3m). Show the 10-minute wait timer
   tick down (cut after 30s, fast-forward through the rest). Watch
   `deploy-prod` + `smoke-prod`. Curl `prod`. Three env tags side by
   side as the closing shot.
7. **08:45 — Ops view** (60s). Open the Grafana dashboard from
   [`docs/observability/dashboard.json`](observability/README.md) and
   point at the `sag_is_flow_invocations_total` and JVM panels.
8. **09:45 — Outro** (15s). "End-to-end pipeline acceptance: green."

---

## Sign-off checklist

- [ ] PR `feat(packages): add HelloWorld demo` opened, gate green.
- [ ] PR merged; `cd.yml` ran on `main`.
- [ ] `deploy-dev` + `smoke-dev` green; manual curl returns `(env: dev)`.
- [ ] `deploy-test` + `smoke-test` green; manual curl returns `(env: test)`.
- [ ] `deploy-prod` + `smoke-prod` green; manual curl returns `(env: prod)`.
- [ ] Grafana shows traffic landing on the new image.
- [ ] Demo screenshots captured and linked from this doc (or a Loom URL pasted below).

> Loom: _paste URL once recorded_  
> Screenshots: _link to the artifact bundle once captured_
