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

## Finding ngoài kịch bản

Sau khi restore, `prompt_length` (PSI=3.461) và `response_quality` (PSI=8.849)
vẫn drift=yes. Reference dataset gốc của lab đã có sẵn distribution gap với
current data trước khi chaos inject. Đây là trạng thái "bình thường" của lab —
không phải do script gây ra.

Implication: alert `DataDriftDetected` đang fire liên tục trong production
mà không ai biết. Cần re-establish reference baseline từ current distribution
trước khi alert này có ý nghĩa thực tế.

## Finding ngoài kịch bản

Sau khi restore, `prompt_length` (PSI=3.461) và `response_quality` (PSI=8.849)
vẫn drift=yes. Reference dataset gốc của lab đã có sẵn distribution gap với
current data trước khi chaos inject. Đây là trạng thái "bình thường" của lab —
không phải do script gây ra.

Implication: alert `DataDriftDetected` đang fire liên tục trong production
mà không ai biết. Cần re-establish reference baseline từ current distribution
trước khi alert này có ý nghĩa thực tế.
