// tests/integration/k6/smoke.js
//
// Tiny smoke load test against a running MSR. The intent is NOT to
// stress the runtime -- it's to catch obvious regressions at the
// "is the request path even up under concurrent traffic?" level. The
// real perf rig lives outside this repo.
//
// Invocation (driver = scripts/test-integration.sh):
//   k6 run \
//     -e MSR_BASE_URL=http://localhost:15555 \
//     -e MSR_ADMIN_USER=Administrator \
//     -e MSR_ADMIN_PASSWORD=manage \
//     --summary-export reports/integration/k6/summary.json \
//     tests/integration/k6/smoke.js
//
// Outputs:
//   summary.json   -- machine-readable, written by k6's --summary-export
//   junit.xml      -- written here in handleSummary() so dorny/test-reporter
//                     and the aggregator in scripts/test-integration.sh see
//                     a green/red signal alongside Newman/REST-assured.
//   stdout-summary.txt -- pretty text dump for human-readable logs.

import http from 'k6/http';
import { check, sleep } from 'k6';
import encoding from 'k6/encoding';

// ---------------------------------------------------------------------
// Tunables
// ---------------------------------------------------------------------
const BASE_URL = __ENV.MSR_BASE_URL || 'http://localhost:15555';
const USER     = __ENV.MSR_ADMIN_USER || 'Administrator';
const PASSWORD = __ENV.MSR_ADMIN_PASSWORD || 'manage';

const AUTH_HEADER = 'Basic ' + encoding.b64encode(`${USER}:${PASSWORD}`);

export const options = {
  // Three short stages: ramp up, hold, ramp down. Total ~30s so the
  // smoke load fits inside the integration-test budget.
  stages: [
    { duration: '5s',  target: 5 },
    { duration: '20s', target: 5 },
    { duration: '5s',  target: 0 },
  ],
  thresholds: {
    // Hard gates the run is considered failed against. p95 of 750ms
    // is lenient on purpose; smoke is for "did things obviously
    // break", not "is perf budget hit".
    http_req_failed:   ['rate<0.01'],
    http_req_duration: ['p(95)<750'],
    checks:            ['rate>0.99'],
  },
  // Don't poison the run with stale cookies between iterations.
  noConnectionReuse: false,
  discardResponseBodies: false,
};

export default function () {
  const res = http.get(`${BASE_URL}/invoke/wm.server:ping`, {
    headers: { Authorization: AUTH_HEADER, Accept: 'application/json' },
    tags: { endpoint: 'ping' },
  });

  check(res, {
    'status is 200':            (r) => r.status === 200,
    'body acknowledges ping':   (r) => /ok|pong|alive/i.test(r.body || ''),
    'served under 750ms':       (r) => r.timings.duration < 750,
  });

  // 200ms think time -> ~25 req/s with 5 VUs, well within MSR's
  // default thread pool. Tune on a per-package basis if the smoke
  // grows beyond a single endpoint.
  sleep(0.2);
}

// ---------------------------------------------------------------------
// JUnit emitter for handleSummary().
// k6 has no first-party JUnit reporter; we synthesize one ourselves so
// the integration-test aggregator can merge it with Newman + Surefire.
// ---------------------------------------------------------------------
function junitFromSummary(data) {
  const checks = (data.root_group && data.root_group.checks) || [];
  // k6 0.45+ also surfaces threshold pass/fail under data.metrics.
  const thresholdFailures = [];
  for (const [metric, info] of Object.entries(data.metrics || {})) {
    if (!info.thresholds) continue;
    for (const [thr, state] of Object.entries(info.thresholds)) {
      if (state.ok === false) {
        thresholdFailures.push({ metric, threshold: thr });
      }
    }
  }

  let passes = 0;
  let failures = 0;
  const cases = [];
  for (const c of checks) {
    const ok = c.fails === 0;
    if (ok) passes++; else failures++;
    cases.push({
      name: xmlEscape(c.name),
      ok,
      passes: c.passes,
      fails:  c.fails,
    });
  }
  for (const tf of thresholdFailures) {
    failures++;
    cases.push({
      name: xmlEscape(`threshold ${tf.metric} :: ${tf.threshold}`),
      ok: false,
      passes: 0,
      fails: 1,
    });
  }

  const total = passes + failures;
  const duration = (data.state && data.state.testRunDurationMs)
    ? (data.state.testRunDurationMs / 1000).toFixed(3)
    : '0';

  const xmlBody = cases.map((c) => (
    c.ok
      ? `    <testcase classname="k6.smoke" name="${c.name}"/>`
      : `    <testcase classname="k6.smoke" name="${c.name}"><failure type="CheckFailed">passes=${c.passes} fails=${c.fails}</failure></testcase>`
  )).join('\n');

  return [
    '<?xml version="1.0" encoding="UTF-8"?>',
    `<testsuites name="k6" tests="${total}" failures="${failures}" time="${duration}">`,
    `  <testsuite name="smoke" tests="${total}" failures="${failures}" time="${duration}">`,
    xmlBody,
    '  </testsuite>',
    '</testsuites>',
    '',
  ].join('\n');
}

function xmlEscape(s) {
  return String(s)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&apos;');
}

export function handleSummary(data) {
  // textSummary is the default pretty-printer that ships with k6's
  // jslib; we re-emit it so stdout matches what users see locally.
  const text = renderTextSummary(data);
  return {
    stdout: text,
    'reports/integration/k6/junit.xml':  junitFromSummary(data),
    'reports/integration/k6/summary.json': JSON.stringify(data, null, 2),
    'reports/integration/k6/summary.txt':  text,
  };
}

// Minimal stdout summary so the script doesn't need the jslib network
// dependency at run time. k6 will still print its own banner; this is
// just the bit we capture to summary.txt.
function renderTextSummary(data) {
  const lines = ['k6 smoke summary', '================', ''];
  for (const [name, m] of Object.entries(data.metrics || {})) {
    if (!m.values) continue;
    const v = m.values;
    const row = Object.entries(v)
      .map(([k, n]) => `${k}=${typeof n === 'number' ? n.toFixed(2) : n}`)
      .join('  ');
    lines.push(`  ${name}: ${row}`);
  }
  lines.push('');
  return lines.join('\n');
}
