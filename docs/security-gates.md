# Security gates

The pipeline runs **three layers** of automated security checks:

1. An **inline source-tree layer** on every PR
   (`.github/workflows/security.yml`) — secret scanning + filesystem
   CVE scanning of dependencies.
2. An **inline image layer** on every PR that touches the service
   image (`.github/workflows/image-security.yml`) — base-image
   signature verification + container CVE scan + SBOM generation /
   attestation.
3. An **asynchronous repo-level layer** provided by GitHub Advanced
   Security — secret scanning, push protection, Dependabot.

The three are complementary — the inline layers are fail-fast so a
PR cannot merge while a finding is open, the asynchronous layer
catches things that arrive after merge (new CVE published against an
old commit, a secret pasted into a comment, etc.).

This page documents all three layers and how to verify they work.

## Inline source-tree layer (`.github/workflows/security.yml`)

| Job        | Tool                                | Trigger                           | Behaviour on a finding                              |
| ---------- | ----------------------------------- | --------------------------------- | --------------------------------------------------- |
| `gitleaks` | gitleaks (binary, version pinned in `versions.env`) | every PR (diff scan), push to `main`, weekly cron, manual dispatch | uploads SARIF to **Security → Code scanning** and **fails the job**. |
| `trivy-fs` | aquasecurity/trivy-action           | same                              | uploads SARIF to **Security → Code scanning**, prints a CVE table to the job log, **fails the job** on any HIGH/CRITICAL. |

Both jobs always upload SARIF (even when they fail) — the
`continue-on-error` on the scan step plus the `if: steps.scan.outcome == 'failure'`
fail step is what makes that work.

### gitleaks scan range

Optimised for fast PR feedback:

| Event             | Scope                                                  |
| ----------------- | ------------------------------------------------------ |
| `pull_request`    | commits added on top of the target branch (`base..HEAD`). |
| `push` to `main`  | commits new in the push (`before..head`); first push falls back to a working-tree scan. |
| `schedule` / `workflow_dispatch` | full working-tree scan via `gitleaks dir .` (catches anything that bypassed PR review). |

The rule pack is `useDefault = true` (~150 detectors including AWS,
GCP, Azure, Slack, Stripe, GitHub PAT, generic high-entropy, private
keys). Repo-local allowlists live in `.gitleaks.toml`.

### trivy scan scope

`trivy fs --severity HIGH,CRITICAL --exit-code 1 .` over the working
tree, with `dist/`, `reports/`, and `.git/` skipped. Three scanners
are enabled:

- `vuln`     — CVEs in JARs (under `docker/base/jars/`), Maven `pom.xml`,
  any other supported lockfile;
- `secret`   — second-pass secret scanner (defence in depth alongside gitleaks);
- `misconfig` — Dockerfile / IaC misconfigurations.

The DB is cached across runs via `actions/cache`; daily DB refreshes
land via the upstream TTL.

## Inline image layer (`.github/workflows/image-security.yml`)

Builds the per-microservice image (`docker/service/Dockerfile`) on
top of the corporate MSR base, then runs four checks before
considering it shippable:

| Step                       | Tool       | Behaviour on a finding                                                  |
| -------------------------- | ---------- | ----------------------------------------------------------------------- |
| `Verify base image`        | cosign     | **Fails the job** if the base ref is not signed by the production base-image workflow on `main` (Sigstore Fulcio identity, OIDC issuer pinned). Runs **before** the build so a malicious base never reaches the runner filesystem. |
| `Run trivy image scan`     | trivy      | **Fails on `CRITICAL`**, emits `::warning::` on `HIGH`, ignores `LOW`/`MEDIUM`. SARIF lands in **Security → Code scanning** under category `trivy-image`. |
| `Generate SBOM`            | syft       | Always produces an SPDX-JSON SBOM and uploads it as an Actions artifact (`sbom-spdx-json`). |
| `Sign + attest` (publish)  | cosign     | On push-to-main and `workflow_dispatch`, the service image is pushed, signed (`cosign sign`), and the SBOM is attached as an attestation (`cosign attest --type spdxjson`). The workflow re-verifies its own signature + attestation as a smoke test. PR runs **skip** publish/sign/attest. |

