import Foundation

/// Hằng số dùng chung giữa Main App và Call Directory Extension.
/// Đổi `com.yourcompany` thành bundle prefix thật (đồng bộ với `project.yml`).
enum AppGroup {
    static let defaultAppBundleIdentifier = "com.yourcompany.callblocker"
    static let extensionSuffix = ".CallDirectoryExtension"
    static let spamRefreshTaskIdentifier = "com.yourcompany.callblocker.spam-refresh"
    static let logSubsystem = "com.yourcompany.callblocker"

    /// Bundle ID của Main App, suy ra lúc chạy. Công cụ sideload (Sideloadly, AltStore) thường đổi
    /// bundle ID khi ký lại bằng Apple ID miễn phí, nên không được gán cứng.
    static var appBundleIdentifier: String {
        let current = Bundle.main.bundleIdentifier ?? defaultAppBundleIdentifier
        return current.hasSuffix(extensionSuffix) ? String(current.dropLast(extensionSuffix.count)) : current
    }

    static var extensionBundleIdentifier: String { appBundleIdentifier + extensionSuffix }

    /// Quy ước `group.<bundle id của app>`; giữ ID gốc làm phương án dự phòng.
    static var candidateIdentifiers: [String] {
        var ids = ["group." + appBundleIdentifier]
        let original = "group." + defaultAppBundleIdentifier
        if !ids.contains(original) { ids.append(original) }
        return ids
    }

    enum ContainerError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "Không truy cập được App Group (\(AppGroup.candidateIdentifiers.joined(separator: ", "))). "
                + "Kiểm tra entitlement App Group của App và Extension."
        }
    }

    static func databaseURL() throws -> URL {
        for id in candidateIdentifiers {
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: id) {
                return container.appendingPathComponent("callblocker.sqlite")
            }
        }
        throw ContainerError.unavailable
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
