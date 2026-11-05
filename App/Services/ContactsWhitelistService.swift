import Contacts
import Foundation
import CallBlockerCore

/// FR-03 / NFR-3: đọc số trong Danh bạ để đưa vào whitelist.
/// Dữ liệu danh bạ **chỉ xử lý trên thiết bị**, không bao giờ gửi lên server (App Store Guideline 5.1).
enum ContactsWhitelistService {
    enum ContactsError: LocalizedError {
        case accessDenied
        var errorDescription: String? {
            "Ứng dụng chưa được cấp quyền Danh bạ. Vào Cài đặt > Quyền riêng tư > Danh bạ để bật."
        }
    }

    static var isAuthorized: Bool {
        CNContactStore.authorizationStatus(for: .contacts) == .authorized
    }

    /// Trả về danh sách số đã chuẩn hoá `84…`, tăng dần, không trùng.
    static func collectNormalizedNumbers() async throws -> [Int64] {
        let granted = try await CNContactStore().requestAccess(for: .contacts)
        guard granted else { throw ContactsError.accessDenied }

        return try await Task.detached(priority: .userInitiated) {
            let store = CNContactStore()
            let request = CNContactFetchRequest(keysToFetch: [CNContactPhoneNumbersKey as CNKeyDescriptor])
            request.unifyResults = false
            var numbers = Set<Int64>()
            try store.enumerateContacts(with: request) { contact, _ in
                for labeled in contact.phoneNumbers {
                    if let normalized = PhoneNormalizer.normalize(labeled.value.stringValue) {
                        numbers.insert(normalized)
                    }
                }
            }
            return numbers.sorted()
        }.value
    }
}