### Severity gate (CRITICAL fails, HIGH warns, LOW/MEDIUM ignored)

The trivy image step takes a single JSON scan over the just-built
image with `--severity HIGH,CRITICAL` (LOW/MEDIUM filtered at the
scanner). It then converts that JSON into both SARIF (Security tab)
and table (job log) without re-running trivy, and parses the JSON to
count CRITICAL vs HIGH findings:

* **CRITICAL count > 0** → `::error::` annotation, exit 1.
* **HIGH count > 0** → `::warning::` annotation, exit 0.
* SARIF upload is `if: always()` so findings appear in the Security
  tab even when the build is failed by a CRITICAL.

### Base-image verification

The expected cosign identity is hard-pinned to:

```
https://github.com/<owner>/<repo>/.github/workflows/base-image.yml@refs/heads/main
```

This is intentional — base images cut from a feature branch are not
production-eligible even if they exist in the registry. Any other
signer (or no signer at all) fails the gate.

The base image ref defaults to
`ghcr.io/<owner>/wm-msr-base:<MSR_VERSION>-base-latest`, resolved to
its current digest at the start of the run so every downstream step
(verify, build `--from`, trivy, SBOM) targets the same artifact.
`workflow_dispatch` accepts a `base_image_ref` input for ad-hoc
overrides.

### Triggers

| Event                | What runs                                                                                                       |
| -------------------- | --------------------------------------------------------------------------------------------------------------- |
| `pull_request`       | verify base + build + trivy + SBOM artifact. **No** push, sign, or attest. Image stays in the runner's daemon. |
| `push` to `main`     | full path: verify + build + trivy + SBOM + push three rolling tags + cosign sign + cosign attest + self-verify. |
| `schedule` (Mon 04:30 UTC) | full path on `main`. Catches CVEs published against the latest base image even when no service-side change has merged. Offset 30 min after `security.yml`. |
| `workflow_dispatch`  | full path; honours optional `base_image_ref` input.                                                              |

### Verifying a published service image

```
cosign verify \
  --certificate-identity \
    "https://github.com/<owner>/<repo>/.github/workflows/image-security.yml@refs/heads/main" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  ghcr.io/<owner>/wm-svc:<MSR_VERSION>-svc-latest

cosign verify-attestation \
  --type spdxjson \
  --certificate-identity \
    "https://github.com/<owner>/<repo>/.github/workflows/image-security.yml@refs/heads/main" \
  --certificate-oidc-issuer "https://token.actions.githubusercontent.com" \
  ghcr.io/<owner>/wm-svc:<MSR_VERSION>-svc-latest \
  | jq -r '.payload' | base64 -d | jq '.predicate.spdxVersion'
```

The first command authenticates the image; the second pulls the
attached SPDX-JSON SBOM and prints its `spdxVersion` as a smoke test.

## Asynchronous layer (GitHub Advanced Security)

These are **repo-level settings**, not workflow YAML. They must be
enabled once per repository — there is no way to commit them. The
state is visible at **Settings → Code security and analysis**.

| Feature                  | What it does                                                | How to enable                                |
| ------------------------ | ----------------------------------------------------------- | -------------------------------------------- |
| Secret Scanning          | Server-side scan of every push for ~200 partner secret types (incl. AWS access tokens). Findings appear under **Security → Secret scanning**. | Settings UI: toggle **Secret scanning**. CLI: `gh api -X PATCH repos/{owner}/{repo} -f security_and_analysis[secret_scanning][status]=enabled` |
| Push Protection          | Refuses the push at git-receive time when a known token format is detected. Strongly recommended — closes the gap between "someone committed it" and "the inline workflow ran". | Settings UI: toggle **Push protection**. CLI: same endpoint, `secret_scanning_push_protection[status]=enabled` |
| Dependabot alerts        | Continuous CVE alerting against the dependency graph. Findings appear under **Security → Dependabot**. | Settings UI: toggle **Dependabot alerts**. CLI: `gh api -X PUT repos/{owner}/{repo}/vulnerability-alerts` |
| Dependabot security updates | Auto-opens PRs that bump vulnerable deps. | Settings UI: toggle **Dependabot security updates**. CLI: `gh api -X PUT repos/{owner}/{repo}/automated-security-fixes` |

