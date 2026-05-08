# Observability — wm-microservice

This directory holds the runtime-observability bits for the
`wm-microservice` chart:

| File | Purpose |
| ---- | ------- |
| `dashboard.json` | Starter Grafana dashboard (importable as-is). |
| `README.md` (this file) | How metrics are exposed, scraped, and visualised. |

The MSR runtime ships with a built-in Prometheus endpoint. Once enabled
it exposes JVM, flow service, JDBC, and JMS metrics on `:9999/metrics`
in the standard Prometheus text format. We just have to (a) turn it on,
(b) tell Prometheus where to scrape it, and (c) point Grafana at the
result.

---

## 1. Enable the MSR Prometheus endpoint

Done already at the config layer. The base extended-settings file
contains:

```properties
# config/base/extended-settings.properties
watt.server.prometheus.enabled=true
watt.server.prometheus.port=9999
```

`scripts/apply-config.sh` applies this on every deploy via
`wm-mcp set_extended_setting`, so any pod that comes up with the
current config has `/metrics` live.

To verify on a running pod:

```sh
kubectl exec -n <ns> <pod> -- curl -fsS http://localhost:9999/metrics | head -50
```

You should see lines like:

```
# HELP jvm_memory_used_bytes The amount of used memory
# TYPE jvm_memory_used_bytes gauge
jvm_memory_used_bytes{area="heap",id="G1 Eden Space",} 1.34217728E8
...
sag_is_service_invocations_total{service="HelloWorld:greet"} 42.0
sag_is_jdbc_connections_active{pool="defaultDb"} 3.0
sag_is_jms_consumer_lag{alias="orderQueue",destination="orders"} 0.0
```

---

## 2. ServiceMonitor (Prometheus Operator)

The Helm chart now emits a `monitoring.coreos.com/v1 ServiceMonitor`
when both toggles are on:

```yaml
# helm/wm-microservice/values.yaml (excerpt)
metrics:
  enabled: true                      # publishes the metrics container/Service port
  serviceMonitor:
    enabled: false                   # turn ON per-env where Prometheus Operator is installed
    additionalLabels:
      release: prometheus            # default kube-prometheus-stack selector
    interval: 30s
    scrapeTimeout: 10s
    scheme: http
```

Per-env overrides flip `serviceMonitor.enabled: true` for `dev`, `test`
and `prod` (see `helm/wm-microservice/values-{dev,test,prod}.yaml`).

Render the resource locally to inspect:

```sh
helm template wm-svc-dev helm/wm-microservice \
  -f helm/wm-microservice/values-dev.yaml \
  --set image.tag=preview \
  --show-only templates/servicemonitor.yaml
```

Acceptance: in the dev cluster, after a successful CD deploy, the
operator picks up the ServiceMonitor and you can confirm the target
shows up in the Prometheus UI under
`Status → Targets → serviceMonitor/<ns>/wm-svc-dev/0`. The endpoint
reports `state=UP` and `last scrape duration < 1s`.

### Selector mismatch troubleshooting

If your Prometheus Operator instance does NOT use
`release: prometheus` as the ServiceMonitor selector (this is common
when the operator was installed via an upstream helm chart or by hand),
override `metrics.serviceMonitor.additionalLabels` per-env to match
the operator's `serviceMonitorSelector`:

```yaml
metrics:
  serviceMonitor:
    additionalLabels:
      app.kubernetes.io/instance: my-prometheus-operator
```

Or, if the operator is configured with `serviceMonitorSelector: {}`
(matches everything in selected namespaces), drop the labels block
entirely.

### Without Prometheus Operator

If your cluster does not have the Prometheus Operator CRDs installed
the ServiceMonitor template is simply not rendered (the toggle gate
ensures `helm install` does not fail with `no matches for kind`). In
that case configure scraping via plain Prometheus
`scrape_config` against the chart's Service:

```yaml
scrape_configs:
  - job_name: wm-microservice
    kubernetes_sd_configs:
      - role: endpoints
    relabel_configs:
      - source_labels: [__meta_kubernetes_service_label_app_kubernetes_io_name]
        action: keep
        regex: wm-microservice
      - source_labels: [__meta_kubernetes_endpoint_port_name]
        action: keep
        regex: metrics
```

---

## 3. Grafana dashboard

`docs/observability/dashboard.json` is a starter dashboard with five
sections:

1. **Overview** — pods up, flow service invocation rate, error ratio,
   peak JVM heap fraction.
2. **JVM Heap** — heap used by pool, committed vs max, GC pause time,
   thread states.
3. **Flow Service Rates** — top services by invocation rate, top
   services by error rate, p50/p95/p99 execution time.
4. **JDBC Pool Usage** — active/idle/max per pool, utilisation
   percentage, connection wait time.
5. **JMS Lag** — consumer lag per alias/destination, send/receive
   throughput, redelivered/failed.

### Importing

Via Grafana UI:

1. **Dashboards → New → Import**
2. Upload `docs/observability/dashboard.json`
3. Pick the Prometheus datasource that scrapes the wm-microservice
   ServiceMonitor (the import wizard exposes the `DS_PROMETHEUS`
   placeholder)
