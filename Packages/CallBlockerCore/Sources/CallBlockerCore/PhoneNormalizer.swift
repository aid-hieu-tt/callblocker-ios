import Foundation

/// BR-03: chuẩn hoá số điện thoại về dạng quốc tế không dấu "+" (E.164 digits), ví dụ `0248888xxxx` -> `84248888xxxx`.
public enum PhoneNormalizer {
    public static let countryCode = "84"

    /// Ký tự đại diện được chấp nhận khi nhập (đều quy về `x`).
    public static let wildcardInputs: Set<Character> = ["x", "X", "*", "?"]
    public static let wildcard: Character = "x"

    /// Ký tự định dạng được bỏ qua.
    static let separators: Set<Character> = [" ", "-", ".", "(", ")", "\u{00A0}", "\u{2011}", "/"]

    public enum CleanError: Error, Equatable {
        case invalidCharacter(Character)
    }

    /// Bỏ ký tự định dạng, giữ `+` ở đầu, quy mọi ký tự đại diện về `x`.
    public static func clean(_ raw: String, allowWildcards: Bool) throws -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        for ch in raw.trimmingCharacters(in: .whitespacesAndNewlines) {
            if separators.contains(ch) { continue }
            if ch.isASCII, ch.isNumber {
                out.append(ch)
            } else if ch == "+", out.isEmpty {
                out.append(ch)
            } else if allowWildcards, wildcardInputs.contains(ch) {
                out.append(wildcard)
            } else {
                throw CleanError.invalidCharacter(ch)
            }
        }
        return out
    }

    /// Áp mã quốc gia cho chuỗi đã `clean`.
    /// - `+84…` / `+<cc>…` -> bỏ dấu `+`
    /// - `00<cc>…`         -> bỏ `00`
    /// - `0…`              -> `84…` (số trong nước)
    /// - `84…`             -> giữ nguyên (đã ở dạng quốc tế)
    /// - còn lại (vd. `1900…`, `1800…`) -> thêm `84`
    public static func applyCountryCode(_ cleaned: String) -> String {
        if cleaned.hasPrefix("+") { return String(cleaned.dropFirst()) }
        if cleaned.hasPrefix("00") { return String(cleaned.dropFirst(2)) }
        if cleaned.hasPrefix("0") { return countryCode + cleaned.dropFirst() }
        if cleaned.hasPrefix(countryCode) { return cleaned }
        return countryCode + cleaned
    }

    /// Chuẩn hoá một số cụ thể (không ký tự đại diện) thành `Int64` dùng cho CallKit.
    /// Trả về `nil` nếu không hợp lệ (vd. danh bạ chứa chữ, mã USSD `*101#`…).
    public static func normalize(_ raw: String) -> Int64? {
        guard let cleaned = try? clean(raw, allowWildcards: false), !cleaned.isEmpty else { return nil }
        let digits = applyCountryCode(cleaned)
        guard (6...15).contains(digits.count), digits.first != "0" else { return nil }
        return Int64(digits)
    }

    /// Hiển thị dạng trong nước: `842488881234` -> `02488881234`; số nước ngoài -> `+1…`.
    public static func nationalDisplay(_ normalized: String) -> String {
        normalized.hasPrefix(countryCode) ? "0" + normalized.dropFirst(countryCode.count) : "+" + normalized
    }

    public static func nationalDisplay(_ number: Int64) -> String {
        nationalDisplay(String(number))
    }
}
