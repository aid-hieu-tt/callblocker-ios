import CallKit
import Foundation
import UIKit

enum ExtensionStatus: Equatable {
    case unknown
    case enabled
    case disabled
}

/// Bọc `CXCallDirectoryManager` (FR-01, FR-04).
struct CallDirectoryService {
    private var manager: CXCallDirectoryManager { .sharedInstance }

    /// BR-01
    func status() async -> ExtensionStatus {
        await withCheckedContinuation { continuation in
            manager.getEnabledStatusForExtension(withIdentifier: AppGroup.extensionBundleIdentifier) { status, error in
                if error != nil {
                    continuation.resume(returning: .unknown)
                    return
                }
                switch status {
                case .enabled: continuation.resume(returning: .enabled)
                case .disabled: continuation.resume(returning: .disabled)
                default: continuation.resume(returning: .unknown)
                }
            }
        }
    }

    /// BR-02: iOS 13.4+ mở thẳng màn "Chặn cuộc gọi & nhận dạng"; fallback về trang Cài đặt của app.
    @MainActor
    func openSettings() async {
        let opened: Bool = await withCheckedContinuation { continuation in
            manager.openSettings { error in continuation.resume(returning: error == nil) }
        }
        if !opened, let url = URL(string: UIApplication.openSettingsURLString) {
            await UIApplication.shared.open(url)
        }
    }

    func reload() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.reloadExtension(withIdentifier: AppGroup.extensionBundleIdentifier) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    static func describe(_ error: Error) -> String {
        guard let callKitError = error as? CXErrorCodeCallDirectoryManagerError else {
            return error.localizedDescription
        }
        switch callKitError.code {
        case .extensionDisabled:
            return "Tiện ích chặn cuộc gọi đang tắt trong Cài đặt."
        case .noExtensionFound:
            return "Không tìm thấy Call Directory Extension (kiểm tra bundle identifier)."
        case .loadingInterrupted:
            return "Quá trình nạp bị gián đoạn (có thể do vượt giới hạn bộ nhớ). Hãy thử lại."
        case .entriesOutOfOrder:
            return "Dữ liệu không theo thứ tự tăng dần."
        case .duplicateEntries:
            return "Dữ liệu có số trùng lặp."
        case .maximumEntriesExceeded:
            return "Vượt quá số lượng tối đa iOS cho phép. Hãy tắt bớt quy tắc."
        case .currentlyLoading:
            return "Đang nạp dữ liệu, vui lòng đợi."
        case .unexpectedIncrementalRemoval:
            return "Dữ liệu đồng bộ lệch với hệ thống."
        default:
            return callKitError.localizedDescription
        }
    }
}
