# CallBlocker — iOS Call Blocker theo quy tắc

Triển khai theo tài liệu BRD/SRS v1.0. iOS 15+, Swift / SwiftUI, CallKit Call Directory Extension.

## Cấu trúc

```
project.yml                         XcodeGen spec (App + Extension + App Group)
Packages/CallBlockerCore/           Logic thuần Swift, test được bằng `swift test`
  PhoneNormalizer.swift             BR-03 chuẩn hoá 0… -> 84…
  PatternParser.swift               FR-02, BR-04 (≤ 5 ký tự đại diện), mẫu -> dải số
  IntervalStreams.swift             BR-05/06/07: gộp dải, trừ whitelist, diff — streaming O(1) RAM
Shared/                             Biên dịch vào cả App và Extension
  SQLiteDatabase.swift              Wrapper SQLite C API (không thư viện ngoài)
  BlockDatabase.swift               Lược đồ App Group DB + các cursor cho Extension
  AppGroup.swift                    Hằng số identifier
CallDirectoryExtension/
  CallDirectoryHandler.swift        FR-04: nạp full / incremental + Caller ID
App/
  AppModel.swift                    State + điều phối reload CallKit
  Services/                         CallKit, Danh bạ (on-device), đồng bộ số rác, BGTask
  Views/                            Onboarding, Quy tắc, Thêm quy tắc, Danh sách trắng, Số rác
```

## Build (cần macOS + Xcode 15+)

```bash
brew install xcodegen
xcodegen generate
open CallBlocker.xcodeproj
```

1. Đổi `com.yourcompany` trong `project.yml` **và** `Shared/AppGroup.swift`; điền `DEVELOPMENT_TEAM`.
2. Tạo App Group `group.<prefix>.callblocker` trên Apple Developer và bật cho cả hai target.
3. Thay `SpamListService.endpoint` bằng API thật.
4. Test logic lõi: `cd Packages/CallBlockerCore && swift test`.

## Luồng dữ liệu

```
Người dùng nhập "024 8888 xxxx"
  -> PatternParser: "84248888xxxx", 10.000 số, dải [842488880000, 842488889999]
  -> block_rules (1 dòng) + block_ranges (1 dòng)
  -> CXCallDirectoryManager.reloadExtension
Extension:
  SELECT start,end FROM block_ranges WHERE is_active=1 ORDER BY start   (partial covering index)
    -> MergedIntervals (gộp chồng lấn/liền kề giữa các quy tắc)
    -> IntervalsExcludingPoints (hai con trỏ với whitelist đã sắp xếp)
    -> vòng for từng số, lô 5.000 trong autoreleasepool -> addBlockingEntry
```

**Incremental (BR-07):** sau mỗi lần nạp thành công, Extension lưu ảnh chụp các dải hiệu lực vào
`synced_blocking`. Lần sau nếu `context.isIncremental`, nó chỉ gửi `snapshot \ hiện tại` (remove) và
`hiện tại \ snapshot` (add) — sửa một quy tắc 10.000 số chỉ tốn ~10.000 lệnh thay vì nạp lại tất cả.
Snapshot chỉ được commit trong `completeRequest` khi không `expired`. Nếu iOS báo
`unexpectedIncrementalRemoval`, App tự đánh dấu snapshot hỏng và gọi lại -> Extension `removeAll` + nạp toàn phần.
Nhãn Caller ID dùng `labels_version`: không đổi thì bỏ qua hoàn toàn.

## Những điểm khác / bổ sung so với tài liệu

| Tài liệu | Triển khai | Lý do |
|---|---|---|
| Pseudocode 6.3 nạp `ranges` và `whitelist` thành mảng/Set trên RAM, không gộp giữa các quy tắc | Đọc thẳng từ cursor SQLite, gộp + trừ whitelist dạng streaming | Hai quy tắc chồng nhau sẽ sinh số trùng -> CallKit trả `duplicateEntries`; Set whitelist lớn (danh bạ) tốn RAM |
| `pattern_display` nằm trong `block_ranges` | Tách `block_rules` (1 quy tắc) và `block_ranges` (N dải) | Dải sau khi gộp không còn thuộc về 1 quy tắc; bật/tắt quy tắc không phải tính lại |
| BR-04 "4 đến 5" ký tự đại diện | Chốt **5** (`PatternParser.defaultMaxWildcards`) | Có thể đổi 1 hằng số |
| Chỉ mô tả ký tự đại diện ở cuối | Hỗ trợ cả ở giữa (`02488x8888x` -> 10 dải) | Vẫn bị giới hạn tổng 10^5 số |
| BR-07 không nói cách tính phần thay đổi | Diff dựa trên snapshot `synced_blocking` | Cần biết chính xác iOS đang giữ gì để `removeBlockingEntry` không lỗi |
| — | Số `1900…`/`1800…` không có số 0 đầu -> thêm `84` | Cần xác nhận với dữ liệu caller ID thực tế từ nhà mạng |

## Cần kiểm tra trên thiết bị thật (chưa xác minh được trong môi trường này)

- Code Swift **chưa được biên dịch** (soạn trên Windows). Thuật toán lõi đã được kiểm chứng bằng bản port Python
  so với brute-force (20.000 lần thử ngẫu nhiên), và có XCTest đi kèm cho `swift test`.
- NFR-1 (< 12 MB): đo bằng Xcode › Debug Navigator / Instruments Allocations khi attach vào process extension.
- NFR-2: thời gian nạp 100k / 1M số hiển thị ngay trong tab Quy tắc (`last_load_summary`).
- Hiển thị nhãn Caller ID và số 1900 trên mạng Việt Nam.
