# Authoring webMethods unit tests

This guide covers how to author unit tests for the packages in this
repository using the **IBM webMethods Integration Test Suite (UTF)**
— formerly known as `wMTestSuite`. Tests are first-class IS assets
authored in **webMethods Designer** and executed headlessly in CI by
[`scripts/test-unit.sh`](../scripts/test-unit.sh).

For the architectural rationale (why UTF rather than a generic JUnit
shim, why mocks-in-test-cases rather than third-party AOP), see
Task 4.1 in the project plan.

---

## TL;DR

For every package `packages/<P>/`, create a sibling test project
under `tests/unit/<P>Test/`. Inside, the runner expects:

```
tests/unit/<P>Test/
  .project                            (Designer project metadata)
  .classpath
  test/
    test-suites/
      <SuiteName>.wmTestSuite         (one or more)
      <SuiteName>/
        <CaseA>.wmTestCase
        <CaseB>.wmTestCase
    setup/
      fixtures/                       (reusable input pipelines)
      mocks/                          (shared mock definitions)
```

The headless runner discovers `*.wmTestSuite` files automatically; you
only edit `tests/unit/run-test-suites.properties.tmpl` if you want to
adjust runner-wide settings (host/port, coverage globs).

---

## Recording a test from a running service

For legacy services with no tests yet, the fastest path is **Service
Result Capture** in Designer. This produces a `.wmTestCase`
pre-populated with the recorded input pipeline, the observed output
pipeline as the expected output, and one mock for every downstream
INVOKE the service made.

Steps:

1. In Designer, open the flow service.
2. **Service Development** → **Enable Service Result Capture** for
   the service (or for the whole package). The IS instance must be
   running.
3. Invoke the service once with realistic input — via the Designer
   **Run** dialog, an HTTP client, the **wm.server:invoke** tool, etc.
4. Open **Service Development** → **Service Results**, find the
   captured invocation.
5. Right-click the result → **Generate Test Case**.
6. Designer prompts for a target project. Pick `tests/unit/<P>Test`
   and a suite (or create a new one). It writes a `.wmTestCase` under
   `test/test-suites/<SuiteName>/`.
7. **Inspect and trim**. The recorded mocks include every downstream
   call — sometimes you'll want to keep only some; sometimes the
   recorded output pipeline contains values that change run-to-run
   (timestamps, generated IDs) and the assertion needs to be relaxed
   from `equals` to `exists` or a regex match.
8. Commit the `.wmTestCase` and rerun `scripts/test-unit.sh`.

This is the recommended way to bootstrap coverage on legacy services.
Hand-authoring is fine for new services where the input/output is
small and well-understood.

---

## Authoring a test by hand

### A `.wmTestSuite` file

A test suite is a manifest of test cases. Suite name maps to the
classname in JUnit reports and shows up as a group in the GitHub
Actions Checks tab.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<wmTestSuite name="Greet" version="1.0">
    <description>Unit tests for hello.world:greet.</description>
    <package>HelloWorld</package>
    <testCases>
        <testCaseRef path="Greet/GreetHappyPath.wmTestCase"/>
        <testCaseRef path="Greet/GreetMissingName.wmTestCase"/>
    </testCases>
</wmTestSuite>
```

### A `.wmTestCase` file

A test case names: **the service under test**, **the input pipeline**,
**assertions on the output pipeline**, and **mock definitions** for
any downstream service the SUT invokes.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<wmTestCase name="GreetHappyPath" version="1.0">
    <description>greet("World") returns "Hello, World!".</description>
    <serviceUnderTest>hello.world:greet</serviceUnderTest>
    <inputPipeline format="xml"><![CDATA[
<IData>
    <value name="name">World</value>
</IData>
    ]]></inputPipeline>
    <expectedOutput>
        <assertion type="equals" path="greeting" expected="Hello, World!"/>
        <assertion type="exists" path="greeting"/>
    </expectedOutput>
    <mocks/>
</wmTestCase>
```

### Assertion vocabulary

| `type=`     | What it checks                                                    |
|-------------|--------------------------------------------------------------------|
| `equals`    | The pipeline value at `path` equals `expected` (string compare).   |
| `exists`    | A pipeline entry at `path` exists (any value).                     |
| `notExists` | No entry at `path`.                                                |
| `regex`     | The pipeline value at `path` matches the `expected` regex.         |
| `xpath`     | A boolean XPath against an XML pipeline value.                     |

`path` uses the same dotted/bracket form Designer uses in the pipeline
view — e.g. `customer.address[0].zip`.

### Mock definitions

