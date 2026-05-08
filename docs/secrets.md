# GitHub Environments and Secrets

This document is the **single source of truth** for which secrets every
deploy environment needs and how they are named. **Names only — never
values.** When onboarding a new environment, this page is the checklist:
every row in the matrix has to exist in that environment's GitHub
Secrets before the pipeline can deploy there.

If you add a new JDBC pool / Kafka connection / MQTT broker / JMS alias
/ user / secret-bearing global variable to `config/base/`, you **must**
update this document in the same PR. CI does not (yet) cross-check this
list against `config/base/`, so reviewer discipline is the gate.

## Environments

The pipeline targets three GitHub Environments, one per stage:

| Environment | Purpose                              | Protection rules                                              |
| ----------- | ------------------------------------ | ------------------------------------------------------------- |
| `dev`       | Continuous deployment from `main`    | None — auto-deploy on green build.                            |
| `test`      | Pre-prod validation / smoke tests    | None — same trust as `dev` but distinct credentials/targets.  |
| `prod`      | Production                           | **Required reviewers ≥ 1**, **wait timer = 10 minutes**, branch policy: only `main`. |

`prod` protections are enforced by the GitHub Environment, not by the
workflow YAML. A workflow run that targets `prod` is paused at the
`environment: prod` job boundary until a reviewer approves; the wait
timer starts after approval. **Do not** approximate this with `if:`
guards in YAML — the gate must be auditable in the Environment settings
UI.

