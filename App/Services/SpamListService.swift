import BackgroundTasks
import Foundation
import os
import CallBlockerCore

private let log = Logger(subsystem: AppGroup.logSubsystem, category: "SpamSync")

/// FR-05: tải danh sách số rác cộng đồng từ server và lưu vào `spam_labels`.
///
/// Định dạng JSON mong đợi:
/// ```json
/// { "version": "2026-11-05T00:00:00Z",
///   "entries": [ { "phone": "0889123456", "label": "Lừa đảo" } ] }
/// ```
/// Request chỉ là GET thuần, không kèm dữ liệu cá nhân / danh bạ của người dùng.
struct SpamListService {
    /// TODO: thay bằng endpoint thật.
    static let endpoint = URL(string: "https://api.yourcompany.com/v1/spam-numbers")!
    static let maxLabelLength = 40

    struct Response: Decodable {
        struct Entry: Decodable {
            let phone: String
            let label: String
        }
        let version: String
        let entries: [Entry]
    }

    var session: URLSession = .shared

    /// Tải và thay thế danh sách. Trả về số bản ghi hợp lệ đã lưu.
    @discardableResult
    func refresh(into database: BlockDatabase) async throws -> Int {
        var request = URLRequest(url: Self.endpoint)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)

        // CallKit yêu cầu số tăng dần & không trùng -> chuẩn hoá, khử trùng (giữ nhãn đầu tiên), sắp xếp.
        var byNumber: [Int64: String] = [:]
        byNumber.reserveCapacity(decoded.entries.count)
        for entry in decoded.entries {
            guard let number = PhoneNormalizer.normalize(entry.phone) else { continue }
            let label = Self.formatLabel(entry.label)
            guard !label.isEmpty, byNumber[number] == nil else { continue }
            byNumber[number] = label
        }
        let sorted = byNumber.sorted { $0.key < $1.key }.map { (number: $0.key, label: $0.value) }
        try database.replaceSpamLabels(sorted, listVersion: decoded.version)
        log.info("Spam list \(decoded.version, privacy: .public): \(sorted.count) entries")
        return sorted.count
    }

    /// `Lừa đảo` -> `[ Lừa đảo ]` (định dạng nhãn trong tài liệu FR-05).
    static func formatLabel(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let core = trimmed.hasPrefix("[") ? trimmed : "[ \(trimmed) ]"
        return String(core.prefix(maxLabelLength))
    }
}

/// Đồng bộ định kỳ bằng `BGAppRefreshTask` (iOS tự quyết định thời điểm chạy thực tế).
enum SpamRefreshScheduler {
    static let interval: TimeInterval = 12 * 60 * 60

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppGroup.spamRefreshTaskIdentifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(refreshTask)
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: AppGroup.spamRefreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            log.error("Cannot schedule spam refresh: \(String(describing: error), privacy: .public)")
        }
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule() // lên lịch lần kế tiếp
        let work = Task {
            do {
                let database = try BlockDatabase.openShared(role: .app)
                guard try database.isSpamEnabled() else {
                    task.setTaskCompleted(success: true)
                    return
                }
                try await SpamListService().refresh(into: database)
                try await CallDirectoryService().reload()
                task.setTaskCompleted(success: true)
            } catch {
                log.error("Background spam refresh failed: \(String(describing: error), privacy: .public)")
                task.setTaskCompleted(success: false)
            }
        }
        task.expirationHandler = { work.cancel() }
    }
}
