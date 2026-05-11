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
