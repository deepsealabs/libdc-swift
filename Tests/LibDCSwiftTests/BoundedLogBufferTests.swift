import XCTest
@testable import LibDCSwift

/// A full-logging download can log tens of MB; the in-app log keeps a bounded part of it, its start and its end.
final class BoundedLogBufferTests: XCTestCase {

    /// "line NNN": 8 bytes, 9 with its newline.
    private static func line(_ i: Int) -> String { String(format: "line %03d", i) }

    func testEveryLineIsKeptInOrderWithinTheBudget() {
        let buffer = BoundedLogBuffer(maxBytes: 90)
        (0..<10).forEach { buffer.append(Self.line($0)) }

        XCTAssertEqual(buffer.lines(), (0..<10).map(Self.line))
        XCTAssertEqual(buffer.lineCount, 10)
        XCTAssertEqual(buffer.byteCount, 90)
        XCTAssertNil(buffer.truncationMarker)
        XCTAssertEqual(buffer.text(), (0..<10).map(Self.line).joined(separator: "\n"))
    }

    func testOverBudgetTheFirstLinesAndTheNewestStayWithAMarkerBetween() throws {
        let buffer = BoundedLogBuffer(maxBytes: 90, headBytes: 27)
        buffer.append(contentsOf: (0..<20).map(Self.line))

        let marker = try XCTUnwrap(buffer.truncationMarker)
        XCTAssertEqual(buffer.lines(), (0..<3).map(Self.line) + [marker] + (13..<20).map(Self.line))
        XCTAssertEqual(buffer.droppedLineCount, 10)
        XCTAssertEqual(buffer.droppedByteCount, 90)
        XCTAssertEqual(buffer.lineCount, 10)
        XCTAssertLessThanOrEqual(buffer.byteCount, buffer.maxBytes)
        XCTAssertTrue(marker.hasPrefix("[log truncated: 10 lines"), marker)
    }

    func testTheHeadIsAQuarterOfTheBudgetByDefault() {
        let buffer = BoundedLogBuffer(maxBytes: 360)
        buffer.append(contentsOf: (0..<100).map(Self.line))

        let lines = buffer.lines()
        XCTAssertEqual(Array(lines.prefix(10)), (0..<10).map(Self.line))
        XCTAssertEqual(lines.last, Self.line(99))
    }

    func testAZeroHeadKeepsOnlyTheNewest() throws {
        let buffer = BoundedLogBuffer(maxBytes: 45, headBytes: 0)
        buffer.append(contentsOf: (0..<12).map(Self.line))

        XCTAssertEqual(buffer.lines(), [try XCTUnwrap(buffer.truncationMarker)] + (7..<12).map(Self.line))
    }

    func testANewestLineOverTheBudgetStaysOnItsOwn() {
        let buffer = BoundedLogBuffer(maxBytes: 20, headBytes: 9)
        buffer.append(Self.line(0))
        let long = String(repeating: "A", count: 50)
        buffer.append(Self.line(1))
        buffer.append(long)

        XCTAssertEqual(buffer.lines().first, Self.line(0))
        XCTAssertEqual(buffer.lines().last, long)
        XCTAssertEqual(buffer.lineCount, 2)
    }

    func testRemoveAllStartsOverWithAnEmptyHead() {
        let buffer = BoundedLogBuffer(maxBytes: 45, headBytes: 18)
        buffer.append(contentsOf: (0..<20).map(Self.line))
        buffer.removeAll()
        buffer.append(contentsOf: (100..<103).map(Self.line))

        XCTAssertEqual(buffer.lines(), (100..<103).map(Self.line))
        XCTAssertEqual(buffer.droppedLineCount, 0)
        XCTAssertNil(buffer.truncationMarker)
    }

    func testOrderHoldsAcrossManyDrops() {
        let buffer = BoundedLogBuffer(maxBytes: 9 * 100, headBytes: 9 * 10)
        let total = 20_000
        for i in 0..<total { buffer.append(String(format: "l%07d", i)) }

        let lines = buffer.lines()
        XCTAssertEqual(lines.count, 101)
        XCTAssertEqual(Array(lines.prefix(10)), (0..<10).map { String(format: "l%07d", $0) })
        XCTAssertEqual(Array(lines.suffix(90)), ((total - 90)..<total).map { String(format: "l%07d", $0) })
        XCTAssertEqual(buffer.droppedLineCount, total - 100)
    }

    func testConcurrentAppendsLoseNoCountAndStayWithinBudget() {
        let buffer = BoundedLogBuffer(maxBytes: 64 * 1024, headBytes: 1024)
        let threads = 8, perThread = 5_000
        DispatchQueue.concurrentPerform(iterations: threads) { t in
            for i in 0..<perThread { buffer.append("t\(t) \(String(format: "%05d", i))") }
        }

        XCTAssertEqual(buffer.lineCount + buffer.droppedLineCount, threads * perThread)
        XCTAssertLessThanOrEqual(buffer.byteCount, buffer.maxBytes)
        // Each thread's lines keep their order.
        var last = [Int](repeating: -1, count: threads)
        for line in buffer.lines() where line.hasPrefix("t") {
            let parts = line.dropFirst().split(separator: " ")
            let t = Int(parts[0])!, i = Int(parts[1])!
            XCTAssertGreaterThan(i, last[t])
            last[t] = i
        }
    }
}
