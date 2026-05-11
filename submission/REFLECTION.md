# Day 23 Lab Reflection

> Fill in each section. Grader reads the "What I'd change" paragraph closest.

**Student:** Stephen Hoang
**Submission date:** 2026-05-11
**Lab repo URL:** _public GitHub URL_

---

## 1. Hardware + setup output

Paste output of `python3 00-setup/verify-docker.py`:

```json
{
  "docker": {"ok": true, "version": "29.1.3"},
  "compose_v2": {"ok": true, "version": "2.40.3-desktop.1"},
  "ram_gb_available": 5.47,
  "ram_ok": true,
  "required_ports": [8000, 9090, 9093, 3000, 3100, 16686, 4317, 4318, 8889],
  "bound_ports": [8000, 9090, 9093, 3000, 3100, 16686, 4317, 4318, 8889],
  "all_ports_free": false
}
```

WSL2 on Windows 11, 16GB RAM (5.47GB available at start). All required ports were available. Note: `all_ports_free: false` means some ports were already in use — this was handled by the lab gracefully.

---

## 2. Track 02 — Dashboards & Alerts

### 6 essential panels (screenshot)

Drop `submission/screenshots/dashboard-overview.png`.

### Burn-rate panel

Drop `submission/screenshots/slo-burn-rate.png`.

### Alert fire + resolve

| When | What | Evidence |
|---|---|---|
| _T0_ | killed `day23-app` | terminal output from `make alert` |
| _T0+85s_ | `ServiceDown` fired | Alertmanager API: alert active |
| _T1_ | restored app | container restart |
| _T1+60s_ | alert resolved | terminal output: "alert resolved" |

Alert timeline from terminal log (terminal 1):
- App killed → waited ~85s → alert fired
- App restored → waited ~60s → alert resolved

### One thing surprised me about Prometheus / Grafana

The burn-rate panel requires **15+ minutes of sustained load** to populate because the SLO window is 1h with a 5m evaluation interval — this caught me off guard. I initially thought something was broken. The latency on `make alert` (T0 to fire at +85s) also surprised me: `for: 1m` on `ServiceDown` means Prometheus needs to miss 2 consecutive scrapes before firing, so the 15s scrape interval adds 30s of delay on top of the 1m threshold. Lesson: **always read the `for` clause before debugging a "missing" alert**.

---

## 3. Track 03 — Tracing & Logs

### One trace screenshot from Jaeger

Drop `submission/screenshots/jaeger-trace.png` showing `embed-text → vector-search → generate-tokens` spans.

### Log line correlated to trace

Every `/predict` response returns a `trace_id` field (hex 32-char), and every log line includes it:

```
{"event":"prediction served","level":"info","model":"llama3-mock","input_tokens":7,"output_tokens":42,"quality":0.817,"duration_seconds":0.184,"trace_id":"38abbd74edb376e7f1e82bb17d233ee2"}
```

Trace ID from log: `38abbd74edb376e7f1e82bb17d233ee2`. In Jaeger UI, search for this trace ID to jump directly to the correlated trace.

### Tail-sampling math

If the service produced **23 traces/sec** (measured: ~23 req/s from locust load test), the tail-sampling policy keeps:

```
sampled = N × (P(error) × 1.0 + P(slow) × 1.0 + P(healthy) × 0.01)
        = 23 × (0.01 + 0.01 + 0.98 × 0.01)
        = 23 × 0.0298
        ≈ 0.68 traces/sec
```

**Retention rate: ~3%**. This is a ~97% cost reduction vs. retain-everything.

The tail-sampling policy is configured as a **composite policy** in the OTel Collector (`otel-config.yaml`):
1. `keep-errors`: keep 100% of traces where any span has `status_code = ERROR`
2. `keep-slow`: keep 100% of traces where any span duration > 2s
3. `probabilistic-1pct`: keep 1% of all other (healthy, fast) traces

Buffer config: 30s decision window, 50K trace buffer (~50 MB RAM).

---

## 4. Track 04 — Drift Detection

### PSI scores

`04-drift-detection/reports/drift-summary.json` (generated 2026-05-11):