4. **Import**

The dashboard auto-discovers `namespace` and `job` via Prometheus
label_values queries, so the same dashboard works against dev / test /
prod without per-env editing — just pick the namespace from the
dropdown at the top.

Via Grafana provisioning (recommended for dev/test/prod):

```yaml
# /etc/grafana/provisioning/dashboards/wm-microservice.yaml
apiVersion: 1
providers:
  - name: 'wm-microservice'
    orgId: 1
    folder: 'webMethods'
    type: file
    disableDeletion: false
    editable: true
    updateIntervalSeconds: 60
    options:
      path: /var/lib/grafana/dashboards/wm-microservice
```

…and drop `dashboard.json` into the watched folder. Grafana picks it
up on the next reload.

Via API:

```sh
curl -fsSL -X POST \
  -H "Authorization: Bearer $GRAFANA_TOKEN" \
  -H "Content-Type: application/json" \
  --data "$(jq -n --slurpfile d docs/observability/dashboard.json '{dashboard: $d[0], overwrite: true}')" \
  https://grafana.example.com/api/dashboards/db
```

### Tuning the dashboard

The metric names follow the IBM-published MSR Prometheus naming
convention (`sag_is_*` for IS-specific metrics, `jvm_*` for the
Micrometer JVM core). On real clusters, two things commonly need
adjustment:

- **`job` regex** — the dashboard's `job` template variable defaults to
  `.*wm.*`. If your Prometheus job label looks different (e.g. the
  ServiceMonitor produces `serviceMonitor/<ns>/<name>/<port-index>`),
  widen or replace the regex via the variable settings.
- **Quantile labels** — MSR exposes Summary metrics with `quantile`
  labels. The execution-time and JDBC-wait panels assume `0.5`, `0.95`,
  `0.99`. If your MSR build only emits `0.5` and `0.95` the `0.99`
  series simply renders empty — no error, just no line.

Once the first scrape lands, every panel should populate within
30 seconds (the default scrape interval). If a panel stays empty after
2 minutes, Section 4 below has the debug ladder.

---

## 4. Acceptance checklist

The Task 8.1 acceptance criterion is:

> Prometheus scrapes `wm-svc-dev:9999/metrics`; the dashboard imports
> cleanly and shows non-zero data within 2 min of deployment.

End-to-end smoke against a dev cluster:

```sh
# 1. Service is exposing metrics port
kubectl -n wm-dev get svc wm-svc-dev -o jsonpath='{.spec.ports[?(@.name=="metrics")]}'
# {"name":"metrics","port":9999,"protocol":"TCP","targetPort":"metrics"}

# 2. ServiceMonitor exists and selects the Service
kubectl -n wm-dev get servicemonitor wm-svc-dev -o yaml | yq '.spec.selector'
# matchLabels:
#   app.kubernetes.io/name: wm-microservice
#   app.kubernetes.io/instance: wm-svc-dev

# 3. Prometheus is actually scraping
kubectl -n monitoring port-forward svc/prometheus-operated 9090:9090 &
curl -fsS 'http://localhost:9090/api/v1/targets?state=active' \
  | jq '.data.activeTargets[] | select(.labels.service=="wm-svc-dev") | {scrapeUrl, health, lastScrape}'
# {
#   "scrapeUrl": "http://10.244.1.42:9999/metrics",
#   "health": "up",
#   "lastScrape": "2026-05-08T10:01:23.456Z"
# }

# 4. Sample MSR metric is non-zero (after even a single ping)
curl -fsS "http://localhost:9090/api/v1/query?query=sum(jvm_memory_used_bytes{job=~%22.*wm.*%22})" \
  | jq '.data.result[0].value[1]'
# "503316480"

# 5. Dashboard renders
xdg-open https://grafana.example.com/d/wm-msr-starter
```

### Debug ladder (target shows but panels are empty)

1. **Endpoint reachable from Prometheus pod?**
   `kubectl -n monitoring exec -it deploy/prometheus -- wget -qO- http://wm-svc-dev.wm-dev:9999/metrics | head`
2. **Metrics actually present?**
   `kubectl exec wm-svc-dev-0 -- curl -fsS http://localhost:9999/metrics | grep sag_is_`
   - If empty: `watt.server.prometheus.enabled` did not apply. Check
     `kubectl exec wm-svc-dev-0 -- cat /opt/softwareag/IntegrationServer/instances/default/config/server.cnf | grep prometheus`.
3. **Job label mismatch?**
   In Prometheus UI: `up{namespace="wm-dev"}` → note the `job` label,
   then update the dashboard's `job` template variable regex.
4. **Quantile labels mismatch?**
   `sag_is_service_execution_seconds` → look at the available
   `quantile=...` values; tweak panel queries accordingly.

---

## 5. References

- IBM webMethods MSR Prometheus endpoint:
  https://www.ibm.com/docs/en/webmethods-integration/wm-integration-server/12.1.0
- Prometheus Operator ServiceMonitor:
  https://prometheus-operator.dev/docs/operator/api/#servicemonitor
- Grafana dashboard JSON schema:
  https://grafana.com/docs/grafana/latest/dashboards/json-model/