Inline and asynchronous detectors **do not** replace each other. A PR
that adds a fake AWS key trips both gitleaks (in this workflow) **and**
Secret Scanning (post-push). The acceptance test for this task
deliberately checks both signals.

> **Future work, intentionally out of scope for Task 5.1.** A
> `.github/dependabot.yml` configuring weekly version-update PRs
> for the `github-actions` and `docker` ecosystems would round out
> the coverage. Add it in a follow-on PR once a real package
> ecosystem (Maven / npm) lands in a microservice.

## Acceptance tests

These reproduce the criteria from the plan. Both must be run on a
throwaway branch — never commit a real-looking secret or a
known-vulnerable JAR to a long-lived branch.

### A1. Fake AWS key trips gitleaks AND Secret Scanning

```bash
# Use AWS's documented dummy format -- 16 chars after AKIA, base64-ish.
# Example pattern: AKIAEXAMPLE1234567PR  (do NOT use the canonical
# AWS docs example AKIAIOSFODNN7EXAMPLE -- it is allowlisted in
# .gitleaks.toml on purpose).
git checkout -b sec-test-aws-key
echo 'aws_access_key_id = AKIAZ7B8YXC9NEXAMPLE'      >> /tmp/leak.txt
echo 'aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYNOTREAL12' >> /tmp/leak.txt
mv /tmp/leak.txt config/dev/leak.txt   # any tracked path works
git add config/dev/leak.txt
git commit -m 'sec-test: fake AWS key (do not merge)'
git push -u origin sec-test-aws-key
gh pr create --draft --title 'sec-test: AWS key (DO NOT MERGE)' --body 'Acceptance test for Task 5.1.'
```

Expected:

1. The `gitleaks (secrets)` job fails on the PR within ~30 s, with a
   `aws-access-token` finding visible in the step log and as a SARIF
   alert under **Security → Code scanning** with category `gitleaks`.
2. Within a few minutes, **Security → Secret scanning** also surfaces
   the same finding from GitHub's server-side scanner.
3. If push protection is enabled, the original `git push` is rejected
   at receive time — to run this test you have to bypass push
   protection ("allow secret" with a one-time approval).

Cleanup:

```bash
gh pr close --delete-branch sec-test-aws-key
# Resolve the Secret Scanning alert as "Used in tests" so it does
# not pollute the dashboard.
```

### A2. Vulnerable JAR fails the trivy step with a CVE ID in the log

The intended target is `docker/base/jars/` (where the corporate JDBC
drivers land at build time). Drop a known-vulnerable JAR there:

```bash
git checkout -b sec-test-cve-jar
# log4j-core 2.14.1 is the canonical Log4Shell carrier (CVE-2021-44228).
# Mirrors come and go; pick whichever Maven mirror is reachable from
# the runner. The point is that trivy detects the embedded version.
curl -fsSL -o docker/base/jars/log4j-core-2.14.1.jar \
  https://repo1.maven.org/maven2/org/apache/logging/log4j/log4j-core/2.14.1/log4j-core-2.14.1.jar
git add docker/base/jars/log4j-core-2.14.1.jar
git commit -m 'sec-test: vulnerable jar (do not merge)'
git push -u origin sec-test-cve-jar
gh pr create --draft --title 'sec-test: vulnerable JAR (DO NOT MERGE)' --body 'Acceptance test for Task 5.1.'
```

Expected:

1. The `trivy fs (CVEs)` job fails on the PR.
2. The **table** step prints CVE IDs inline in the log, including at
   minimum `CVE-2021-44228` (Log4Shell, CRITICAL) and very likely
   `CVE-2021-45046` (CRITICAL) and `CVE-2021-45105` (HIGH).
