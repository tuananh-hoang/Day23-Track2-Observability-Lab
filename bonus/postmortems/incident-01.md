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
