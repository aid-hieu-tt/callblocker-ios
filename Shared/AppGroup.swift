import Foundation

/// Hằng số dùng chung giữa Main App và Call Directory Extension.
/// Đổi `com.yourcompany` thành bundle prefix thật (đồng bộ với `project.yml`).
enum AppGroup {
    static let identifier = "group.com.yourcompany.callblocker"
    static let extensionBundleIdentifier = "com.yourcompany.callblocker.CallDirectoryExtension"
    static let spamRefreshTaskIdentifier = "com.yourcompany.callblocker.spam-refresh"
    static let logSubsystem = "com.yourcompany.callblocker"

    enum ContainerError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "Không truy cập được App Group \(AppGroup.identifier). Kiểm tra entitlement của App và Extension."
        }
    }

    static func databaseURL() throws -> URL {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) else {
            throw ContainerError.unavailable
        }
        return container.appendingPathComponent("callblocker.sqlite")
    }
}

/// Kết quả lần nạp gần nhất do Extension ghi lại, App đọc để hiển thị.
struct CallDirectoryLoadSummary: Codable, Equatable {
    enum Mode: String, Codable { case full, incremental }

    var mode: Mode
    var blockedAdded: Int64 = 0
    var blockedRemoved: Int64 = 0
    var labelsLoaded: Int64 = 0
    var labelsReused = false
    var durationMs: Int = 0
    var finishedAt = Date()
}
