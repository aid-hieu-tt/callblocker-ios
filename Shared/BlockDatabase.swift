import Foundation
import CallBlockerCore

// MARK: - Models

struct BlockRule: Identifiable, Equatable {
    let id: Int64
    let patternDisplay: String
    let normalizedPattern: String
    let numberCount: Int64
    var isActive: Bool
}

enum WhitelistSource: String {
    case contact = "CONTACT"
    case manual = "MANUAL"
}

struct WhitelistEntry: Identifiable, Equatable {
    var id: String { "\(source.rawValue)-\(phoneNumber)" }
    let phoneNumber: Int64
    let source: WhitelistSource
    let note: String?
}

enum MetaKey: String {
    case blockingSnapshotValid = "blocking_snapshot_valid"
    case labelsVersion = "labels_version"             // App tăng mỗi khi danh sách nhãn / cờ bật-tắt đổi
    case labelsSyncedVersion = "labels_synced_version" // Extension ghi sau khi nạp thành công
    case spamEnabled = "spam_enabled"
    case spamListVersion = "spam_list_version"
    case spamLastSync = "spam_last_sync"
    case contactsWhitelistEnabled = "contacts_whitelist_enabled"
    case lastLoadSummary = "last_load_summary"
}

// MARK: - Database

/// Lược đồ dữ liệu trong App Group (mục 6.2 tài liệu), mở rộng thêm:
/// - `block_rules`: 1 dòng / quy tắc người dùng nhập (pattern hiển thị, trạng thái).
/// - `block_ranges`: các dải `[start, end]` của từng quy tắc (thường chỉ 1 dải). Việc *gộp dải chồng lấn*
///   được làm dạng streaming lúc nạp, nên bật/tắt/xoá một quy tắc không phải tính lại toàn bộ.
/// - `synced_blocking`: ảnh chụp các dải đã nạp vào CallKit lần trước -> tính diff cho incremental.
final class BlockDatabase {
    enum Role { case app, callDirectoryExtension }

    let db: SQLiteDatabase

    static func openShared(role: Role) throws -> BlockDatabase {
        try BlockDatabase(path: AppGroup.databaseURL().path, role: role)
    }

    init(path: String, role: Role) throws {
        db = try SQLiteDatabase(path: path)
        try db.execute("PRAGMA journal_mode=WAL;")
        if role == .callDirectoryExtension {
            // NFR-1: giới hạn page cache ~512 KB để Extension luôn < 12 MB.
            try db.execute("PRAGMA cache_size=-512; PRAGMA temp_store=FILE;")
        }
        try migrate()
    }

    private func migrate() throws {
        let version = try db.scalarInt64("PRAGMA user_version") ?? 0
        guard version < 1 else { return }
        try db.transaction {
            try db.execute("""
            CREATE TABLE IF NOT EXISTS block_rules (
                id                 INTEGER PRIMARY KEY AUTOINCREMENT,
                pattern_display    TEXT    NOT NULL,
                normalized_pattern TEXT    NOT NULL UNIQUE,
                number_count       INTEGER NOT NULL,
                is_active          INTEGER NOT NULL DEFAULT 1,
                created_at         REAL    NOT NULL
            );
            CREATE TABLE IF NOT EXISTS block_ranges (
                rule_id      INTEGER NOT NULL,
                start_number INTEGER NOT NULL,
                end_number   INTEGER NOT NULL,
                is_active    INTEGER NOT NULL DEFAULT 1
            );
            CREATE INDEX IF NOT EXISTS idx_block_ranges_rule ON block_ranges(rule_id);
            -- Covering partial index: Extension đọc tuần tự theo start_number, không cần sort trên RAM.
            CREATE INDEX IF NOT EXISTS idx_block_ranges_active_start
                ON block_ranges(start_number, end_number) WHERE is_active = 1;

            CREATE TABLE IF NOT EXISTS whitelist_numbers (
                phone_number INTEGER NOT NULL,
                source       TEXT    NOT NULL,
                note         TEXT,
                PRIMARY KEY (phone_number, source)
            ) WITHOUT ROWID;

            CREATE TABLE IF NOT EXISTS spam_labels (
                phone_number INTEGER PRIMARY KEY,
                label        TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS synced_blocking      (lower INTEGER PRIMARY KEY, upper INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS synced_blocking_next (lower INTEGER PRIMARY KEY, upper INTEGER NOT NULL);

            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);

            PRAGMA user_version = 1;
            """)
        }
    }

    // MARK: Meta

    func meta(_ key: MetaKey) throws -> String? {
        try db.scalarString("SELECT value FROM meta WHERE key = ?", .text(key.rawValue))
    }

