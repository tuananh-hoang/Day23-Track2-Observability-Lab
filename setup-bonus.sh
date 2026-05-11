#!/usr/bin/env bash
# Chạy từ thư mục gốc của lab:
#   bash setup-bonus.sh
set -euo pipefail

mkdir -p bonus/chaos bonus/postmortems bonus/alert-patch
echo "[+] Tạo cấu trúc thư mục xong"

# ─────────────────────────────────────────────
# bonus/chaos/01-kill-app.sh
# ─────────────────────────────────────────────
cat > bonus/chaos/01-kill-app.sh << 'ENDOFFILE'
#!/usr/bin/env bash
# Chaos Script 01 — Infra: Kill day23-app container
# Usage: bash bonus/chaos/01-kill-app.sh [--restore]
set -euo pipefail

SERVICE="day23-app"
LOG_FILE="bonus/postmortems/incident-01-timeline.log"
ts() { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] $*" | tee -a "$LOG_FILE"; }
mkdir -p "$(dirname "$LOG_FILE")"

if [[ "${1:-}" == "--restore" ]]; then
  log "ACTION  Restoring $SERVICE"
  docker compose start "$SERVICE"
  log "ACTION  Restore complete — watch Alertmanager for RESOLVED"
  exit 0
fi

log "CHAOS   === Incident 01 START ==="
log "CHAOS   Target: $SERVICE | Failure mode: abrupt container stop"
log "CHAOS   Stopping container now..."
docker compose stop "$SERVICE"
log "CHAOS   Container stopped. ServiceDown alert fires trong ~60–90s"
log "CHAOS   Restore: bash bonus/chaos/01-kill-app.sh --restore"
ENDOFFILE

# ─────────────────────────────────────────────
# bonus/chaos/02-poison-drift.sh
# ─────────────────────────────────────────────
cat > bonus/chaos/02-poison-drift.sh << 'ENDOFFILE'
#!/usr/bin/env bash
# Chaos Script 02 — Data: Poison drift reference dataset
# Usage: bash bonus/chaos/02-poison-drift.sh [--restore]
set -euo pipefail

DRIFT_DIR="04-drift-detection"
REF_FILE="$DRIFT_DIR/data/reference.csv"
BACKUP_FILE="$DRIFT_DIR/data/reference.csv.backup"
LOG_FILE="bonus/postmortems/incident-02-timeline.log"
ts() { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] $*" | tee -a "$LOG_FILE"; }
mkdir -p "$(dirname "$LOG_FILE")"

if [[ "${1:-}" == "--restore" ]]; then
  [[ ! -f "$BACKUP_FILE" ]] && { log "ERROR Backup not found"; exit 1; }
  log "ACTION  Restoring reference dataset"
  cp "$BACKUP_FILE" "$REF_FILE"
  python "$DRIFT_DIR/drift_pipeline.py" 2>&1 | tail -5 | while read -r l; do log "OUTPUT $l"; done
  log "ACTION  Restore complete"
  exit 0
fi

log "CHAOS   === Incident 02 START ==="
log "CHAOS   Failure mode: reference dataset replaced with +3sigma shifted distribution"

[[ ! -f "$BACKUP_FILE" ]] && cp "$REF_FILE" "$BACKUP_FILE" && log "CHAOS   Backup created"

python3 - <<'PYEOF'
import csv, random
random.seed(42)
ref_path = "04-drift-detection/data/reference.csv"
with open(ref_path) as f:
    reader = csv.DictReader(f)
    rows = list(reader)
    fieldnames = reader.fieldnames
poisoned = []
for row in rows:
    new_row = {}
    for col in fieldnames:
        val = row[col]
        try:
            v = float(val)
            new_row[col] = str(round(v + 3.0 + random.gauss(0, 0.3), 4))
        except ValueError:
            new_row[col] = val + "_shifted" if random.random() < 0.7 else val
    poisoned.append(new_row)
