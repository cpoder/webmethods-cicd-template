# webMethods Microservice CI/CD Pipeline

This repository contains the source code, configuration, and deployment artifacts for webMethods Integration Server (IS) microservices with a complete CI/CD pipeline on GitHub Actions.

## Using this template

This repo is published as a GitHub **template repository**. To start your own pipeline:

1. Click **Use this template → Create a new repository** on the GitHub page (or `gh repo create <you>/<repo> --template cpoder/webmethods-cicd-template --public`).
2. Clone your new repo and replace the placeholders / fixtures listed below before merging anything to `main`.

> **Hard prerequisite — IBM entitlement.** The MSR base image is pulled from IBM's entitled registry `cp.icr.io`. Before running `make image` (or letting CI do it), authenticate with your IBM entitlement key:
>
> ```
> docker login cp.icr.io
>   Username: cp
>   Password: <entitlement-key from https://myibm.ibm.com/products-services/containerlibrary>
> ```
>
> In CI, set `cp.icr.io` registry credentials as repo/org secrets and add a `docker/login-action` step before the build (the existing workflows assume registry auth is already wired). Without entitlement the build will 401 at the `FROM` line. The same applies to the `WM_TEST_SUITE_INSTALLER_URL` in `versions.env` — point it at your IBM Passport download or your corporate mirror; there is no working public default.

What to customise after cloning:

| File / area | What to change |
|---|---|
| `packages/HelloWorld/` | Demo package — replace with your real IS packages, or keep alongside as a smoke artifact |
| `CODEOWNERS` | Replace `@<org>/<team>` placeholder team handles with your org's teams |
| `helm/wm-microservice/values.yaml` | Image registry, hostnames, resource sizing for your environments |
| `config/{dev,test,prod}/` | Environment-specific overlays for connection strings, ports, ACLs |
| `scripts/setup-environments.sh` | Update `ENVIRONMENTS` if you have envs beyond `dev/test/prod`, then `--apply` |
| `scripts/setup/branch-protection.sh` | Run `--apply --bot-app <your-release-bot-slug>` once `main` exists |
| `docker/base/Dockerfile` | Point at your org's `wm-mcp-server` binary / registry |
| GitHub Environments + Secrets | Seed per `docs/secrets.md` matrix (registry creds, MSR admin, deploy keys) |

Then run `make build && make test && make image` locally to confirm the pipeline runs end-to-end before pushing.

## Prerequisites

Before you begin, ensure you have the following installed:

- **Docker** (20.10+) - For building and running containers
- **Java 17** (JDK) - Required for building and testing IS packages
- **jq** - JSON processor for configuration management
- **curl** - For API calls and health checks
- **act** (optional) - For running GitHub Actions workflows locally
- **make** - For using the build automation commands
- **Git** - Version control

### Optional Tools

- **wm-mcp-server** - webMethods Model Context Protocol server for AI-assisted development
  - Provided by your organisation; the base image (`docker/base/Dockerfile`) fetches the binary at build time

## Repository Structure

```
wmcicd/
├── packages/                  # Integration Server packages
│   └── <PackageName>/         # Each IS package (ns/, code/, manifest.v3, etc.)
├── config/                    # Environment-specific configurations
│   ├── base/                  # Default configurations shared by all environments
│   ├── dev/                   # Development environment overlays
│   ├── test/                  # Test environment overlays
│   └── prod/                  # Production environment overlays
├── tests/                     # Test suites
│   ├── unit/                  # Unit tests (wm-jbehave .story files + step definitions)
│   └── integration/           # Integration tests (newman/k6/REST-assured suites)
├── docker/                    # Docker build configurations
│   ├── base/                  # Corporate MSR base image
│   └── service/               # Per-microservice image (derives from base)
├── helm/                      # Kubernetes Helm charts (optional)
├── scripts/                   # Shell helpers used by CI (apply-config.sh, etc.)
├── .github/workflows/         # GitHub Actions CI/CD workflows
└── docs/                      # Additional documentation
```

## Quick Start Commands

Use these `make` commands for common tasks:

```bash
# Build all packages
make build

# Run unit tests
make test

# Build Docker image
make image

# Deploy to an environment (dev, test, or prod)
make deploy ENV=dev
make deploy ENV=test
make deploy ENV=prod
```

## Getting Started

### 1. Clone the Repository