    func setMeta(_ key: MetaKey, _ value: String?) throws {
        let stmt = try db.prepare("INSERT INTO meta(key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        try stmt.run(.text(key.rawValue), value.map(SQLValue.text) ?? .null)
    }

    func bumpLabelsVersion() throws {
        try setMeta(.labelsVersion, UUID().uuidString)
    }

    func invalidateBlockingSnapshot() throws {
        try setMeta(.blockingSnapshotValid, "0")
    }

    func lastLoadSummary() -> CallDirectoryLoadSummary? {
        guard let json = try? meta(.lastLoadSummary), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(CallDirectoryLoadSummary.self, from: data)
    }

    // MARK: Rules (Main App)

    func fetchRules() throws -> [BlockRule] {
        let stmt = try db.prepare("""
            SELECT id, pattern_display, normalized_pattern, number_count, is_active
            FROM block_rules ORDER BY created_at DESC
            """)
        var rules: [BlockRule] = []
        while try stmt.step() {
            rules.append(BlockRule(
                id: stmt.int64(at: 0),
                patternDisplay: stmt.string(at: 1),
                normalizedPattern: stmt.string(at: 2),
                numberCount: stmt.int64(at: 3),
                isActive: stmt.int64(at: 4) != 0
            ))
        }
        return rules
    }

    func ruleExists(_ pattern: BlockPattern) throws -> Bool {
        try db.scalarInt64("SELECT 1 FROM block_rules WHERE normalized_pattern = ?", .text(pattern.normalized)) != nil
    }

    @discardableResult
    func insertRule(_ pattern: BlockPattern, display: String) throws -> Int64 {
        try db.transaction {
            let insertRule = try db.prepare("""
                INSERT INTO block_rules(pattern_display, normalized_pattern, number_count, is_active, created_at)
                VALUES (?, ?, ?, 1, ?)
                """)
            try insertRule.run(.text(display), .text(pattern.normalized), .int(pattern.numberCount),
                               .real(Date().timeIntervalSince1970))
            let ruleID = db.lastInsertRowID
            let insertRange = try db.prepare("INSERT INTO block_ranges(rule_id, start_number, end_number, is_active) VALUES (?, ?, ?, 1)")
            for range in pattern.ranges() {
                try insertRange.run(.int(ruleID), .int(range.lower), .int(range.upper))
            }
            return ruleID
        }
    }

    func setRuleActive(id: Int64, _ active: Bool) throws {
        try db.transaction {
            try db.prepare("UPDATE block_rules SET is_active = ? WHERE id = ?").run(.int(active ? 1 : 0), .int(id))
            try db.prepare("UPDATE block_ranges SET is_active = ? WHERE rule_id = ?").run(.int(active ? 1 : 0), .int(id))
        }
    }

    func deleteRule(id: Int64) throws {
        try db.transaction {
            try db.prepare("DELETE FROM block_ranges WHERE rule_id = ?").run(.int(id))
            try db.prepare("DELETE FROM block_rules WHERE id = ?").run(.int(id))
        }
    }

    /// Số lượng số thực sự bị chặn (đã gộp trùng + trừ whitelist). Chỉ duyệt các dải, không duyệt từng số.
    func effectiveBlockedCount() throws -> Int64 {
        let stream = try makeEffectiveBlockingStream()
        let total = stream.totalNumberCount()
        try stream.checkErrors()
        return total
    }

    // MARK: Whitelist (Main App)

    func fetchWhitelist(source: WhitelistSource) throws -> [WhitelistEntry] {
        let stmt = try db.prepare("SELECT phone_number, note FROM whitelist_numbers WHERE source = ? ORDER BY phone_number")
        try stmt.bind([.text(source.rawValue)])
        var entries: [WhitelistEntry] = []
        while try stmt.step() {
            entries.append(WhitelistEntry(
                phoneNumber: stmt.int64(at: 0),
                source: source,
                note: stmt.isNull(at: 1) ? nil : stmt.string(at: 1)
            ))
        }
        return entries
    }

    func whitelistCount(source: WhitelistSource) throws -> Int64 {
        try db.scalarInt64("SELECT COUNT(*) FROM whitelist_numbers WHERE source = ?", .text(source.rawValue)) ?? 0
    }

    func addWhitelist(_ number: Int64, source: WhitelistSource, note: String?) throws {
        try db.prepare("""
            INSERT INTO whitelist_numbers(phone_number, source, note) VALUES (?, ?, ?)
            ON CONFLICT(phone_number, source) DO UPDATE SET note = excluded.note
            """).run(.int(number), .text(source.rawValue), note.map(SQLValue.text) ?? .null)
    }

    func removeWhitelist(_ number: Int64, source: WhitelistSource) throws {
        try db.prepare("DELETE FROM whitelist_numbers WHERE phone_number = ? AND source = ?")
            .run(.int(number), .text(source.rawValue))
    }

    /// FR-03: thay toàn bộ whitelist nguồn Danh bạ. Dữ liệu chỉ nằm trên máy (NFR-3).
    func replaceContactWhitelist<S: Sequence>(_ numbers: S) throws where S.Element == Int64 {
        try db.transaction {
            try db.prepare("DELETE FROM whitelist_numbers WHERE source = ?").run(.text(WhitelistSource.contact.rawValue))
            let insert = try db.prepare("INSERT OR IGNORE INTO whitelist_numbers(phone_number, source) VALUES (?, ?)")
            for number in numbers {
                try insert.run(.int(number), .text(WhitelistSource.contact.rawValue))
            }
        }
    }

    // MARK: Spam labels (FR-05)

    func replaceSpamLabels(_ entries: [(number: Int64, label: String)], listVersion: String) throws {
        try db.transaction {
            try db.execute("DELETE FROM spam_labels")
            let insert = try db.prepare("INSERT OR IGNORE INTO spam_labels(phone_number, label) VALUES (?, ?)")
            for entry in entries {
                try insert.run(.int(entry.number), .text(entry.label))
            }
            try setMeta(.spamListVersion, listVersion)
            try setMeta(.spamLastSync, String(Date().timeIntervalSince1970))
            try bumpLabelsVersion()
        }
    }

    func spamLabelCount() throws -> Int64 {
        try db.scalarInt64("SELECT COUNT(*) FROM spam_labels") ?? 0
    }

    func isSpamEnabled() throws -> Bool {
        try meta(.spamEnabled) != "0" // mặc định bật
    }

    func setSpamEnabled(_ enabled: Bool) throws {
        try db.transaction {
            try setMeta(.spamEnabled, enabled ? "1" : "0")
            try bumpLabelsVersion()
        }
    }

    // MARK: Streaming cursors (Call Directory Extension)

    /// Dải đang bật, đã gộp chồng lấn, đã trừ whitelist — đúng tập số cần có trong CallKit.
    func makeEffectiveBlockingStream() throws -> EffectiveBlockingStream {
        let ranges = try db.prepare("""
            SELECT start_number, end_number FROM block_ranges
            WHERE is_active = 1 ORDER BY start_number, end_number
            """)
        // DISTINCT: một số có thể vừa là CONTACT vừa là MANUAL.
        let whitelist = try db.prepare("SELECT DISTINCT phone_number FROM whitelist_numbers ORDER BY phone_number")
        return EffectiveBlockingStream(ranges: ranges, whitelist: whitelist)
    }

    func makeSyncedSnapshotStream() throws -> IntervalCursor {
        IntervalCursor(statement: try db.prepare("SELECT lower, upper FROM synced_blocking ORDER BY lower"))
    }

    func makeSpamLabelStatement() throws -> Statement {
        try db.prepare("SELECT phone_number, label FROM spam_labels ORDER BY phone_number")
    }

    /// Ghi tập dải vừa nạp vào bảng tạm `synced_blocking_next`. Chỉ được "commit" sau khi
    /// CallKit báo nạp thành công (xem `commitPendingSnapshot`).
    func writePendingBlockingSnapshot() throws {
        try db.execute("DELETE FROM synced_blocking_next")
        var stream = try makeEffectiveBlockingStream()
        let insert = try db.prepare("INSERT INTO synced_blocking_next(lower, upper) VALUES (?, ?)")
        while let interval = stream.next() {
            try insert.run(.int(interval.lower), .int(interval.upper))
        }
        try stream.checkErrors()
    }

    func commitPendingSnapshot(labelsVersion: String?, summary: CallDirectoryLoadSummary) throws {
        let summaryJSON = (try? JSONEncoder().encode(summary)).flatMap { String(data: $0, encoding: .utf8) }
        try db.transaction {
            try db.execute("""
                DELETE FROM synced_blocking;
                INSERT INTO synced_blocking(lower, upper) SELECT lower, upper FROM synced_blocking_next;
                DELETE FROM synced_blocking_next;
                """)
            try setMeta(.blockingSnapshotValid, "1")
            if let labelsVersion { try setMeta(.labelsSyncedVersion, labelsVersion) }
            try setMeta(.lastLoadSummary, summaryJSON)
        }
    }
}

// MARK: - Cursor adapters (SQLite statement -> IteratorProtocol)

struct IntervalCursor: IteratorProtocol {
    let statement: Statement
    func next() -> PhoneInterval? {
        guard statement.nextRow() else { return nil }
        return PhoneInterval(statement.int64(at: 0), statement.int64(at: 1))
    }
    func checkErrors() throws { try statement.throwIfIterationFailed() }
}

struct NumberCursor: IteratorProtocol {
    let statement: Statement
    func next() -> Int64? {
        guard statement.nextRow() else { return nil }
        return statement.int64(at: 0)
    }
}

/// `block_ranges (đang bật) -> gộp chồng lấn -> trừ whitelist`, toàn bộ dạng streaming O(1) RAM.
struct EffectiveBlockingStream: IteratorProtocol {
    private let rangeStatement: Statement
    private let whitelistStatement: Statement
    private var base: IntervalsExcludingPoints<MergedIntervals<IntervalCursor>, NumberCursor>

    init(ranges: Statement, whitelist: Statement) {
        rangeStatement = ranges
        whitelistStatement = whitelist
        base = IntervalCursor(statement: ranges).merged().excluding(points: NumberCursor(statement: whitelist))
    }

    mutating func next() -> PhoneInterval? { base.next() }

    /// Statement là reference type nên bản copy của stream vẫn chia sẻ trạng thái lỗi.
    func checkErrors() throws {
        try rangeStatement.throwIfIterationFailed()
        try whitelistStatement.throwIfIterationFailed()
    }
}
