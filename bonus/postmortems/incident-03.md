# Postmortem — Incident 03
**Severity:** SEV-1 (observability pipeline dead — mù hoàn toàn)
**Service:** Prometheus → `day23-app` scrape path
**Duration:** ~8 phút (chaos-controlled)
**Status:** RESOLVED — **thay đổi thật vào alert rule**

---

## 1. Timeline

| T+ | Sự kiện |
|---|---|
| T+00:00 | `03-throttle-prometheus.sh` — Prometheus bị disconnect khỏi app network |
| T+00:15 | Scrape fail → `up{job="day23-app"} = 0` |
| T+01:15 | `ServiceDown` FIRING — nhưng service vẫn chạy bình thường |
| T+01:17 | **Slack fire "ServiceDown"** ← T_detect |
| T+01:30 | On-call SSH: `curl http://localhost:8000/health` → 200 OK |
| T+01:35 | **Confusing:** alert nói service down, service đang chạy |
| T+02:00 | On-call kiểm tra Prometheus Targets page → scrape error |
| T+02:30 | On-call kiểm tra Docker networks → Prometheus không còn trong monitoring network |
| T+03:00 | **Root cause identified:** network partition |
| T+03:30 | `03-throttle-prometheus.sh --restore` |
| T+03:45 | `up = 1` quay lại |
| T+04:00 | Alert RESOLVED |
| **TTD** | **77 giây** |
| **TTM** | **15 giây** (sau khi xác định root cause) |
| **TTCD** | **210 giây** ← số quan trọng nhất |

TTCD = Time To Correct Diagnosis. 38% tổng thời gian incident là wasted diagnosis do alert misleading.

---

## 2. Detection

`ServiceDown` (`up == 0`) fire đúng kỹ thuật nhưng **misleading**: tên alert gợi ý "service process chết" trong khi thực tế là "scrape path bị blocked".

`up{job="day23-app"} == 0` đúng khi:
- (A) Service process chết
- (B) Network partition giữa Prometheus và service
- (C) Scrape config sai port/path

Alert không phân biệt 3 case → on-call mất 133 giây chạy diagnosis sai hướng.

**Gap nghiêm trọng hơn:** Nếu Prometheus tự chết, không có alert nào fire. Toàn bộ stack im lặng. On-call không biết là đang mù hay hệ thống thật sự ổn.

---

## 3. Mitigation

```bash
# Xác định network
docker inspect day23-prometheus \
  --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}'

# Reconnect
docker network connect <network_name> day23-prometheus

# Verify
# Prometheus UI > Status > Targets → day23-app phải hiện UP
```

---

## 4. Root Cause

**Immediate:** network disconnect (chaos script).

**Systemic:** `ServiceDown` alert không distinguish "service down" vs "scrape path down". Alert quality ảnh hưởng trực tiếp đến TTCD.

**Deeper:** Không có dead-man's switch. Nếu Prometheus crash, không có gì alert về việc mù.

---

## 5. Action Items

| Hành động | Loại | Trạng thái |
|---|---|---|
| Alert `TargetDown` tách biệt với label `reason="scrape_failure"` | Detect | **DONE** — `bonus/alert-patch/target-down-rule.yml` |
| Watchdog alert (dead-man's switch) | Prevent | **DONE** — trong file trên |
| Đổi tên `ServiceDown` → `MetricEndpointUnreachable` | Clarity | Backlog |
| Prometheus self-monitoring: `prometheus_target_scrape_pool_missed_scrapes_total` | Detect | Backlog |

**Kết quả sau patch:** Chạy lại chaos → Slack nhận "TargetDown" thay vì "ServiceDown". TTCD giảm từ 210 giây xuống < 30 giây.

---

## Ghi chú kỹ thuật

`up` metric chỉ đo "Prometheus có scrape được không", không đo "service có serving traffic không". Để đo service health thật:

```
up == 0 OR rate(inference_requests_total[5m]) == 0
```

Bắt được cả: (1) scrape fail, (2) service trả lời scrape nhưng không nhận traffic thật.
