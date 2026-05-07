# Configuration layout and merge rule

This document describes how runtime configuration for the webMethods MSR
microservice is laid out on disk and how the per-environment overlay is
merged on top of the shared base at deploy time.

## Folder layout

```
config/
  base/                          # union of every key the service supports
    global-variables.yaml
    jdbc-pools.yaml
    jms-aliases.yaml
    kafka-connections.yaml
    mqtt-connections.yaml
    ports.yaml
    acls.yaml
    extended-settings.properties
    users-and-groups.yaml

  dev/                           # sparse overlay - dev environment
    global-variables.yaml        # only the variables that differ from base
  test/                          # sparse overlay - test environment
  prod/                          # sparse overlay - prod environment
```

`config/base/` is the **single source of truth** for the full set of keys
the service expects. `config/<env>/` is a **sparse overlay**: it lists
**only** the entries that differ from base for that environment. An empty
overlay file is legal and means "use base verbatim".

Every YAML file is validated against `schemas/config.schema.json` by
`scripts/validate-config.sh`. Top-level keys not declared in the matching
sub-schema cause CI to fail.

## Merge rule (high-level)

For each `config/<env>/<file>.yaml`:

1. Load `config/base/<file>.yaml` as the **base document**.
2. If `config/<env>/<file>.yaml` exists, load it as the **overlay**.
3. Merge overlay into base using the rules below.
4. Resolve any `secret_ref` / `password_secret_ref` / `*_secret_ref` fields
   against the active secret backend (Vault / GitHub Secrets / Kubernetes
   Secret) to produce the final apply-time document.

**Overlay always wins on collision.** The base document is never mutated
in place; a new merged document is produced for the apply step.

## Merging scalars and maps

* For top-level scalar fields, overlay replaces base.
* For nested maps (objects), the merge is a **recursive deep-merge** keyed
  by map key. Keys present only in base are preserved; keys present in
  overlay replace the base value (recursively for nested objects).
* `null` in overlay explicitly removes the corresponding base key.
  (Use sparingly - prefer omitting the key.)

## Merging lists - identity-keyed merge

Most config files store their payload as a list of objects. Lists are
**not** concatenated blindly; doing so would silently duplicate aliases
or ports across env layers. Instead each list type has a designated
**identity field**, and the merge rule is:

* Entry in overlay whose identity matches an entry in base **replaces**
  that base entry.
* Entry in overlay whose identity does **not** match any base entry is
  **appended**.
* Entry in base with no overlay match is **kept**.

Identity fields by file:

| File                        | List path        | Identity field        |
| --------------------------- | ---------------- | --------------------- |
| `global-variables.yaml`     | `variables[]`    | `key`                 |
| `jdbc-pools.yaml`           | `pools[]`        | `alias`               |
| `jms-aliases.yaml`          | `aliases[]`      | `alias`               |
| `kafka-connections.yaml`    | `connections[]`  | `alias`               |
| `mqtt-connections.yaml`     | `connections[]`  | `alias`               |
| `ports.yaml`                | `ports[]`        | `name`                |
| `acls.yaml`                 | `acls[]`         | `name`                |
| `users-and-groups.yaml`     | `users[]`        | `username`            |
| `users-and-groups.yaml`     | `groups[]`       | `name`                |

A merged list entry is itself produced by deep-merging the overlay entry
into the matched base entry (per "Merging scalars and maps" above), so an
overlay can override a single field of an existing entry without
re-stating the rest.

### Example

`config/base/global-variables.yaml`:

```yaml
variables:
  - key: LOG_LEVEL
    value: INFO
  - key: HTTP_TIMEOUT_MS
    value: 30000
```

`config/dev/global-variables.yaml`:

```yaml
variables:
  - key: LOG_LEVEL          # matches base by key -> replaces value
    value: DEBUG
  - key: DEV_FEATURE_FLAGS  # no match in base    -> appended
    value: "experimental.retry"
```

Resulting effective config for `dev`:

```yaml
variables:
  - key: LOG_LEVEL
    value: DEBUG
  - key: HTTP_TIMEOUT_MS
    value: 30000
  - key: DEV_FEATURE_FLAGS
    value: "experimental.retry"
```

## Merging `extended-settings.properties`

`extended-settings.properties` is **not** YAML and is **not** validated
against the JSON schema. Merge is performed as a flat key=value overlay:

1. Read every `key=value` line from `config/base/extended-settings.properties`.
2. Read every `key=value` line from `config/<env>/extended-settings.properties`
   (if the file exists).
3. Later assignments win on key collision; new keys are appended.
4. Comments (`#` or `!` prefix) and blank lines are preserved from base
   only - overlay comments are dropped during merge.

This matches the semantics of Java `java.util.Properties` chained loading.

## Secrets

Plain `value:` fields are stored in plain text in git. Anything sensitive
must use a `secret_ref` form:

```yaml
- key: API_TOKEN
  secret: true
  secret_ref: vault://kv/data/wm/<service>/api_token
```

For pool/JMS/Kafka/MQTT/users/groups, the dedicated field name is
`password_secret_ref` (or `sasl_password_secret_ref`,
`ssl_truststore_secret_ref`, etc.). The schema enforces these naming
conventions.

The merge step does **not** resolve secrets - resolution happens later in
the apply step, by the deploy tool, using the active backend. Merge tools
should treat `*_secret_ref` strings as opaque.

## Apply-time precedence summary

```
config/base/<file>   <-- ground truth, always loaded
       |
       v   (deep merge, identity-keyed for lists)
config/<env>/<file>  <-- sparse overlay, wins on collision
       |
       v   (resolve secret_refs)
secret backend       <-- Vault / GH Secrets / k8s Secret
       |
       v
effective runtime config consumed by wm-mcp / IS REST admin API
```

## Validation

Every YAML file is validated by `scripts/validate-config.sh`, which runs
in CI on every change to `config/**` or `schemas/**`. The script:

* Maps each file by basename to a `$defs/<name>` definition in
  `schemas/config.schema.json`.
* Files whose basename has no mapping fail (this prevents accidental
  drop-ins under `config/<env>/`).
* `additionalProperties: false` is set on every sub-schema, so an
  unknown top-level key fails validation - this is the project's primary
  guard against silent typos like `varables:` instead of `variables:`.
* `extended-settings.properties` is skipped (raw IS settings, not YAML).