```bash
git clone <repository-url>
cd wmcicd
```

### 2. Build Locally

```bash
# Build all IS packages
make build

# Run tests
make test
```

### 3. Run the Pipeline Locally

You have two options for running the CI/CD pipeline locally:

#### Option A: Using `act` (GitHub Actions locally)

```bash
# Install act if you haven't already
# macOS: brew install act
# Linux: see https://github.com/nektos/act

# Run the entire workflow
act

# Run a specific job
act -j build

# Run with specific event
act push
```

#### Option B: Using Docker Compose

```bash
# Start the full local development stack
docker compose up

# Build and start in detached mode
docker compose up -d

# View logs
docker compose logs -f

# Stop the stack
docker compose down
```

## How to Add a New Package

1. **Create the package directory structure**:
   ```bash
   mkdir -p packages/YourPackageName/{ns,code}
   ```

2. **Add your package files**:
   - Place flow services in `packages/YourPackageName/ns/`
   - Place Java services in `packages/YourPackageName/code/`
   - Create `manifest.v3` with package metadata

3. **Add package configuration**:
   - Add base configuration in `config/base/YourPackageName.properties`
   - Add environment-specific overrides in `config/{dev,test,prod}/`

4. **Write tests**:
   - Add unit tests in `tests/unit/YourPackageName/`
   - Add integration tests in `tests/integration/YourPackageName/`

5. **Update documentation**:
   - Document your package in `docs/packages/YourPackageName.md`

6. **Commit and push**:
   ```bash
   git add packages/YourPackageName
   git commit -m "feat(packages): add YourPackageName"
   git push
   ```

## How to Add a New Environment

1. **Create environment configuration directory**:
   ```bash
   mkdir -p config/newenv
   ```

2. **Add environment-specific configurations**:
   - Copy relevant files from `config/base/` to `config/newenv/`
   - Modify values for the new environment
   - Add secrets/credentials references (never commit actual secrets)

3. **Create the GitHub Environment and seed its secrets**:
   - Follow `docs/secrets.md` (canonical secret matrix and prod
     protection rules)
   - Run `scripts/setup-environments.sh --apply` after appending the
     new env to `ENVIRONMENTS` in that script
   - Run `scripts/setup-environments.sh --check` to verify every
     matrix-listed secret is set

4. **Update CI/CD workflow**:
   - Edit `.github/workflows/cd.yml`
   - Add the new environment to the deployment matrix

5. **Update deployment scripts**:
   - Modify `scripts/apply-config.sh` if needed
   - Add environment-specific deployment logic

## Configuration Management

Configuration files are organized by environment:

