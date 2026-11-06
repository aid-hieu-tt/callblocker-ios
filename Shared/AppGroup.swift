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

    /// Thứ tự thử: App Group thực sự có trong provisioning profile (do công cụ ký tạo ra),
    /// rồi tới quy ước `group.<bundle id>` và ID gốc.
    static var candidateIdentifiers: [String] {
        var ids = ProvisioningProfile.embedded?.applicationGroups ?? []
        for id in ["group." + appBundleIdentifier, "group." + defaultAppBundleIdentifier] where !ids.contains(id) {
            ids.append(id)
        }
        return ids
    }

    enum ContainerError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            let profile = ProvisioningProfile.embedded
            let profileGroups = profile.map { $0.applicationGroups.isEmpty ? "không có" : $0.applicationGroups.joined(separator: ", ") }
                ?? "không đọc được profile"
            return "Không truy cập được App Group.\n"
                + "Bundle: \(Bundle.main.bundleIdentifier ?? "?")\n"
                + "App Group trong profile: \(profileGroups)\n"
                + "Đã thử: \(AppGroup.candidateIdentifiers.joined(separator: ", "))"
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

/// Đọc `embedded.mobileprovision` trong bundle (file CMS chứa plist dạng XML) để biết
/// entitlement thực tế mà công cụ ký đã cấp.
struct ProvisioningProfile {
    let applicationGroups: [String]
    let teamIdentifier: String?

    static let embedded: ProvisioningProfile? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>"),
              start.lowerBound < end.upperBound,
              let xml = String(text[start.lowerBound..<end.upperBound]).data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any]
        else { return nil }

        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        return ProvisioningProfile(
            applicationGroups: entitlements["com.apple.security.application-groups"] as? [String] ?? [],
            teamIdentifier: (plist["TeamIdentifier"] as? [String])?.first
        )
    }()
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