The bootstrap script `scripts/setup-environments.sh` creates the three
environments and applies the `prod` protection rules idempotently. See
[Bootstrap procedure](#bootstrap-procedure) below.

## Two kinds of secrets in this project

The pipeline distinguishes two flows. Both are documented here so
nothing slips through.

1. **Apply-time placeholders — `${SECRET:NAME}`.** `apply-config.sh`
   substitutes these against process env vars (populated from GitHub
   Secrets) before calling `wm-mcp`. See `scripts/lib/secret-resolver.sh`.
   These are the rows in the [Per-environment secret matrix](#per-environment-secret-matrix)
   below.

2. **Opaque secret references — `*_secret_ref: <uri>`.** Strings like
   `vault://kv/data/wm/<service>/db/orders/password` are passed through
   to `wm-mcp` verbatim. The runtime resolves them through its own
   backend (Vault, k8s Secret, …). They are **not** GitHub Secrets and
   do not appear in the matrix below — but the bootstrap credentials
   that let `wm-mcp` reach Vault (`VAULT_ADDR`, `VAULT_ROLE_ID`,
   `VAULT_SECRET_ID`) **are** GitHub Secrets and **are** in the matrix.

If a deployment uses GitHub Secrets directly (no Vault), every
`*_secret_ref` entry in `config/base/*.yaml` must have a paired
`${SECRET:NAME}` overlay in `config/<env>/*.yaml` and a matching row in
the matrix. The naming convention in
[Naming convention](#naming-convention) tells you what the GitHub
Secret name has to be.

## Per-environment secret matrix

Every row below is required in **each** of `dev`, `test`, `prod` unless
explicitly noted. The values differ per environment (that's the whole
point of having three Environments); the **names** are identical so the
same workflow YAML works against any of the three.

### MSR admin / pipeline credentials

| GitHub Secret name        | Used by                          | Notes                                                |
| ------------------------- | -------------------------------- | ---------------------------------------------------- |
| `MSR_ADMIN_USER`          | `apply-config.sh --user`         | Local IS administrator account name.                 |
| `MSR_ADMIN_PASSWORD`      | `apply-config.sh --password`     | Local IS administrator password.                     |
| `TARGET_HOST`             | deploy job                       | Hostname / DNS of the MSR (or ingress) for this env. |
| `TARGET_KUBECONFIG_B64`   | deploy job                       | Base64-encoded kubeconfig scoped to the target ns.   |
| `REGISTRY_USER`           | image pull from base/service     | Same value as repo-level secret if present.          |
| `REGISTRY_TOKEN`          | image pull from base/service     | Token with `read:packages` for ghcr.io.              |

> **Note.** `REGISTRY_USER` / `REGISTRY_TOKEN` already exist as
> repo-level secrets for `.github/workflows/base-image.yml` (Task 1.2).

### IBM webMethods Container Registry (source of MSR FROM image)

These are **repo-level** secrets (not per-environment), required by
`base-image.yml` and the `unit-tests` job in `ci.yml` to authenticate
to `ibmwebmethods.azurecr.io` for pulling the MSR base image.

| GitHub Secret name      | Used by                                            | Notes                                                                                              |
| ----------------------- | -------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `IBMWM_REGISTRY_USER`   | `base-image.yml`, `ci.yml/unit-tests` Docker login | Registry token **name** minted at https://containers.webmethods.io after IBMid (w3id SSO) sign-in. |
| `IBMWM_REGISTRY_TOKEN`  | `base-image.yml`, `ci.yml/unit-tests` Docker login | Matching token **password**. The portal does not show this again — store it on first mint.        |

> **Mint procedure.** Sign in at https://containers.webmethods.io with
> your IBMid (w3id SSO for IBM employees), follow the prompt to
> generate a registry token, copy both the name and the password, and
> set them as repo-level secrets in
> **Settings → Secrets and variables → Actions**. Both `base-image.yml`
> and `ci.yml/unit-tests` will 401 at the FROM line without these.
> They are duplicated into each Environment so per-env scoping is
> possible later (e.g. a separate prod registry account) without a
> workflow change.

### Vault bootstrap (only when `*_secret_ref: vault://...` is used)

| GitHub Secret name        | Used by                          | Notes                                                |
| ------------------------- | -------------------------------- | ---------------------------------------------------- |
| `VAULT_ADDR`              | `wm-mcp` Vault resolver          | e.g. `https://vault.<env>.example.com`.              |
| `VAULT_ROLE_ID`           | AppRole login                    | Per-env role.                                        |
| `VAULT_SECRET_ID`         | AppRole login                    | Per-env secret ID; rotate on a schedule.             |

If your deployment does **not** use Vault (i.e. every `*_secret_ref` has
been replaced by a `${SECRET:…}` overlay), omit these three.

### JDBC pool passwords

One `DB_PASSWORD_<ALIAS>` per entry in `config/base/jdbc-pools.yaml`
under `pools[].alias`. `<ALIAS>` is the pool alias upper-snake-cased
(`ordersDb` → `ORDERS_DB`).

| GitHub Secret name      | Pool alias  | Source field                              |
| ----------------------- | ----------- | ----------------------------------------- |
| `DB_PASSWORD_ORDERS_DB` | `ordersDb`  | `pools[0].password_secret_ref`            |
| `DB_PASSWORD_AUDIT_DB`  | `auditDb`   | `pools[1].password_secret_ref`            |

### Kafka credentials

One `KAFKA_SASL_PASSWORD_<ALIAS>` per `connections[].alias`. Truststore
material (PEM/JKS, base64-encoded) goes in
`KAFKA_SSL_TRUSTSTORE_<ALIAS>` and is only required when
`security_protocol` includes `SSL`.

| GitHub Secret name                  | Connection alias | Source field                                    |
| ----------------------------------- | ---------------- | ----------------------------------------------- |
| `KAFKA_SASL_PASSWORD_EVENTS_CLUSTER`| `eventsCluster`  | `connections[0].sasl_password_secret_ref`       |
| `KAFKA_SSL_TRUSTSTORE_EVENTS_CLUSTER` | `eventsCluster` | `connections[0].ssl_truststore_secret_ref`     |

### MQTT credentials

| GitHub Secret name              | Connection alias | Source field                                |
| ------------------------------- | ---------------- | ------------------------------------------- |
| `MQTT_PASSWORD_IOT_INGEST`      | `iotIngest`      | `connections[0].password_secret_ref`        |
| `MQTT_SSL_TRUSTSTORE_IOT_INGEST`| `iotIngest`      | `connections[0].ssl_truststore_secret_ref`  |

### JMS alias passwords

One `JMS_PASSWORD_<ALIAS>` per `aliases[].alias`.

| GitHub Secret name        | JMS alias    | Source field                          |
| ------------------------- | ------------ | ------------------------------------- |
| `JMS_PASSWORD_UM_DEFAULT` | `umDefault`  | `aliases[0].password_secret_ref`      |
| `JMS_PASSWORD_LEGACY_MQ`  | `legacyMq`   | `aliases[1].password_secret_ref`      |

### Service account user passwords

One `USER_PASSWORD_<USERNAME>` per `users[].username`. Hyphens in the
username become underscores; the rest is upper-snake-cased
(`wm-deploy-bot` → `WM_DEPLOY_BOT`).

| GitHub Secret name           | Username        | Source field                       |
| ---------------------------- | --------------- | ---------------------------------- |
| `USER_PASSWORD_WM_DEPLOY_BOT`| `wm-deploy-bot` | `users[0].password_secret_ref`     |
| `USER_PASSWORD_WM_OPS_BOT`   | `wm-ops-bot`    | `users[1].password_secret_ref`     |

### Secret-bearing global variables

Every `variables[]` entry in `config/base/global-variables.yaml` with
`secret: true` gets a `GV_<KEY>` secret. `<KEY>` is taken verbatim
(it's already SCREAMING_SNAKE_CASE per the schema).

| GitHub Secret name | Variable key | Source field                  |
| ------------------ | ------------ | ----------------------------- |
| `GV_API_TOKEN`     | `API_TOKEN`  | `variables[].secret_ref`      |

## Naming convention

Future entries follow the same pattern. Add them to
`config/base/`, then add a row here in the same PR.

| Source                                                | GitHub Secret name pattern              |
| ----------------------------------------------------- | --------------------------------------- |
| `jdbc-pools.yaml` `pools[].password_secret_ref`       | `DB_PASSWORD_<ALIAS>`                   |
| `kafka-connections.yaml` `…sasl_password_secret_ref`  | `KAFKA_SASL_PASSWORD_<ALIAS>`           |
| `kafka-connections.yaml` `…ssl_truststore_secret_ref` | `KAFKA_SSL_TRUSTSTORE_<ALIAS>`          |
| `mqtt-connections.yaml` `…password_secret_ref`        | `MQTT_PASSWORD_<ALIAS>`                 |
| `mqtt-connections.yaml` `…ssl_truststore_secret_ref`  | `MQTT_SSL_TRUSTSTORE_<ALIAS>`           |
| `jms-aliases.yaml` `aliases[].password_secret_ref`    | `JMS_PASSWORD_<ALIAS>`                  |
| `users-and-groups.yaml` `users[].password_secret_ref` | `USER_PASSWORD_<USERNAME>`              |
| `global-variables.yaml` `variables[].secret_ref`      | `GV_<KEY>`                              |

`<ALIAS>` / `<USERNAME>` transformation rule:

* lower-case → upper-case
* `camelCase` → `CAMEL_CASE` (boundary insert before each capital)
* `kebab-case` → `KEBAB_CASE` (`-` → `_`)
* `snake_case` → `SNAKE_CASE` (already conformant; only upper-case)

Examples: `ordersDb` → `ORDERS_DB`, `wm-deploy-bot` → `WM_DEPLOY_BOT`,
`already_snake` → `ALREADY_SNAKE`. The bootstrap script uses the same
rule, so it's the source of truth if a corner case is ever ambiguous.

## Bootstrap procedure

This repository ships `scripts/setup-environments.sh` to create the
three Environments and configure `prod` protection rules idempotently.
It is **not** run by CI — it is run **once** by an operator with
`gh auth login` of someone holding `Manage` permission on the repo,
typically when the repo is first connected to GitHub or when a new env
is added.

```bash
# Required tools: gh (>= 2.x), jq.
# Required GH auth: classic PAT with `repo` scope OR `gh auth login`
# under an account that has Manage on the repo.

# Dry-run first (default): prints the planned changes, mutates nothing.
./scripts/setup-environments.sh

# Apply: creates dev/test/prod and sets prod gate.
./scripts/setup-environments.sh --apply

# Override prod reviewer (default: read REPO_OWNER from `gh repo view`).
./scripts/setup-environments.sh --apply \
    --prod-reviewer-user octocat \
    --prod-reviewer-team my-org/release-managers \
    --prod-wait-minutes 30
```

After the environments exist, set the secrets per environment. The
script does **not** set secret *values* — that's a manual step so
secrets never pass through any local checkout:

```bash
gh secret set MSR_ADMIN_PASSWORD --env dev --body "$(read -s; echo "$REPLY")"
# … repeat per row in the matrix …
```

For convenience, `scripts/setup-environments.sh --check` lists which
secrets in the matrix are **missing** in each environment (using
`gh api /repos/:owner/:repo/environments/<env>/secrets`, which returns
names only). Run it after seeding:

```bash
./scripts/setup-environments.sh --check
# dev   : missing MQTT_SSL_TRUSTSTORE_IOT_INGEST
# test  : ok
# prod  : missing TARGET_KUBECONFIG_B64, GV_API_TOKEN
```

## Onboarding a new environment

When you add `config/<newenv>/`:

1. Add a new row to the [Environments table](#environments) above with
   protection rules appropriate for the new tier.
2. Append the env name to `ENVIRONMENTS` in
   `scripts/setup-environments.sh`.
3. Run `./scripts/setup-environments.sh --apply` to create the
   Environment in GitHub.
4. Walk every section of the
   [Per-environment secret matrix](#per-environment-secret-matrix)
   and `gh secret set ... --env <newenv> ...` each one.
5. Run `./scripts/setup-environments.sh --check` to confirm none are
   missing.
6. Update the deploy workflow's `environment:` matrix to include the
   new env (if the workflow uses one).

## Onboarding a new secret-bearing config entry

When you add (e.g.) a new JDBC pool to `config/base/jdbc-pools.yaml`:

1. Add the entry, with `password_secret_ref` set to a `vault://...` URI
   if you're on Vault, or with the password field overlaid to
   `${SECRET:DB_PASSWORD_<ALIAS>}` in each `config/<env>/jdbc-pools.yaml`
   if you're not.
2. Add a new row to the matching subsection of
   [Per-environment secret matrix](#per-environment-secret-matrix).
3. Set the new secret in **every** environment:
   `gh secret set DB_PASSWORD_<ALIAS> --env dev`,
   `--env test`, `--env prod`.
4. `./scripts/setup-environments.sh --check` should now pass.

## Acceptance criteria reference

For Task 3.3 of the wm-microservice-cicd-pipeline plan, the acceptance
criteria are:

* `gh api /repos/:owner/:repo/environments` returns `dev`, `test`,
  `prod` — verified by `setup-environments.sh --apply` (which is
  idempotent) and re-checkable with `setup-environments.sh --list`.
* `prod` environment has at least one required reviewer — set by
  `setup-environments.sh --apply` from `--prod-reviewer-user` /
  `--prod-reviewer-team` (one or both must be supplied for `--apply`
  to succeed against `prod`).
* Pipeline dry-run against `dev` succeeds without prompts — the deploy
  workflow's `environment: dev` step has no required reviewers, so
  `apply-config.sh --env dev --dry-run` runs unattended once secrets
  are seeded per the matrix.
