import XCTest
@testable import NauticTestApp

final class ExplorerLogTests: XCTestCase {
    private var directory: URL!

    // A real Nautic RPC packet read twice in a row, 27 ms apart, in urbamax's DC_LOGLEVEL_ALL capture.
    private let read = "iostream.c:200 dc_iostream_read(): Read: size=35, data=7EA50117000000F0240E01800002240C2433AE0B00000050000C0000000016DC9A147E"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testARepeatedFullLoggingLineIsKept() {
        let log = ExplorerLog(directory: directory)
        log.appendLibdc(level: "INFO", message: read)
        log.appendLibdc(level: "INFO", message: read)
        XCTAssertEqual(count(of: read, in: log.text()), 2)
    }

    func testARepeatedParserErrorIsLeftOut() {
        let log = ExplorerLog(directory: directory)
        let error = "suunto_nautic_parser.c:1203 suunto_nautic_parser_samples_foreach(): Invalid sample size"
        log.appendLibdc(level: "ERROR", message: error)
        log.appendLibdc(level: "ERROR", message: error)
        XCTAssertEqual(count(of: error, in: log.text()), 1)
    }

    func testTheFirstFullLoggingLineMakesItAFullLog() throws {
        let log = ExplorerLog(directory: directory)
        // Auto download resumed at launch with the switch off, then reconnected at full logging.
        log.noteConnection("Auto download ON for Nautic", device: "Nautic")
        log.appendLibdc(level: "WARN", message: "suunto_nautic.c:400 suunto_nautic_device_open(): Busy")
        XCTAssertFalse(log.usedFullLogging)
        XCTAssertTrue(log.shareItem() is String)

        log.appendLibdc(level: "INFO", message: read)
        XCTAssertTrue(log.usedFullLogging)
        let text = try String(contentsOf: XCTUnwrap(log.shareItem() as? URL), encoding: .utf8)
        XCTAssertTrue(text.contains("Full logging ON (DC_LOGLEVEL_ALL) from "))
        XCTAssertTrue(text.contains("Device: Nautic"))
        XCTAssertTrue(text.contains("Auto download ON for Nautic"))
        XCTAssertTrue(text.contains(read))
    }

    func testAFullLogSurvivesARelaunch() throws {
        let lines = (0..<2000).map { "iostream.c:200 dc_iostream_read(): Read: size=60, data=\(String(format: "%04d", $0))" }
        do {
            let log = ExplorerLog(directory: directory)
            log.noteConnection("Connecting to Nautic", device: "Nautic")
            for line in lines { log.appendLibdc(level: "INFO", message: line) }
            // Flushes to disk, as the next publish would before a crash.
            _ = log.shareItem()
        }

        let relaunched = ExplorerLog(directory: directory)
        XCTAssertTrue(relaunched.usedFullLogging)
        relaunched.append("After the relaunch")
        let text = try String(contentsOf: XCTUnwrap(relaunched.shareItem() as? URL), encoding: .utf8)
        XCTAssertTrue(text.contains("Full logging ON (DC_LOGLEVEL_ALL) from "))
        XCTAssertTrue(text.contains("Device: Nautic"))
        let reads = text.components(separatedBy: "\n").filter { $0.contains("[libdc INFO] ") }
        XCTAssertEqual(reads.map { String($0.suffix(lines[0].count)) }, lines)
        XCTAssertTrue(text.hasSuffix("After the relaunch\n"))
    }

    func testClearEndsTheFullLog() throws {
        let log = ExplorerLog(directory: directory)
        log.appendLibdc(level: "INFO", message: read)
        _ = log.shareItem()
        log.clear()
        XCTAssertFalse(log.usedFullLogging)
        XCTAssertFalse(ExplorerLog(directory: directory).usedFullLogging)
    }

    func testAFullLogOverItsCapKeepsItsStartAndNewestLines() throws {
        let store = FullLogStore(directory: directory.appendingPathComponent("full-log"), maxBytes: 800, segmentBytes: 100)
        store.start(since: Date(), device: "Nautic", seed: [])
        // 10 bytes a line, so 10 a segment: 2 segments at the start and the newest 6 stay.
        for i in 0..<200 { store.append([String(format: "line %04d", i)]) }

        let out = directory.appendingPathComponent("out.txt")
        XCTAssertTrue(store.export(to: out, header: "header\n"))
        let lines = try String(contentsOf: out, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "header")
        XCTAssertEqual(Array(lines[1...20]), (0..<20).map { String(format: "line %04d", $0) })
        XCTAssertEqual(lines[21], "[log truncated: 120 lines (0.0 MB) dropped here to stay within 0.0 MB]")
        XCTAssertEqual(Array(lines[22...]), (140..<200).map { String(format: "line %04d", $0) })

        let restored = FullLogStore(directory: directory.appendingPathComponent("full-log"), maxBytes: 800, segmentBytes: 100)
        let again = directory.appendingPathComponent("again.txt")
        XCTAssertTrue(restored.export(to: again, header: "header\n"))
        XCTAssertEqual(try Data(contentsOf: again), try Data(contentsOf: out))
    }

    private func count(of line: String, in text: String) -> Int {
        text.components(separatedBy: "\n").filter { $0.hasSuffix(line) }.count
    }
}
