import Foundation

/// Một dải số liên tục `[lower, upper]` (bao gồm hai đầu).
public struct PhoneInterval: Hashable, CustomStringConvertible {
    public let lower: Int64
    public let upper: Int64

    public init(_ lower: Int64, _ upper: Int64) {
        precondition(lower <= upper, "PhoneInterval lower > upper")
        self.lower = lower
        self.upper = upper
    }

    public init(single number: Int64) { self.init(number, number) }

    public var count: Int64 { upper - lower + 1 }
    public func contains(_ number: Int64) -> Bool { lower <= number && number <= upper }
    public var description: String { "[\(lower)…\(upper)]" }
}

// MARK: - Streaming operators
//
// Toàn bộ các toán tử dưới đây là iterator "kéo" (pull-based), chỉ giữ O(1) trạng thái,
// nên Extension có thể đọc dữ liệu thẳng từ con trỏ SQLite mà không nạp mảng lên RAM (BR-08).

/// Gộp các dải chồng lấn hoặc liền kề. Đầu vào PHẢI được sắp xếp theo `lower` tăng dần
/// (SQL: `ORDER BY start_number`). Đầu ra: các dải rời nhau, tăng dần tuyệt đối (BR-05).
public struct MergedIntervals<Base: IteratorProtocol>: IteratorProtocol where Base.Element == PhoneInterval {
    private var base: Base
    private var pending: PhoneInterval?

    public init(_ base: Base) { self.base = base }

    public mutating func next() -> PhoneInterval? {
        guard let first = pending ?? base.next() else { return nil }
        pending = nil
        let lower = first.lower
        var upper = first.upper
        while let candidate = base.next() {
            assert(candidate.lower >= lower, "MergedIntervals: input must be sorted by lower bound")
            if upper == .max || candidate.lower <= upper + 1 {
                upper = Swift.max(upper, candidate.upper)
            } else {
                pending = candidate
                break
            }
        }
        return PhoneInterval(lower, upper)
    }
}

/// Loại các số lẻ (whitelist) ra khỏi một chuỗi dải đã gộp (BR-06), bằng kỹ thuật hai con trỏ.
/// `points` phải tăng dần (cho phép trùng lặp). Không cần `Set` trên RAM.
public struct IntervalsExcludingPoints<Intervals: IteratorProtocol, Points: IteratorProtocol>: IteratorProtocol
where Intervals.Element == PhoneInterval, Points.Element == Int64 {
    private var intervals: Intervals
    private var points: Points
    private var current: PhoneInterval?
    private var point: Int64?
    private var primed = false

    public init(_ intervals: Intervals, excluding points: Points) {
        self.intervals = intervals
        self.points = points
    }

    public mutating func next() -> PhoneInterval? {
        if !primed {
            point = points.next()
            primed = true
        }
        while true {
            guard let c = current ?? intervals.next() else { return nil }
            current = nil
            while let p = point, p < c.lower { point = points.next() }
            guard let p = point, p <= c.upper else { return c }

            // p nằm trong c: tách c thành [c.lower, p-1] và [p+1, c.upper].
            point = points.next()
            if p < c.upper { current = PhoneInterval(p + 1, c.upper) }
            if p > c.lower { return PhoneInterval(c.lower, p - 1) }
            // p == c.lower: phần bên trái rỗng, tiếp tục với phần còn lại.
        }
    }
}

/// Hiệu tập hợp `A \ B` của hai chuỗi dải rời nhau, tăng dần. Dùng cho Incremental Update (BR-07):
/// `removed = snapshot \ current`, `added = current \ snapshot`.
public struct IntervalDifference<A: IteratorProtocol, B: IteratorProtocol>: IteratorProtocol
where A.Element == PhoneInterval, B.Element == PhoneInterval {
    private var a: A
    private var b: B
    private var current: PhoneInterval?
    private var subtrahend: PhoneInterval?
    private var primed = false

    public init(_ a: A, minus b: B) {
        self.a = a
        self.b = b
    }

    public mutating func next() -> PhoneInterval? {
        if !primed {
            subtrahend = b.next()
            primed = true
        }
        while true {
            guard let x = current ?? a.next() else { return nil }
            current = nil
            while let y = subtrahend, y.upper < x.lower { subtrahend = b.next() }
            guard let y = subtrahend, y.lower <= x.upper else { return x }

            if y.upper < x.upper { current = PhoneInterval(y.upper + 1, x.upper) }
            if y.lower > x.lower { return PhoneInterval(x.lower, y.lower - 1) }
            // y phủ đầu trái của x: bỏ phần đó, xử lý tiếp phần còn lại (nếu có).
        }
    }
}

public extension IteratorProtocol where Element == PhoneInterval {
    func merged() -> MergedIntervals<Self> { MergedIntervals(self) }

    func excluding<P: IteratorProtocol>(points: P) -> IntervalsExcludingPoints<Self, P> where P.Element == Int64 {
        IntervalsExcludingPoints(self, excluding: points)
    }

    func subtracting<B: IteratorProtocol>(_ other: B) -> IntervalDifference<Self, B> where B.Element == PhoneInterval {
        IntervalDifference(self, minus: other)
    }

    /// Tiêu thụ iterator và đếm tổng số điện thoại.
    func totalNumberCount() -> Int64 {
        var copy = self
        var total: Int64 = 0
        while let i = copy.next() { total += i.count }
        return total
    }
}
