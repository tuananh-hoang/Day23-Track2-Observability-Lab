# Bonus Reflection — Provocation 5: Diễn tập Postmortem Thực Tế

## Bạn ngạc nhiên cái gì nhất trong quá trình Chaos Engineering?

Điều ngạc nhiên nhất không phải là hệ thống hỏng, mà là những rủi ro nằm ngoài kịch bản dự kiến và cách các công cụ phản ứng. Cụ thể:

1. **"Bơm độc" dữ liệu không dễ như tưởng tượng (Incident 02):** Ban đầu, script phá hoại thất bại vì pipeline thực tế đã chuyển sang dùng định dạng `.parquet` thay vì `.csv`. Sau khi sửa script dùng `pandas` để nạp độ lệch +3 sigma cho 1000 dòng, tôi lại phát hiện ra một bug trong `drift_detect.py`: nó tự động ghi đè dữ liệu sạch vào file `reference.parquet` trước khi tính toán! Điều này khiến hệ thống "tự chữa lành" ngay lập tức và biểu đồ không đổi. Phải sửa lại logic đọc file thì Drift Report mới bắt được đúng `PSI=3.461` (prompt_length) và `PSI=8.849` (response_quality), báo đỏ 4/4 cột. Bài học: *Data Pipeline lỏng lẻo nguy hiểm không kém gì model sai.*

2. **Network Partition gây mù lòa toàn diện (Incident 03):** Khi cắt mạng Prometheus bằng lệnh `docker network disconnect`, tôi nghĩ mình sẽ chụp được bảng báo đỏ "DOWN". Nhưng thực tế, tôi nhận được một trang trắng tinh báo lỗi `ERR_EMPTY_RESPONSE` trên trình duyệt! Lý do là Docker cắt luôn cả port-forwarding từ máy host. Sau khi tinh chỉnh lại, tôi mới bắt được khoảnh khắc các Targets báo lỗi `dial tcp: lookup app on 127.0.0.11:53: server misbehaving` (lỗi DNS do mất mạng). 
Cùng lúc đó, Alert mới được patch (`TargetDown`) đã báo về Slack rất chuẩn xác, thay vì báo lừa là `ServiceDown` như ban đầu. TTCD (Thời gian chẩn đoán đúng) nhờ đó giảm xuống chỉ còn vài chục giây thay vì vài phút mò mẫm.

## Nếu có thêm 8 giờ nữa bạn sẽ build cái gì tiếp?

1. **Bảo mật tính toàn vẹn cho Data Drift:** Từ sự cố Incident 02, tôi nhận ra ai cũng có thể ghi đè file `reference.parquet`. Tôi sẽ xây dựng cơ chế mã hóa checksum (SHA-256) cho tập reference. Nếu checksum bị thay đổi mà không thông qua quy trình chuẩn, hệ thống tự động bắn alert "Reference Data Corrupted" thay vì chạy báo cáo Drift sai lệch.
2. **Dead-man's switch hoàn chỉnh cho Prometheus:** Sự cố Incident 03 cho thấy khi Prometheus sập mạng, chúng ta gần như mù. Tôi sẽ cấu hình receiver trong Alertmanager để nhận tín hiệu `Watchdog` heartbeat mỗi 5 phút. Nếu im lặng quá 5 phút, Alertmanager (nếu chạy trên node/network khác) sẽ kích hoạt escalate: "Prometheus đã chết hoặc mất mạng - Đừng tin vào bảng điều khiển lúc này!".
3. **Phân loại mức độ Drift:** Hiện tại cứ PSI > 0.2 là báo đỏ. Tôi sẽ tách ra: `DriftWarning` (0.1 - 0.2) gửi vào kênh `#data-logs` để theo dõi, và `DriftCritical` (> 0.2) mới gửi chuông réo đội ngũ Data Scientist.

Bài học đắt giá nhất: *Một hệ thống Observability tốt là hệ thống biết tự báo cáo khi chính nó không còn đáng tin cậy.*
