import XCTest
@testable import CallBlockerCore

final class PhoneNormalizerTests: XCTestCase {
    func testNormalizesDomesticAndInternationalForms() {
        XCTAssertEqual(PhoneNormalizer.normalize("0912 345 678"), 84_912_345_678)
        XCTAssertEqual(PhoneNormalizer.normalize("+84 912-345-678"), 84_912_345_678)
        XCTAssertEqual(PhoneNormalizer.normalize("0084912345678"), 84_912_345_678)
        XCTAssertEqual(PhoneNormalizer.normalize("84912345678"), 84_912_345_678)
        XCTAssertEqual(PhoneNormalizer.normalize("(024) 8888.1234"), 842_488_881_234)
        XCTAssertEqual(PhoneNormalizer.normalize("1900 1234"), 8_419_001_234)
    }

    func testRejectsInvalidNumbers() {
        XCTAssertNil(PhoneNormalizer.normalize("*101#"))
        XCTAssertNil(PhoneNormalizer.normalize("abc"))
        XCTAssertNil(PhoneNormalizer.normalize(""))
    }

    func testNationalDisplay() {
        XCTAssertEqual(PhoneNormalizer.nationalDisplay(842_488_881_234), "02488881234")
        XCTAssertEqual(PhoneNormalizer.nationalDisplay("14155550100"), "+14155550100")
    }
}

final class PatternParserTests: XCTestCase {
    func testTrailingWildcardsBecomeSingleRange() throws {
        let pattern = try PatternParser.parse("024 8888 xxxx")
        XCTAssertEqual(pattern.normalized, "84248888xxxx")
        XCTAssertEqual(pattern.numberCount, 10_000)
        XCTAssertEqual(pattern.ranges(), [PhoneInterval(842_488_880_000, 842_488_889_999)])
    }

    func testStarWildcards() throws {
        let pattern = try PatternParser.parse("0248888***")
        XCTAssertEqual(pattern.normalized, "84248888xxx")
        XCTAssertEqual(pattern.numberCount, 1_000)
    }

    func testBR04RejectsTooManyWildcards() {
        XCTAssertThrowsError(try PatternParser.parse("024xxxxxxx")) { error in
            XCTAssertEqual(error as? PatternError, .tooManyWildcards(found: 7, limit: 5))
        }
        XCTAssertNoThrow(try PatternParser.parse("02888xxxxx")) // đúng 5
    }

    func testWildcardMustNotReplacePrefix() {
        XCTAssertThrowsError(try PatternParser.parse("x248888123")) { error in
            XCTAssertEqual(error as? PatternError, .wildcardInPrefix)
        }
    }

    func testInvalidCharacter() {
        XCTAssertThrowsError(try PatternParser.parse("024a8888")) { error in
            XCTAssertEqual(error as? PatternError, .invalidCharacter("a"))
        }
    }

    func testExactNumberIsSingleNumberRange() throws {
        let pattern = try PatternParser.parse("0889123456")
        XCTAssertEqual(pattern.ranges(), [PhoneInterval(single: 84_889_123_456)])
    }

    func testMiddleWildcardsProduceSortedRanges() throws {
        let pattern = try PatternParser.parse("02488x8888x")
        let ranges = pattern.ranges()
        XCTAssertEqual(ranges.count, 10)
        XCTAssertEqual(ranges.first, PhoneInterval(842_488_088_880, 842_488_088_889))
        XCTAssertEqual(ranges.last, PhoneInterval(842_488_988_880, 842_488_988_889))
        XCTAssertEqual(ranges, ranges.sorted { $0.lower < $1.lower })
        XCTAssertEqual(ranges.reduce(0) { $0 + $1.count }, pattern.numberCount)
    }
}

final class IntervalStreamTests: XCTestCase {
    private func iv(_ a: Int64, _ b: Int64) -> PhoneInterval { PhoneInterval(a, b) }
    private func collect<I: IteratorProtocol>(_ it: I) -> [I.Element] {
        var it = it
        var out: [I.Element] = []
        while let x = it.next() { out.append(x) }
        return out
    }

    func testMergeOverlappingAndAdjacent() {
        let input = [iv(1, 5), iv(3, 8), iv(9, 10), iv(12, 12), iv(12, 20), iv(15, 16)]
        XCTAssertEqual(collect(input.makeIterator().merged()), [iv(1, 10), iv(12, 20)])
    }

    func testMergeDuplicateRules() {
        let input = [iv(100, 199), iv(100, 199), iv(150, 160)]
        XCTAssertEqual(collect(input.makeIterator().merged()), [iv(100, 199)])
    }

    func testExcludingPoints() {
        let intervals = [iv(10, 20), iv(30, 30), iv(40, 45)]
        let points: [Int64] = [5, 10, 15, 15, 20, 30, 41, 99]
        XCTAssertEqual(
            collect(intervals.makeIterator().excluding(points: points.makeIterator())),
            [iv(11, 14), iv(16, 19), iv(40, 40), iv(42, 45)]
        )
    }

    func testBR06Example() throws {
        let ranges = try PatternParser.parse("0248888xxxx").ranges()
        let whitelist: [Int64] = [842_488_881_234]
        let result = collect(ranges.makeIterator().merged().excluding(points: whitelist.makeIterator()))
        XCTAssertEqual(result, [iv(842_488_880_000, 842_488_881_233), iv(842_488_881_235, 842_488_889_999)])
        XCTAssertEqual(result.reduce(0) { $0 + $1.count }, 9_999)
    }

    func testDifference() {
        let a = [iv(1, 10), iv(20, 30), iv(40, 50)]
        let b = [iv(0, 2), iv(5, 6), iv(25, 45)]
        XCTAssertEqual(
            collect(a.makeIterator().subtracting(b.makeIterator())),
            [iv(3, 4), iv(7, 10), iv(20, 24), iv(46, 50)]
        )
        XCTAssertEqual(collect(a.makeIterator().subtracting([PhoneInterval]().makeIterator())), a)
        XCTAssertEqual(collect([PhoneInterval]().makeIterator().subtracting(a.makeIterator())), [])
    }

    /// Mô phỏng BR-07: áp diff lên tập cũ phải ra đúng tập mới.
    func testIncrementalDiffRoundTrip() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let old = randomSet(using: &rng)
            let new = randomSet(using: &rng)
            let oldIntervals = intervals(from: old)
            let newIntervals = intervals(from: new)

            let removed = collect(oldIntervals.makeIterator().subtracting(newIntervals.makeIterator()))
            let added = collect(newIntervals.makeIterator().subtracting(oldIntervals.makeIterator()))

            var applied = old
            for r in removed { for n in r.lower...r.upper { XCTAssertNotNil(applied.remove(n)) } }
            for a in added { for n in a.lower...a.upper { XCTAssertTrue(applied.insert(n).inserted) } }
            XCTAssertEqual(applied, new)
        }
    }

    func testTotalCount() {
        let input = [iv(1, 10), iv(5, 15)]
        XCTAssertEqual(input.makeIterator().merged().totalNumberCount(), 15)
    }

    private func randomSet(using rng: inout SystemRandomNumberGenerator) -> Set<Int64> {
        Set((0..<Int.random(in: 0...40, using: &rng)).map { _ in Int64.random(in: 0...80, using: &rng) })
    }

    private func intervals(from set: Set<Int64>) -> [PhoneInterval] {
        collect(set.sorted().map { PhoneInterval(single: $0) }.makeIterator().merged())
    }
}