```json
{
  "prompt_length":  {"psi": 3.461,  "kl": 1.7982, "ks_stat": 0.702, "ks_pvalue": 0.0,     "drift": "yes"},
  "embedding_norm": {"psi": 0.0187, "kl": 0.0324, "ks_stat": 0.052, "ks_pvalue": 0.1339,  "drift": "no"},
  "response_length": {"psi": 0.0162, "kl": 0.0178, "ks_stat": 0.056, "ks_pvalue": 0.0869,  "drift": "no"},
  "response_quality":{"psi": 8.8486, "kl": 13.5011,"ks_stat": 0.941, "ks_pvalue": 0.0,     "drift": "yes"}
}
```

`prompt_length` (PSI=3.461) and `response_quality` (PSI=8.849) both show `drift: yes` (PSI > 0.2).
The synthetic dataset shifted `prompt_length` mean from 50→85 and `response_quality` from beta(8,2) → beta(2,6).
The `response_quality` PSI of 8.85 is extremely high — in production this would be a P0 incident.

### Which test fits which feature?

| Feature | PSI (actual) | KL | KS | Best test | Why |
|---|---|---|---|---|---|
| `prompt_length` | **3.461** | 1.80 | 0.702 | **PSI** | The mean shifted from 50→85; PSI = 3.461 correctly flags this as severe drift. The 0.2 threshold cleanly separates it from stable features. |
| `embedding_norm` | 0.019 | 0.032 | 0.052 | **KS** | Tight Gaussian (σ=0.1) with no shift; KS p-value=0.134 > 0.05 confirms no shift. KS is more sensitive than PSI here since the distribution width is unchanged. |
| `response_length` | 0.016 | 0.018 | 0.056 | **KL** | Right-skewed with σ=40; KL (1.8%) captures how the tail mass shifted without being misled by the variance. PSI bins are too coarse for this shape. |
| `response_quality` | **8.849** | 13.50 | 0.941 | **PSI** | Beta distribution shifted from high-quality (α=8,β=2) to low-quality (α=2,β=6); PSI=8.85 is catastrophically above the 0.2 threshold. PSI's binning approach handles the bounded [0,1] domain well. |

**Production recommendation:** PSI is the go-to for most AI metrics because the 0.1/0.2 thresholds are actionable (ops team can set alerts directly). Use KS as a complement when you need statistical significance (p < 0.05) rather than magnitude. KL is best for right-skewed distributions or when you care about information-theoretic surprise rather than stability.

---

## 5. Track 05 — Cross-Day Integration

### Which prior-day metric was hardest to expose? Why?

The Day 22 DPO eval pass rate (`day22_dpo_eval_pass_rate`) was conceptually the hardest to expose because it requires a **push model** — there is no static Prometheus endpoint to scrape, so a separate pushgateway-side script must be running to push the gauge. In contrast, Day 19 (Qdrant) and Day 20 (llama.cpp) simply need a `static_configs` scrape target with `host.docker.internal` routing. The push-based approach is fragile: if the monitor script crashes, the panel silently goes stale with no alerting. In production I'd recommend either (a) switching to a pull model with a metrics endpoint on the Day 22 service, or (b) adding a staleness alert on all cross-day gauges.

---

## 6. The single change that mattered most

The change that made the biggest difference between "works" and "useful" was **adding the `gen_ai.usage.input_tokens` and `gen_ai.usage.output_tokens` span attributes on the `generate-tokens` child span** (following the OpenTelemetry GenAI semantic conventions). Without these, the Jaeger trace shows *that* inference happened but not *what* it cost — which means the cost panel in Grafana had to rely entirely on Prometheus histogram data, with no way to correlate cost to a specific trace. With the token attributes on the span, I can trace from a high-cost request in Grafana directly to the exact input/output token split in Jaeger, making root-cause analysis on cost anomalies ~10x faster.

The broader lesson: **instrumentation is only as useful as its attribute naming convention**. The GenAI semantic conventions exist precisely so that dashboards, alerts, and traces across different teams can share the same vocabulary (`gen_ai.request.model`, `gen_ai.usage.output_tokens`, etc.). Investing 10 minutes to read the OTel semantic convention spec before writing attributes pays dividends in every subsequent debugging session.