A mock replaces a downstream INVOKE with a canned response. Match
keys: `serviceName` (always), optionally `inputPipelineMatcher`
(matches when the input shape — keys / values — matches the matcher;
useful when the same downstream service is invoked twice with
different inputs in one test run).

```xml
<mocks>
    <mock>
        <serviceName>hello.world.jdbc:insertGreeting</serviceName>
        <responsePipeline format="xml"><![CDATA[
<IData>
    <value name="rowsAffected">1</value>
    <value name="generatedId">42</value>
</IData>
        ]]></responsePipeline>
    </mock>

    <!-- Match by input shape: only fire when name=="missing". -->
    <mock>
        <serviceName>hello.world.audit:lookup</serviceName>
        <inputPipelineMatcher format="xml"><![CDATA[
<IData>
    <value name="name">missing</value>
</IData>
        ]]></inputPipelineMatcher>
        <responsePipeline format="xml"><![CDATA[
<IData>
    <value name="found">false</value>
</IData>
        ]]></responsePipeline>
    </mock>
</mocks>
```

The WmTestSuite engine handles JDBC adapter calls, `pub.client:http`,
`pub.jms:send`, Kafka send/receive, and most other built-in adapters
through this same mechanism. **No third-party AOP is involved.** That
is why unit tests run against an MSR with no external infrastructure —
no Postgres sidecar, no broker, no Kafka.

### Sharing mocks and fixtures

Common mocks (e.g. the JDBC audit-row INSERT used by half of the
test cases for a package) live under `test/setup/mocks/` and can be
referenced by file rather than inlined:

```xml
<mocks>
    <mock file="setup/mocks/jdbc-insert-greeting.xml"/>
</mocks>
```

Likewise, common input pipelines live under `test/setup/fixtures/`:

```xml
<inputPipeline format="xml" file="setup/fixtures/sample-input.xml"/>
```

---

## Running the tests locally

```bash
# Build the service image once (uses the test variant of the base image).
make build

# Run the headless runner.
scripts/test-unit.sh
```

Outputs land under `reports/unit/`:

```
reports/unit/
  html/index.html       pretty HTML report
  coverage/index.html   wmcodecoverage HTML report
  raw/                  raw wmTestSuiteResult.xml files
  junit.xml             JUnit XML for dorny/test-reporter
```

Useful flags:

| Flag                    | What it does                                              |
|-------------------------|-----------------------------------------------------------|
| `--no-coverage`         | Skip coverage instrumentation (faster, used on every push). |
| `--suites NAME[,...]`   | Run only the named suites.                                |
| `--keep`                | Leave the container running after the run for debugging.  |
| `--coverage-threshold F`| Use a different thresholds YAML.                          |

`scripts/test-unit.sh` exits:

- `0` — all passed and coverage met.
- `2` — one or more cases failed/errored.
- `3` — tests passed but coverage fell below the threshold.

---

## Coverage threshold

`tests/unit/coverage-threshold.yaml` configures the gate. Defaults
apply to packages without an explicit entry:

```yaml
defaults:
  min_line_coverage: 70

packages:
  HelloWorld:
    min_line_coverage: 80
```

To waive a package (with reviewer approval), set its threshold to `0`
and add a comment explaining why.

The gate inspects the wmcodecoverage Cobertura-style XML emitted by
the `composite-runner-all-tests-with-coverage` Ant target. Vendor
packages (`Wm*`, `Default`) are filtered by the `coverage-exclude`
glob in `run-test-suites.properties.tmpl`.

---

## CI integration

The GitHub Actions workflow (added in Task 6.x) calls
`scripts/test-unit.sh`, then publishes `reports/unit/junit.xml` via
`dorny/test-reporter` so failures render in the **Checks** tab. The
HTML and coverage reports are uploaded as workflow artifacts.

`run-test-suites.properties.tmpl` is rendered at workflow time using
[`scripts/lib/render-properties.sh`](../scripts/lib/render-properties.sh)
with admin creds drawn from GitHub Secrets — the file in git holds
no secrets.

---

## See also

- [`scripts/test-unit.sh`](../scripts/test-unit.sh) — the runner.
- [`scripts/lib/wmtestsuite-to-junit.xsl`](../scripts/lib/wmtestsuite-to-junit.xsl)
  — XSLT for raw → JUnit conversion.
- [`scripts/lib/render-properties.sh`](../scripts/lib/render-properties.sh)
  — properties template renderer.
- [`tests/unit/HelloWorldTest/`](../tests/unit/HelloWorldTest) — the
  reference example, with passing, deliberately-failing, and
  JDBC-mocked test cases.
- Task 4.2 — integration tests against a real DB / broker stack.
