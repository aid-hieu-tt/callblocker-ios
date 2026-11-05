import CallKit
import Foundation
import os
import CallBlockerCore

private let log = Logger(subsystem: AppGroup.logSubsystem, category: "CallDirectory")

/// Điểm vào của Call Directory Extension (FR-04).
///
/// Ràng buộc bộ nhớ (NFR-1, BR-08): không có mảng số điện thoại nào trên RAM. Dữ liệu đi theo đường
/// `SQLite cursor -> iterator gộp/trừ -> vòng lặp từng số -> context.add…`, mỗi lô 5.000 số được bọc
/// trong `autoreleasepool` để giải phóng object tạm của CallKit.
final class CallDirectoryHandler: CXCallDirectoryProvider {
    override func beginRequest(with context: CXCallDirectoryExtensionContext) {
        context.delegate = self
        do {
            let database = try BlockDatabase.openShared(role: .callDirectoryExtension)
            let loader = CallDirectoryLoader(database: database, context: context)
            try loader.load()
            context.completeRequest { expired in
                guard !expired else {
                    log.error("Call directory request expired; snapshot not committed")
                    return
                }
                do {
                    try loader.commit()
                } catch {
                    // Không commit được ảnh chụp: lần sau sẽ tự làm full reload (snapshot cũ vẫn hợp lệ
                    // về mặt cấu trúc nhưng App sẽ gặp lỗi unexpectedIncrementalRemoval và tự sửa).
                    log.error("Commit snapshot failed: \(String(describing: error), privacy: .public)")
                }
            }
        } catch {
            log.error("Call directory load failed: \(String(describing: error), privacy: .public)")
            context.cancelRequest(withError: error)
        }
    }
}

extension CallDirectoryHandler: CXCallDirectoryExtensionContextDelegate {
    func requestFailed(for extensionContext: CXCallDirectoryExtensionContext, withError error: Error) {
        // Thường gặp: .entriesOutOfOrder, .duplicateEntries, .maximumEntriesExceeded.
        log.error("CallKit rejected request: \(String(describing: error), privacy: .public)")
    }
}

final class CallDirectoryLoader {
    private let database: BlockDatabase
    private let context: CXCallDirectoryExtensionContext
    private let batchSize: Int64 = 5_000
    private let startedAt = Date()

    private var summary = CallDirectoryLoadSummary(mode: .full)
    private var labelsVersionLoaded: String?

    init(database: BlockDatabase, context: CXCallDirectoryExtensionContext) {
        self.database = database
        self.context = context
    }

    func load() throws {
        // Toàn bộ quá trình đọc nằm trong 1 transaction để mọi lượt duyệt (nạp, ghi snapshot)
        // thấy cùng một trạng thái dữ liệu dù Main App đang ghi song song.
        try database.db.transaction {
            let snapshotValid = try database.meta(.blockingSnapshotValid) == "1"

            if context.isIncremental && snapshotValid {
                summary.mode = .incremental
                try loadBlockingIncrementally()
            } else {
                summary.mode = .full
                if context.isIncremental {
                    // Hệ thống còn dữ liệu cũ nhưng ta không có snapshot tin cậy -> xoá sạch và nạp lại.
                    context.removeAllBlockingEntries()
                }
                try loadBlockingFully()
            }

            try database.writePendingBlockingSnapshot()
            try loadIdentification()
        }
        summary.durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        summary.finishedAt = Date()
        log.info("Loaded \(self.summary.mode.rawValue, privacy: .public): +\(self.summary.blockedAdded) -\(self.summary.blockedRemoved) labels=\(self.summary.labelsLoaded) in \(self.summary.durationMs)ms")
    }

    func commit() throws {
        try database.commitPendingSnapshot(labelsVersion: labelsVersionLoaded, summary: summary)
    }

    // MARK: Blocking

    private func loadBlockingFully() throws {
        var stream = try database.makeEffectiveBlockingStream()
        summary.blockedAdded = emitNumbers(from: &stream) { number in
            context.addBlockingEntry(withNextSequentialPhoneNumber: number)
        }
        try stream.checkErrors()
    }

    /// BR-07: chỉ gửi phần chênh lệch so với lần nạp trước -> cập nhật nhanh khi người dùng sửa 1 quy tắc.
    private func loadBlockingIncrementally() throws {
        let removedOld = try database.makeSyncedSnapshotStream()
        let removedNew = try database.makeEffectiveBlockingStream()
        var removed = removedOld.subtracting(removedNew)
        summary.blockedRemoved = emitNumbers(from: &removed) { number in
            context.removeBlockingEntry(withPhoneNumber: number)
        }
        try removedOld.checkErrors()
        try removedNew.checkErrors()

        let addedNew = try database.makeEffectiveBlockingStream()
        let addedOld = try database.makeSyncedSnapshotStream()
        var added = addedNew.subtracting(addedOld)
        summary.blockedAdded = emitNumbers(from: &added) { number in
            context.addBlockingEntry(withNextSequentialPhoneNumber: number)
        }
        try addedNew.checkErrors()
        try addedOld.checkErrors()
    }

    // MARK: Identification (FR-05)

    private func loadIdentification() throws {
        let version = try database.meta(.labelsVersion) ?? "initial"
        let syncedVersion = try database.meta(.labelsSyncedVersion)

        if context.isIncremental && syncedVersion == version {
            summary.labelsReused = true
            return
        }
        if context.isIncremental {
            context.removeAllIdentificationEntries()
        }
        labelsVersionLoaded = version

        guard try database.isSpamEnabled() else { return }

        let statement = try database.makeSpamLabelStatement()
        var loaded: Int64 = 0
        var hasMore = true
        while hasMore {
            autoreleasepool {
                var inBatch: Int64 = 0
                while inBatch < batchSize {
                    guard statement.nextRow() else {
                        hasMore = false
                        return
                    }
                    context.addIdentificationEntry(
                        withNextSequentialPhoneNumber: statement.int64(at: 0),
                        label: statement.string(at: 1)
                    )
                    inBatch += 1
                    loaded += 1
                }
            }
        }
        try statement.throwIfIterationFailed()
        summary.labelsLoaded = loaded
    }

    // MARK: Helpers

    /// Sinh từng số trong mỗi dải và đẩy thẳng vào CallKit, theo lô `batchSize` trong `autoreleasepool`.
    @discardableResult
    private func emitNumbers<I: IteratorProtocol>(from intervals: inout I, _ body: (Int64) -> Void) -> Int64
    where I.Element == PhoneInterval {
        var total: Int64 = 0
        while let interval = intervals.next() {
            var start = interval.lower
            while true {
                let end = min(interval.upper, start + batchSize - 1)
                autoreleasepool {
                    var number = start
                    while number <= end {
                        body(number)
                        number += 1
                    }
                }
                total += end - start + 1
                if end == interval.upper { break }
                start = end + 1
            }
        }
        return total
    }
}