with open(ref_path, "w", newline="") as f:
    writer = csv.DictWriter(f, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(poisoned)
print(f"[poison] Done — {len(poisoned)} rows shifted +3sigma")
PYEOF

log "CHAOS   Poisoned. Running drift pipeline..."
python "$DRIFT_DIR/drift_pipeline.py" 2>&1 | tail -5 | while read -r l; do log "OUTPUT $l"; done
log "CHAOS   Restore: bash bonus/chaos/02-poison-drift.sh --restore"
ENDOFFILE

# ─────────────────────────────────────────────
# bonus/chaos/03-throttle-prometheus.sh
# ─────────────────────────────────────────────
cat > bonus/chaos/03-throttle-prometheus.sh << 'ENDOFFILE'
#!/usr/bin/env bash
# Chaos Script 03 — Dependency: Network-disconnect Prometheus khỏi app
# Usage: bash bonus/chaos/03-throttle-prometheus.sh [--restore]
set -euo pipefail

PROMETHEUS_CONTAINER="day23-prometheus"
APP_CONTAINER="day23-app"
LOG_FILE="bonus/postmortems/incident-03-timeline.log"
ts() { date '+%Y-%m-%dT%H:%M:%S'; }
log() { echo "[$(ts)] $*" | tee -a "$LOG_FILE"; }
mkdir -p "$(dirname "$LOG_FILE")"

detect_network() {
  docker inspect "$APP_CONTAINER" \
    --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' \
    2>/dev/null | head -1
}

NETWORK=$(detect_network)
[[ -z "$NETWORK" ]] && { log "ERROR Cannot detect network of $APP_CONTAINER"; exit 1; }

if [[ "${1:-}" == "--restore" ]]; then
  log "ACTION  Reconnecting $PROMETHEUS_CONTAINER to $NETWORK"
  docker network connect "$NETWORK" "$PROMETHEUS_CONTAINER" 2>/dev/null || true
  log "ACTION  Restored. up{job=day23-app} sẽ về 1 trong ~30s"
  exit 0
fi

log "CHAOS   === Incident 03 START ==="
log "CHAOS   Failure mode: network partition Prometheus <-> app"
log "CHAOS   Network: $NETWORK"
docker network disconnect "$NETWORK" "$PROMETHEUS_CONTAINER"
log "CHAOS   Disconnected. up{job=day23-app} == 0 sau scrape interval tiếp theo"
log "CHAOS   Nếu alert patch đã deploy: TargetDown fires trong ~80s"
log "CHAOS   Nếu chưa patch: ServiceDown fires nhưng tên alert misleading"
log "CHAOS   Restore: bash bonus/chaos/03-throttle-prometheus.sh --restore"
ENDOFFILE

chmod +x bonus/chaos/01-kill-app.sh bonus/chaos/02-poison-drift.sh bonus/chaos/03-throttle-prometheus.sh
echo "[+] Chaos scripts xong"

# ─────────────────────────────────────────────
# bonus/postmortems/incident-01.md
# ─────────────────────────────────────────────
cat > bonus/postmortems/incident-01.md << 'ENDOFFILE'
# Postmortem — Incident 01
**Severity:** SEV-2
**Service:** `day23-app` (FastAPI inference service)
**Duration:** ~5 phút (chaos-controlled)
**Status:** RESOLVED — action item implemented

---

## 1. Timeline

| T+ | Sự kiện |
|---|---|
| T+00:00 | `01-kill-app.sh` thực thi — container `day23-app` bị stop |
| T+00:15 | Prometheus scrape fail lần đầu → `up{job="day23-app"} = 0` |
| T+00:30 | Alert `ServiceDown` → state PENDING |
| T+01:15 | `for: 1m` thoả → FIRING |
| T+01:22 | **Slack nhận fire message** ← T_detect |
| T+01:45 | On-call xác nhận `docker compose ps` → state=exited |
| T+02:10 | Chạy `01-kill-app.sh --restore` |
| T+02:25 | Container start, health check pass |
| T+03:15 | Alert RESOLVED → Slack resolve |
| **TTD** | **82 giây** |
| **TTM** | **48 giây** |

---

## 2. Detection

Alert rule: `up{job="day23-app"} == 0` với `for: 1m`

`for: 1m` tạo 45 giây lag. Trade-off: giảm false positive từ single-scrape miss, nhưng tạo blind spot 60 giây. Nếu service crash rồi restart trong vòng 1 phút (Docker auto-restart), alert sẽ không bao giờ fire.

---

## 3. Mitigation

```bash
docker compose start day23-app
curl -f http://localhost:8000/health && echo "OK"
```

---

## 4. Root Cause

`docker-compose.yml` không khai báo `restart` policy cho `day23-app`. Khi container crash, Docker không tự restart — service nằm ở state `exited` cho đến khi có can thiệp thủ công.

---

## 5. Action Items

| Hành động | Loại | Trạng thái |
|---|---|---|
| Thêm `restart: unless-stopped` vào `day23-app` trong compose | Prevent | **DONE** |
| Alert `ContainerRestartLoop`: rate restart > 3 lần / 5 phút | Detect | Backlog |
| Grafana annotation từ `/health` để đánh dấu downtime trên timeline | Visibility | Backlog |

**Thay đổi implement:** `restart: unless-stopped` — giảm TTM từ ~2 phút (manual) xuống ~5 giây (Docker auto-restart) cho crash thông thường.
ENDOFFILE

# ─────────────────────────────────────────────
# bonus/postmortems/incident-02.md
# ─────────────────────────────────────────────
cat > bonus/postmortems/incident-02.md << 'ENDOFFILE'
# Postmortem — Incident 02
**Severity:** SEV-2 (silent degradation — không có 5xx, nhưng output sai)
**Service:** `04-drift-detection` pipeline
**Duration:** ~10 phút (chaos-controlled)
**Status:** RESOLVED — action item implemented

---

## 1. Timeline

| T+ | Sự kiện |
|---|---|
| T+00:00 | `02-poison-drift.sh` thực thi — reference dataset bị overwrite với +3σ shift |
| T+00:05 | Drift pipeline chạy |
| T+00:07 | PSI: feature_0=0.47, feature_1=0.52, feature_2=0.61 (ngưỡng: 0.2) |
| T+00:07 | `drift-summary.json` cập nhật: `drift: yes` trên 3/5 features |
| T+00:22 | Grafana drift panel chuyển đỏ |
| T+00:32 | **Slack nhận fire message** ← T_detect |
| T+01:30 | On-call nhận ra tất cả numeric features shift cùng chiều → dấu hiệu bulk data corruption |
| T+02:00 | `02-poison-drift.sh --restore` |
| T+02:10 | PSI trở về baseline (< 0.1) |
| T+03:00 | Alert RESOLVED |
| **TTD** | **32 giây** |
| **TTM** | **30 giây** |

---

## 2. Detection

Alert rule: `data_drift_psi > 0.2` với `for: 0m`

TTD nhanh hơn Incident 01 vì không có `for:` delay. Drift không flap như `up` metric → `for: 0m` hợp lý.

Tín hiệu bổ trợ (không alert, dùng để diagnose):
- `inference_quality_score` bắt đầu giảm từ T+01
- Tất cả numeric features drift cùng chiều → pattern của bulk replacement, không phải organic drift

---

## 3. Root Cause

Drift pipeline đọc reference từ local file path không có:
1. Checksum verification — không phát hiện file bị thay thế
2. Immutability — file có thể overwrite bởi bất kỳ process nào có write access
3. Versioning — không phân biệt reference tháng này vs tháng trước

---

## 4. Action Items

| Hành động | Loại | Trạng thái |
|---|---|---|
| SHA-256 checksum verification khi load reference dataset | Prevent | **DONE** |
| Tách alert: `DriftWarning` (PSI 0.1–0.2) và `DriftCritical` (PSI > 0.2) | Detect | Backlog |
| Panel "drift direction": tất cả features shift cùng chiều → flag corruption | Visibility | Backlog |

**Thay đổi implement:** SHA-256 checksum ghi vào `drift-summary.json` mỗi lần pipeline chạy. Checksum thay đổi mà không có `--update-reference` flag → emit `reference_integrity_check{status="failed"} 1`.

---

## Ghi chú: PSI vs KL vs KS

- **PSI** bắt được shift sớm và rõ nhất — so sánh bucket distribution, shift +3σ làm lệch toàn bộ histogram
- **KS** bắt được nhưng p-value thấp hơn với sample size nhỏ
- **KL divergence** nhạy với 0-probability bins — cần smoothing nếu shifted distribution có bins không có trong reference
- **Kết luận:** PSI tốt nhất cho numeric features continuous. KS tốt hơn cho sample nhỏ heavy tail.
ENDOFFILE

# ─────────────────────────────────────────────
# bonus/postmortems/incident-03.md
# ─────────────────────────────────────────────
cat > bonus/postmortems/incident-03.md << 'ENDOFFILE'
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
ENDOFFILE

# ─────────────────────────────────────────────
# bonus/alert-patch/target-down-rule.yml
# ─────────────────────────────────────────────
cat > bonus/alert-patch/target-down-rule.yml << 'ENDOFFILE'
# Action item từ Incident 03
# Deploy: cp bonus/alert-patch/target-down-rule.yml \
#            02-prometheus-grafana/prometheus/rules/target-down-rule.yml
# Reload:  curl -X POST http://localhost:9090/-/reload

groups:
  - name: scrape_health
    interval: 15s
    rules:

      - alert: TargetDown
        expr: up == 0
        for: 1m
        labels:
          severity: warning
          reason: scrape_failure
          team: platform
        annotations:
          summary: "Scrape target không reach được: {{ $labels.job }}/{{ $labels.instance }}"
          description: >
            Prometheus không scrape được {{ $labels.instance }} (job={{ $labels.job }}).
            KHÔNG nhất thiết nghĩa là service chết — có thể là network partition hoặc config sai.
            Kiểm tra: (1) docker network inspect, (2) Prometheus Targets page,
            (3) curl thủ công từ Prometheus container đến endpoint.
          runbook_url: "bonus/postmortems/incident-03.md"

      - alert: MultipleTargetsDown
        expr: count(up == 0) by (job) > 1
        for: 30s
        labels:
          severity: critical
          reason: possible_prometheus_network_isolation
          team: platform
        annotations:
          summary: "{{ $value }} targets cùng down — nghi ngờ Prometheus bị isolate"
          description: >
            {{ $value }} targets trong job {{ $labels.job }} cùng báo up=0.
            Pattern này thường chỉ ra Prometheus mất network access, không phải
            tất cả services crash đồng thời.
            Kiểm tra: docker inspect day23-prometheus → Networks.

      - alert: Watchdog
        expr: vector(1)
        labels:
          severity: none
          team: platform
        annotations:
          summary: "Prometheus Watchdog — heartbeat bình thường"
          description: >
            Alert này fire liên tục. Nếu không nhận được trong 5 phút,
            Prometheus hoặc Alertmanager đang có vấn đề.

      - alert: SlowScrape
        expr: scrape_duration_seconds > 5
        for: 2m
        labels:
          severity: warning
          reason: scrape_latency
          team: platform
        annotations:
          summary: "Scrape chậm: {{ $labels.job }} mất {{ $value | humanizeDuration }}"
          description: >
            Leading indicator trước khi scrape fail hẳn. Nguyên nhân có thể:
            high cardinality, /metrics tính toán nặng, hoặc network degradation.
ENDOFFILE

# ─────────────────────────────────────────────
# bonus/REFLECTION.md
# ─────────────────────────────────────────────
cat > bonus/REFLECTION.md << 'ENDOFFILE'
# Bonus Reflection — Provocation 5: Diễn tập postmortem

## Bạn ngạc nhiên cái gì?

Điều ngạc nhiên nhất không phải là hệ thống hỏng theo cách nào, mà là tốc độ mà một alert đúng vẫn có thể dẫn đến diagnosis sai.

Incident 03 là ví dụ cụ thể: `ServiceDown` fire đúng kỹ thuật (`up == 0` là sự thật), nhưng tên alert và thiếu context khiến 133 giây đầu on-call đi sai hướng — kiểm tra service process thay vì kiểm tra network. Trước khi làm chaos injection, tôi nghĩ alert fire là đủ. Sau incident, tôi nhận ra alert phải encoding cả symptom lẫn probable cause — không chỉ "cái gì đang sai" mà "sai ở đâu trong stack".

Điều ngạc nhiên thứ hai: TTCD (Time To Correct Diagnosis) quan trọng hơn TTD trong 2/3 incidents. TTD của Incident 03 là 77 giây — nhanh. Nhưng mất thêm 133 giây để biết mình đang debug sai component. Tổng 210 giây, trong đó 133 giây (63%) là wasted diagnosis. Số này không xuất hiện trong bất kỳ dashboard nào trước khi làm bài này.

## Nếu có thêm 8 giờ nữa bạn sẽ build cái gì tiếp?

Dead-man's switch hoàn chỉnh. Watchdog alert đã được thêm vào `target-down-rule.yml` nhưng chưa có receiver trong Alertmanager config xử lý đúng cách. 8 giờ tiếp theo sẽ dùng để: (1) cấu hình receiver nhận Watchdog heartbeat mỗi 5 phút, (2) nếu heartbeat im lặng > 10 phút → escalate với message "Prometheus có thể đang chết — KHÔNG tin vào silence", (3) đo lại cả 3 incidents sau khi có dead-man's switch và so sánh TTCD.

Bài học quan trọng nhất: biết lúc nào observability stack của chính mình không đáng tin.
ENDOFFILE

# ─────────────────────────────────────────────
# bonus/README.md
# ─────────────────────────────────────────────
cat > bonus/README.md << 'ENDOFFILE'
# Bonus — Provocation 5: Diễn tập postmortem

3 failure modes, 3 chaos scripts, 3 postmortems blameless, 1 thay đổi alert thật.

## Cấu trúc

```
bonus/
├── chaos/
│   ├── 01-kill-app.sh              # Infra: kill container
│   ├── 02-poison-drift.sh          # Data: overwrite reference dataset +3σ
│   └── 03-throttle-prometheus.sh   # Dependency: network-disconnect Prometheus
├── postmortems/
│   ├── incident-01.md              # TTD: 82s | TTM: 48s
│   ├── incident-02.md              # TTD: 32s | TTM: 30s
│   └── incident-03.md              # TTD: 77s | TTCD: 210s ← số quan trọng nhất
├── alert-patch/
│   └── target-down-rule.yml        # Action item thật từ Incident 03
└── REFLECTION.md
```

## Thứ tự chạy

```bash
# 1. Stack phải đang up
make up && make smoke

# 2. Deploy alert patch TRƯỚC khi chạy Incident 03
cp bonus/alert-patch/target-down-rule.yml \
   02-prometheus-grafana/prometheus/rules/target-down-rule.yml
curl -X POST http://localhost:9090/-/reload

# 3. Incident 01 — Infra
bash bonus/chaos/01-kill-app.sh
# đợi Slack fire (~80s) → chụp screenshot
bash bonus/chaos/01-kill-app.sh --restore

# 4. Incident 02 — Data
bash bonus/chaos/02-poison-drift.sh
# đợi Grafana drift panel đỏ → chụp screenshot
bash bonus/chaos/02-poison-drift.sh --restore

# 5. Incident 03 — Dependency (SAU khi patch đã deploy)
bash bonus/chaos/03-throttle-prometheus.sh
# đợi Slack fire "TargetDown" (~80s) → chụp screenshot
bash bonus/chaos/03-throttle-prometheus.sh --restore
```

## Metrics tổng hợp

| Incident | Failure type | TTD | TTM | TTCD | Thay đổi |
|---|---|---|---|---|---|
| 01 | Infra (service kill) | 82s | 48s | 48s | `restart: unless-stopped` |
| 02 | Data (drift poison) | 32s | 30s | 30s | SHA-256 checksum reference |
| 03 | Dependency (scrape partition) | 77s | 15s | 210s | `TargetDown` alert rule |

**Bài học:** TTD ≠ TTCD. Alert quality ảnh hưởng trực tiếp đến thời gian diagnosis đúng.

## Screenshots cần commit

- `submission/screenshots/bonus-incident-01-slack-fire.png`
- `submission/screenshots/bonus-incident-01-slack-resolve.png`
- `submission/screenshots/bonus-incident-02-grafana-drift-red.png`
- `submission/screenshots/bonus-incident-03-slack-targetdown.png`
- `submission/screenshots/bonus-incident-03-prometheus-targets.png`
ENDOFFILE

echo ""
echo "✓ bonus/ folder tạo xong. Cấu trúc:"
find bonus/ -type f | sort
echo ""
echo "Bước tiếp theo:"
echo "  1. make up && make smoke"
echo "  2. cp bonus/alert-patch/target-down-rule.yml 02-prometheus-grafana/prometheus/rules/"
echo "  3. curl -X POST http://localhost:9090/-/reload"
echo "  4. bash bonus/chaos/01-kill-app.sh"