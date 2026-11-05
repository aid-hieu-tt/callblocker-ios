import Foundation

public enum PatternError: Error, Equatable {
    case empty
    case invalidCharacter(Character)
    case tooManyWildcards(found: Int, limit: Int)
    case wildcardInPrefix
    case tooShort
    case tooLong
}

extension PatternError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Vui lòng nhập số hoặc mẫu số cần chặn."
        case .invalidCharacter(let ch):
            return "Ký tự không hợp lệ: \"\(ch)\". Chỉ dùng chữ số và ký tự đại diện x hoặc *."
        case .tooManyWildcards(let found, let limit):
            return "Mẫu có \(found) ký tự đại diện (≈ \(PatternParser.formatCount(pow10(found))) số). "
                + "Tối đa \(limit) ký tự (≈ \(PatternParser.formatCount(pow10(limit))) số) — hãy nhập cụ thể hơn."
        case .wildcardInPrefix:
            return "Phải có ít nhất đầu số cố định (vd. 024, 028, 1900) trước ký tự đại diện."
        case .tooShort:
            return "Số quá ngắn."
        case .tooLong:
            return "Số quá dài (tối đa 15 chữ số theo chuẩn quốc tế)."
        }
    }
}

/// Một quy tắc chặn đã được kiểm tra hợp lệ, ở dạng chuẩn hoá `84…` với ký tự đại diện `x`.
public struct BlockPattern: Equatable, Hashable {
    /// Ví dụ `842488889xxx`.
    public let normalized: String

    public var wildcardCount: Int { normalized.reduce(0) { $1 == PhoneNormalizer.wildcard ? $0 + 1 : $0 } }

    /// Số lượng số điện thoại mà mẫu bao phủ (10^số ký tự đại diện).
    public var numberCount: Int64 { pow10(wildcardCount) }

    /// Số ký tự đại diện liên tiếp ở cuối — phần này thành 1 dải liền mạch.
    public var trailingWildcardCount: Int {
        normalized.reversed().prefix { $0 == PhoneNormalizer.wildcard }.count
    }

    /// Dạng hiển thị trong nước, vd. `0248888xxxx`.
    public var nationalDisplay: String { PhoneNormalizer.nationalDisplay(normalized) }

    init(normalized: String) {
        self.normalized = normalized
    }

    /// BR-05: chuyển mẫu thành các dải `[start, end]` tăng dần, không chồng lấn.
    ///
    /// - Ký tự đại diện ở cuối (`0248888xxxx`) -> đúng 1 dải.
    /// - Ký tự đại diện ở giữa (`02488x8888x`) -> 10^(số x ở giữa) dải.
    /// Tổng số phần tử luôn ≤ 10^maxWildcards nên mảng này nhỏ (≤ 1.6 MB, chỉ dùng ở Main App).
    public func ranges() -> [PhoneInterval] {
        let chars = Array(normalized)
        let trailing = trailingWildcardCount
        let head = chars.dropLast(trailing)
        var headDigits: [Int64] = head.map { $0 == PhoneNormalizer.wildcard ? 0 : Int64($0.wholeNumberValue ?? 0) }
        let wildcardPositions = head.indices.filter { head[$0] == PhoneNormalizer.wildcard }
        let span = pow10(trailing)
        let combinations = pow10(wildcardPositions.count)

        var result: [PhoneInterval] = []
        result.reserveCapacity(Int(combinations))
        for combo in 0..<combinations {
            var c = combo
            // Chữ số có nghĩa lớn nhất trước -> kết quả tự động tăng dần.
            for pos in wildcardPositions.reversed() {
                headDigits[pos] = c % 10
                c /= 10
            }
            let prefixValue = headDigits.reduce(Int64(0)) { $0 * 10 + $1 }
            let lower = prefixValue * span
            result.append(PhoneInterval(lower, lower + span - 1))
        }
        return result
    }
}

public enum PatternParser {
    /// BR-04: tối đa 5 ký tự đại diện = 100.000 số / quy tắc.
    public static let defaultMaxWildcards = 5
    /// Số chữ số cố định tối thiểu ở đầu (tính cả mã quốc gia), vd. `8424`.
    public static let minimumFixedPrefixDigits = 4
    public static let minimumLength = 8
    public static let maximumLength = 15

    public static func parse(_ input: String, maxWildcards: Int = defaultMaxWildcards) throws -> BlockPattern {
        let cleaned: String
        do {
            cleaned = try PhoneNormalizer.clean(input, allowWildcards: true)
        } catch PhoneNormalizer.CleanError.invalidCharacter(let ch) {
            throw PatternError.invalidCharacter(ch)
        }
        guard !cleaned.isEmpty, cleaned != "+" else { throw PatternError.empty }

        let normalized = PhoneNormalizer.applyCountryCode(cleaned)
        let wildcards = normalized.reduce(0) { $1 == PhoneNormalizer.wildcard ? $0 + 1 : $0 }

        guard wildcards <= maxWildcards else {
            throw PatternError.tooManyWildcards(found: wildcards, limit: maxWildcards)
        }
        guard normalized.count >= minimumLength else { throw PatternError.tooShort }
        guard normalized.count <= maximumLength else { throw PatternError.tooLong }
        guard normalized.prefix(minimumFixedPrefixDigits).allSatisfy({ $0.isASCII && $0.isNumber }),
              normalized.first != "0" else {
            throw PatternError.wildcardInPrefix
        }
        return BlockPattern(normalized: normalized)
    }

    public static func formatCount(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "vi_VN")
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}

@inline(__always)
func pow10(_ exponent: Int) -> Int64 {
    var v: Int64 = 1
    for _ in 0..<max(0, exponent) { v *= 10 }
    return v
}
