import CallKit
import Contacts
import Foundation
import SwiftUI
import CallBlockerCore

@MainActor
final class AppModel: ObservableObject {
    enum SyncStatus: Equatable {
        case idle
        case syncing
        case succeeded(seconds: Double, summary: CallDirectoryLoadSummary?)
        case failed(String)
    }

    @Published private(set) var extensionStatus: ExtensionStatus = .unknown
    @Published private(set) var rules: [BlockRule] = []
    @Published private(set) var manualWhitelist: [WhitelistEntry] = []
    @Published private(set) var contactWhitelistCount: Int64 = 0
    @Published private(set) var effectiveBlockedCount: Int64 = 0
    @Published private(set) var syncStatus: SyncStatus = .idle
    @Published private(set) var spamEnabled = true
    @Published private(set) var spamCount: Int64 = 0
    @Published private(set) var spamLastSync: Date?
    @Published private(set) var isRefreshingSpam = false
    @Published private(set) var contactsWhitelistEnabled = false
    @Published var alertMessage: String?
    @Published var onboardingSkipped = false

    private let database: BlockDatabase?
    private let directory = CallDirectoryService()
    private var isReloading = false
    private var reloadPending = false
    private var contactsObserver: NSObjectProtocol?

    init() {
        do {
            database = try BlockDatabase.openShared(role: .app)
        } catch {
            database = nil
            alertMessage = "Không mở được cơ sở dữ liệu: \(error.localizedDescription)"
        }
        reloadLocalState()
        contactsObserver = NotificationCenter.default.addObserver(
            forName: .CNContactStoreDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.resyncContactsIfEnabled() }
        }
    }

    // MARK: State

    func reloadLocalState() {
        guard let database else { return }
        do {
            rules = try database.fetchRules()
            manualWhitelist = try database.fetchWhitelist(source: .manual)
            contactWhitelistCount = try database.whitelistCount(source: .contact)
            effectiveBlockedCount = try database.effectiveBlockedCount()
            spamEnabled = try database.isSpamEnabled()
            spamCount = try database.spamLabelCount()
            spamLastSync = try database.meta(.spamLastSync).flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            contactsWhitelistEnabled = try database.meta(.contactsWhitelistEnabled) == "1"
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func refreshExtensionStatus() async {
        extensionStatus = await directory.status()
    }

    func openSystemSettings() async {
        await directory.openSettings()
    }

    // MARK: Rules (FR-02)

    /// Kiểm tra mẫu để hiển thị trước khi lưu.
    func validate(_ input: String) -> Result<BlockPattern, PatternError> {
        do {
            return .success(try PatternParser.parse(input))
        } catch let error as PatternError {
            return .failure(error)
        } catch {
            return .failure(.empty)
        }
    }

    func addRule(_ input: String) throws {
        guard let database else { return }
        let pattern = try PatternParser.parse(input)
        if try database.ruleExists(pattern) {
            throw RuleError.duplicate
        }
        try database.insertRule(pattern, display: input.trimmingCharacters(in: .whitespacesAndNewlines))
        didChangeBlockingData()
    }

    func setRule(_ rule: BlockRule, active: Bool) {
        perform { try $0.setRuleActive(id: rule.id, active) }
    }

    func deleteRules(_ ids: [Int64]) {
        perform { db in try ids.forEach { try db.deleteRule(id: $0) } }
    }

    enum RuleError: LocalizedError {
        case duplicate
        var errorDescription: String? { "Quy tắc này đã tồn tại." }
    }

    // MARK: Whitelist (FR-03)

    func addManualWhitelist(_ input: String, note: String?) throws {
        guard let number = PhoneNormalizer.normalize(input) else { throw WhitelistError.invalidNumber }
        let trimmedNote = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        try database?.addWhitelist(number, source: .manual, note: trimmedNote?.isEmpty == false ? trimmedNote : nil)
        didChangeBlockingData()
    }

    func removeManualWhitelist(_ entries: [WhitelistEntry]) {
        perform { db in try entries.forEach { try db.removeWhitelist($0.phoneNumber, source: .manual) } }
    }

    func setContactsWhitelist(enabled: Bool) async {
        guard let database else { return }
        do {
            if enabled {
                let numbers = try await ContactsWhitelistService.collectNormalizedNumbers()
                try database.replaceContactWhitelist(numbers)
            } else {
                try database.replaceContactWhitelist([Int64]())
            }
            try database.setMeta(.contactsWhitelistEnabled, enabled ? "1" : "0")
            didChangeBlockingData()
        } catch {
            alertMessage = error.localizedDescription
            reloadLocalState()
        }
    }

    private func resyncContactsIfEnabled() async {
        guard contactsWhitelistEnabled, ContactsWhitelistService.isAuthorized else { return }
        await setContactsWhitelist(enabled: true)
    }

    enum WhitelistError: LocalizedError {
        case invalidNumber
        var errorDescription: String? { "Số điện thoại không hợp lệ." }
    }

    // MARK: Spam (FR-05)

    func setSpamEnabled(_ enabled: Bool) {
        perform { try $0.setSpamEnabled(enabled) }
    }

    func refreshSpamList() async {
        guard let database, !isRefreshingSpam else { return }
        isRefreshingSpam = true
        defer { isRefreshingSpam = false }
        do {
            try await SpamListService().refresh(into: database)
            didChangeBlockingData()
        } catch {
            alertMessage = "Không tải được danh sách số rác: \(error.localizedDescription)"
        }
    }

    // MARK: Sync (FR-04)

    private func perform(_ change: (BlockDatabase) throws -> Void) {
        guard let database else { return }
        do {
            try change(database)
            didChangeBlockingData()
        } catch {
            alertMessage = error.localizedDescription
            reloadLocalState()
        }
    }

    private func didChangeBlockingData() {
        reloadLocalState()
        Task { await reloadCallDirectory() }
    }

    /// Gộp các yêu cầu nạp liên tiếp (vd. bật/tắt nhanh nhiều quy tắc) thành tối đa 1 lần chạy kế tiếp.
    func reloadCallDirectory() async {
        if isReloading {
            reloadPending = true
            return
        }
        isReloading = true
        defer { isReloading = false }
        repeat {
            reloadPending = false
            await performReload(allowRepair: true)
        } while reloadPending
    }

    private func performReload(allowRepair: Bool) async {
        syncStatus = .syncing
        let started = Date()
        do {
            try await directory.reload()
            syncStatus = .succeeded(seconds: Date().timeIntervalSince(started), summary: database?.lastLoadSummary())
        } catch let error as CXErrorCodeCallDirectoryManagerError where allowRepair &&
                    (error.code == .unexpectedIncrementalRemoval || error.code == .duplicateEntries) {
            // Snapshot lệch với dữ liệu thật trong CallKit -> buộc Extension làm full reload.
            try? database?.invalidateBlockingSnapshot()
            await performReload(allowRepair: false)
        } catch let error as CXErrorCodeCallDirectoryManagerError where error.code == .currentlyLoading {
            reloadPending = true
            try? await Task.sleep(nanoseconds: 500_000_000)
        } catch {
            syncStatus = .failed(CallDirectoryService.describe(error))
            if (error as? CXErrorCodeCallDirectoryManagerError)?.code == .extensionDisabled {
                extensionStatus = .disabled
            }
        }
    }
}