- **base/**: Default values and common settings
- **dev/**: Development-specific overrides
- **test/**: Test environment settings
- **prod/**: Production settings

The `scripts/apply-config.sh` helper merges base + environment-specific configs during deployment.

### Configuration Precedence

```
base config < environment config < runtime overrides
```

## Docker Images

### Base Image (`docker/base/`)
Corporate-standard MSR base image with:
- Security patches
- Common libraries
- Monitoring agents

### Service Image (`docker/service/`)
Microservice-specific image that:
- Derives from base image
- Includes IS packages
- Applies environment configuration

## Testing

### Unit Tests
Located in `tests/unit/`, using wm-jbehave framework:
```bash
# Run all unit tests
make test

# Run specific package tests
./scripts/test-unit.sh --package YourPackageName
```

### Integration Tests
Located in `tests/integration/`, using newman/k6/REST-assured:
```bash
# Run all integration tests
make integration-test

# Run specific test suite
./scripts/test-integration.sh --suite api-tests
```

## CI/CD Pipeline

The GitHub Actions workflows in `.github/workflows/` handle:

- **Build**: Compile packages, run unit tests
- **Test**: Run integration tests
- **Image**: Build and push Docker images
- **Deploy**: Deploy to target environments
- **Promote**: Promote releases through environments (dev → test → prod)

### Pipeline Stages

1. **Build** - Triggered on every push
2. **Test** - Runs after successful build
3. **Deploy to Dev** - Automatic on main branch
4. **Deploy to Test** - Manual approval required
5. **Deploy to Prod** - Manual approval + additional checks

### Security gates

Every PR runs three inline security checks:

- `gitleaks` (secret scanning over the diff) and
  `trivy fs --severity HIGH,CRITICAL` (dependency CVE scan) via
  `.github/workflows/security.yml`.
- `cosign verify` against the base image, `trivy image` against the
  built service image (CRITICAL fails, HIGH warns, LOW/MEDIUM
  ignored), and `syft` SPDX-JSON SBOM generation via
  `.github/workflows/image-security.yml`. On push to `main` the
  service image is also pushed, signed with `cosign sign`, and the
  SBOM is attached as a `cosign attest --type spdxjson` attestation.

All three jobs upload SARIF to the **Security → Code scanning** tab.
See [`docs/security-gates.md`](docs/security-gates.md) for the
inline + GitHub Advanced Security model and acceptance tests
(A1: gitleaks, A2: trivy-fs, A3: image-security).

### Observability

MSR's built-in Prometheus endpoint is enabled via
`watt.server.prometheus.enabled=true` in
[`config/base/extended-settings.properties`](config/base/extended-settings.properties)
and surfaced on container port `9999` at `/metrics`. The Helm chart's
[`templates/servicemonitor.yaml`](helm/wm-microservice/templates/servicemonitor.yaml)
emits a Prometheus-Operator `ServiceMonitor` (toggle
`metrics.serviceMonitor.enabled=true` per env). A starter Grafana
dashboard with JVM heap, flow-service-rate, JDBC-pool, and JMS-lag
panels lives at
[`docs/observability/dashboard.json`](docs/observability/dashboard.json).
See [`docs/observability/README.md`](docs/observability/README.md) for
import + scrape-verification recipes.

### Branch protection

`main` is locked down by the rules codified in
[`scripts/setup/branch-protection.sh`](scripts/setup/branch-protection.sh):
required PR review (`>= 1`, bumped to `>= 2` for `/config/prod/` via
[`CODEOWNERS`](CODEOWNERS)), required status check `gate`, linear
history, dismiss-stale-reviews, signed commits, no force-push or
deletion, and push restricted to the release bot. Run
`scripts/setup/branch-protection.sh` (dry-run) to preview the JSON
body, or `--apply --bot-app <slug>` to commit the rules. The script
is idempotent and re-runs cleanly. See
[`docs/branch-protection.md`](docs/branch-protection.md).

## Contributing

Please read [CONTRIBUTING.md](CONTRIBUTING.md) for details on:
- Branch model and workflow
- Commit message conventions
- Pull request process
- Code review guidelines

## Code Ownership

See [CODEOWNERS](CODEOWNERS) for automatic review assignment:
- `/packages/**` - Integration team and package maintainers
- `/config/**` - DevOps and integration teams
- `/.github/**` - DevOps team
- `/docker/**` - DevOps team

## Operations & troubleshooting

The on-call front door is [`docs/runbook.md`](docs/runbook.md) — it
covers rollback, MSR version bumps, adding a package, adding an
environment, and reading MSR logs against either backend. The
symptom-oriented failure-mode catalogue lives at
[`docs/troubleshooting.md`](docs/troubleshooting.md) (package
install fails, config apply fails, smoke fails, CrashLoop, security
gate failures, etc.).

For a deploy-failed-in-prod page, jump straight to
[`docs/runbook.md` §0](docs/runbook.md#0-pager-response--deploy-failed-in-prod-what-do-i-do).

## End-to-end demo

The pipeline acceptance test — a single PR adding the
[`HelloWorld`](packages/HelloWorld/) package, going from PR-open →
green CI → merged → dev → test → prod with each env's deployed
service returning a greeting tagged with its own env name — is
walked through step-by-step in [`docs/demo.md`](docs/demo.md). That
document also lists the screenshots / Loom shots to capture for
sign-off.

## Support

For questions or issues:
- Check the `docs/` directory for detailed documentation
- Review [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines
- Contact the integration team (see [CODEOWNERS](CODEOWNERS))
- Open an issue in this repository

## Additional Resources

- [IBM webMethods Integration Server documentation](https://www.ibm.com/docs/en/webmethods-integration/wm-integration-server/11.1.0)
- [IBM webMethods Helm charts (reference patterns)](https://github.com/IBM/webmethods-helm-charts)
- [GitHub Actions documentation](https://docs.github.com/en/actions)
- [Docker best practices](https://docs.docker.com/develop/dev-best-practices/)

## License

Apache License 2.0 — see [LICENSE](LICENSE).