3. The same findings appear under **Security → Code scanning** with
   category `trivy-fs`.

Cleanup:

```bash
gh pr close --delete-branch sec-test-cve-jar
```

> **Note.** `*.jar` is gitignored at the repo root **except** for
> `packages/*/code/jars/**/*.jar`. To stage a JAR under
> `docker/base/jars/` you must `git add -f` it (or temporarily
> negate the rule). This is intentional — JDBC drivers are not
> source-controlled in this repo (Task 1.1 design decision).

### A3. Vulnerable base image trips the `image-security` PR check

Two reproducible recipes — both turn the `image-security` check red
on the PR.

#### A3a. Quickest path: `workflow_dispatch` with an unsigned base

No PR/branch needed. From the **Actions → image-security** page,
click **Run workflow** and set the `base_image_ref` input to
`docker.io/vulnerables/web-dvwa`. Expected:

1. The `Verify base image cosign signature` step **fails** with a
   `no matching signatures` / `tlog entry not found` error —
   `vulnerables/web-dvwa` was never signed by our base-image
   workflow's identity.
2. The build does not proceed past base verification (fail-fast
   ordering is intentional).
3. The workflow conclusion is `failure`.

This proves the cosign verify gate.

#### A3b. Full path: vulnerable base on a real PR

Reproduces the criterion verbatim ("introducing `vulnerables/web-dvwa`
as base in a test branch").

```bash
git checkout -b sec-test-vulnerable-base
# Override the BASE_IMAGE arg default in the service Dockerfile.
# This makes the FROM resolve to vulnerables/web-dvwa for the build,
# and is what the workflow's resolve-base step picks up too (since
# we do not use the workflow_dispatch override on a pull_request
# event).
sed -i 's|^ARG BASE_IMAGE$|ARG BASE_IMAGE=docker.io/vulnerables/web-dvwa|' docker/service/Dockerfile

# Anything else that triggers the image-security path filter is fine;
# touching the Dockerfile is sufficient.
git add docker/service/Dockerfile
git commit -m 'sec-test: vulnerable base (do not merge)'
git push -u origin sec-test-vulnerable-base
gh pr create --draft --title 'sec-test: vulnerable base (DO NOT MERGE)' \
  --body 'Acceptance test for Task 5.2.'
```

Expected:

1. `Verify base image cosign signature` **fails** — same reason as
   A3a, web-dvwa is not signed by our base-image workflow identity.
2. Even if the verify step were skipped, `Run trivy image scan`
   would fail on CRITICAL CVEs (web-dvwa is built around an EOL
   Debian with dozens of known critical findings) — so the gate is
   defended in depth.
3. The `image-security` PR check turns red.

Cleanup:

```bash
gh pr close --delete-branch sec-test-vulnerable-base
```

> **Note.** `vulnerables/web-dvwa` lacks the `sagadmin` user and
> `IS_INSTANCE_DIR` env var that our service Dockerfile expects, so
> on some runs the build itself errors before trivy gets a chance.
> That is still a red `image-security` check, which is what the
> acceptance criterion calls for. If you want to isolate the
> *trivy-only* failure mode, use A3a (which never builds at all).

## Operating notes

- **Allowlisting**: prefer path-scoped allowlists in `.gitleaks.toml`
  over disabling rules. Never allowlist a real secret — rotate it.
- **CVE waivers**: there is no global ignore file. If a HIGH/CRITICAL
  finding cannot be fixed immediately, add a per-finding suppression
  via `.trivyignore` (NOT yet present in the repo — add it on first
  legitimate need with a comment justifying each entry).
- **Cron drift**: the weekly schedules of `base-image.yml` (Mon 03:00),
  `security.yml` (Mon 04:00), and `image-security.yml` (Mon 04:30)
  are intentionally offset so the base-image rebuild's signed digest
  is fresh before the source CVE scan runs, which is itself fresh
  before the image CVE scan picks up the new base.
