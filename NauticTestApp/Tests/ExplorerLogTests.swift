import XCTest
import Compression
@testable import NauticTestApp

final class ExplorerLogTests: XCTestCase {
    private var directory: URL!
    private var shareDirectory: URL { directory.appendingPathComponent("share") }

    // A real Nautic RPC packet read twice in a row, 27 ms apart, in urbamax's DC_LOGLEVEL_ALL capture.
    private let read = "iostream.c:200 dc_iostream_read(): Read: size=35, data=7EA50117000000F0240E01800002240C2433AE0B00000050000C0000000016DC9A147E"
    private let stamp = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} "#)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerLogTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeLog(segmentBytes: Int = FullLogStore.defaultSegmentBytes) -> ExplorerLog {
        ExplorerLog(directory: directory, shareDirectory: shareDirectory, fullLogSegmentBytes: segmentBytes)
    }

    func testARepeatedFullLoggingLineIsKept() {
        let log = makeLog()
        log.appendLibdc(level: "INFO", message: read)
        log.appendLibdc(level: "INFO", message: read)
        XCTAssertEqual(count(of: read, in: log.text()), 2)
    }

    func testARepeatedParserErrorIsLeftOut() {
        let log = makeLog()
        let error = "suunto_nautic_parser.c:1203 suunto_nautic_parser_samples_foreach(): Invalid sample size"
        log.appendLibdc(level: "ERROR", message: error)
        log.appendLibdc(level: "ERROR", message: error)
        XCTAssertEqual(count(of: error, in: log.text()), 1)
    }

    func testWithFullLoggingOffShareLogIsTheText() throws {
        let log = makeLog()
        log.noteConnection("Connecting to Nautic", device: "Nautic")
        log.appendLibdc(level: "WARN", message: "suunto_nautic.c:400 suunto_nautic_device_open(): Busy")
        let items = log.makeShareItems()
        XCTAssertEqual(items.count, 1)
        let text = try XCTUnwrap(items.first as? String)
        XCTAssertTrue(text.hasPrefix("DC Tester "))
        XCTAssertTrue(text.contains("\nFull logging off: "))
        XCTAssertTrue(text.contains("\nDevice: Nautic\n"))
        XCTAssertTrue(text.hasSuffix(" [libdc WARN] suunto_nautic.c:400 suunto_nautic_device_open(): Busy"))
        log.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("full-log").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: shareDirectory.path))
    }

    func testTheFirstFullLoggingLineMakesItAFullLog() throws {
        let log = makeLog()
        // Auto download resumed at launch with the switch off, then reconnected at full logging.
        log.noteConnection("Auto download ON for Nautic", device: "Nautic")
        log.appendLibdc(level: "WARN", message: "suunto_nautic.c:400 suunto_nautic_device_open(): Busy")
        XCTAssertFalse(log.usedFullLogging)
        XCTAssertTrue(log.makeShareItems().first is String)

        log.appendLibdc(level: "INFO", message: read)
        XCTAssertTrue(log.usedFullLogging)
        let shared = try sharedLog(log.makeShareItems())
        XCTAssertTrue(shared.header.contains("Full logging ON (DC_LOGLEVEL_ALL) from "))
        XCTAssertTrue(shared.header.contains("Device: Nautic"))
        XCTAssertTrue(shared.log.contains("Auto download ON for Nautic"))
        XCTAssertTrue(shared.log.contains(read))
    }

    func testShareLogIsAZipOfTheWholeFullLog() throws {
        let log = makeLog(segmentBytes: 16 * 1024)
        log.noteConnection("Connecting to Nautic", device: "Nautic")
        let lines = (0..<6000).map { "iostream.c:200 dc_iostream_read(): Read: size=60, data=\(String(format: "%06d", $0))" }
        for (i, line) in lines.enumerated() {
            log.appendLibdc(level: "INFO", message: line)
            // A batch at a time, as the publishes write them, so the log spans segments.
            if i % 1000 == 999 { log.flush() }
        }

        let items = log.makeShareItems()
        XCTAssertEqual(items.count, 1)
        let zip = try XCTUnwrap(items.first as? URL)
        XCTAssertEqual(zip.pathExtension, "zip")
        XCTAssertTrue(zip.lastPathComponent.hasPrefix("DC-Tester-"), zip.lastPathComponent)
        let names = try Self.unzip(zip).keys.sorted()
        XCTAssertGreaterThanOrEqual(names.count, 7, "the header and a part for each batch: \(names)")
        XCTAssertTrue(names[0].hasSuffix("/part-000-header.txt"), names[0])
        XCTAssertEqual(Set(names.map { $0.components(separatedBy: "/").first! }), [zip.deletingPathExtension().lastPathComponent])

        let shared = try sharedLog(items)
        XCTAssertTrue(shared.header.contains("Full log: \(names.count - 1) part(s) after this header"), shared.header)
        XCTAssertFalse(shared.header.contains("truncated"))
        let reads = shared.log.split(separator: "\n").filter { $0.contains("[libdc INFO] ") }
        XCTAssertEqual(reads.map { String($0.suffix(lines[0].count)) }, lines, "every line, in order")
        XCTAssertFalse(FileManager.default.fileExists(atPath: zip.deletingPathExtension().path), "the staged parts are removed")

        log.append("After the first share")
        let again = try XCTUnwrap(log.makeShareItems().first as? URL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: zip.path) && zip != again, "the next share replaces it")
        XCTAssertTrue(try sharedLog([again]).log.hasSuffix("After the first share\n"))
    }

    /// trustthegoose's 21-dive Nautic run logged 56 MB, of which build 32 kept 32 MiB.
    func testAFullLogTwiceTheOldCapIsKeptWhole() throws {
        let store = FullLogStore(directory: directory.appendingPathComponent("full-log"))
        XCTAssertGreaterThanOrEqual(store.maxBytes, 30 * 3_000_000, "about 30 dives at 3 MB each")
        store.start(since: Date(), device: "Nautic", seed: [])
        let line = "2026-11-21 13:34:04.685 [libdc INFO] iostream.c:200 dc_iostream_read(): Read: size=60, data="
            + String(repeating: "7E", count: 60)
        let batch = Array(repeating: line, count: 4000)
        var written = 0
        while written < 64 * 1024 * 1024 {
            store.append(batch)
            written += batch.count * (line.utf8.count + 1)
        }
        XCTAssertEqual(store.byteCount, written)
        XCTAssertEqual(store.meta?.droppedLines, 0)

        let parts = try XCTUnwrap(store.exportParts(to: directory.appendingPathComponent("parts"), header: ["header"]))
        let sizes = try parts.dropFirst().map { try XCTUnwrap(FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int) }
        XCTAssertEqual(sizes.reduce(0, +), written)
        XCTAssertFalse(parts.contains { $0.lastPathComponent.contains("truncated") })
    }

    func testEveryLineHasADateAndMilliseconds() throws {
        let log = makeLog()
        log.append("Couldn't connect to Nautic.\nPress a button on the watch.")
        log.appendLibdc(level: "WARN", message: "suunto_nautic.c:400 suunto_nautic_device_open(): Busy")
        let lines = logLines(log.text())
        XCTAssertEqual(lines.count, 4, "the session line, both lines of the message, and the libdc line: \(lines)")
        for line in lines { XCTAssertTrue(isStamped(line), line) }
        XCTAssertTrue(lines[0].contains(" ===== Session started: DC Tester "), lines[0])
        XCTAssertTrue(lines[2].hasSuffix(" Press a button on the watch."), lines[2])
    }

    func testLinesFromAnEarlierBuildAreMarkedUndatedBeforeTheSessionStarts() throws {
        // Build 31 and 32 lines, without and with milliseconds, and a continuation line with no time.
        let earlier = ["14:46:21 Connecting to Suunto Nautic", "Press a button on the watch.",
                       "07:57:15.433 [LibDCSwift INFO] Bluetooth is powered on"]
        try Data((earlier.joined(separator: "\n") + "\n").utf8).write(to: directory.appendingPathComponent("explorer.log"))

        let log = makeLog()
        log.append("Connecting to Nautic")
        let lines = logLines(log.text())
        XCTAssertEqual(lines.count, 5, "\(lines)")
        XCTAssertEqual(Array(lines.prefix(3)), earlier.map { "undated " + $0 })
        XCTAssertTrue(isStamped(lines[3]) && lines[3].contains(" ===== Session started"), lines[3])
        XCTAssertTrue(isStamped(lines[4]) && lines[4].hasSuffix(" Connecting to Nautic"), lines[4])

        // Read back once more, they stay as they are.
        log.flush()
        XCTAssertEqual(Array(logLines(makeLog().text()).prefix(5)), lines)
    }

    func testEachSessionIsMarkedInTheFullLog() throws {
        do {
            let log = makeLog()
            log.noteConnection("Connecting to Nautic", device: "Nautic")
            log.appendLibdc(level: "INFO", message: read)
            log.flush()
        }
        let relaunched = makeLog()
        relaunched.append("After the relaunch")
        let shared = try sharedLog(relaunched.makeShareItems())
        XCTAssertTrue(shared.header.contains("\nThis session started "), shared.header)
        let lines = shared.log.split(separator: "\n").map(String.init)
        for line in lines { XCTAssertTrue(isStamped(line), line) }
        let sessions = lines.indices.filter { lines[$0].contains(" ===== Session started") }
        XCTAssertEqual(sessions.count, 2, lines.joined(separator: "\n"))
        XCTAssertEqual(sessions.first, 0)
        XCTAssertTrue(lines[sessions[1] - 1].hasSuffix(read))
        XCTAssertTrue(lines[sessions[1] + 1].hasSuffix(" After the relaunch"))
    }

    func testAFullLogSurvivesARelaunch() throws {
        let lines = (0..<2000).map { "iostream.c:200 dc_iostream_read(): Read: size=60, data=\(String(format: "%04d", $0))" }
        do {
            let log = makeLog()
            log.noteConnection("Connecting to Nautic", device: "Nautic")
            for line in lines { log.appendLibdc(level: "INFO", message: line) }
            // On disk, as the next publish would leave it before a crash.
            log.flush()
        }

        let relaunched = makeLog()
        XCTAssertTrue(relaunched.usedFullLogging)
        relaunched.append("After the relaunch")
        let shared = try sharedLog(relaunched.makeShareItems())
        XCTAssertTrue(shared.header.contains("Full logging ON (DC_LOGLEVEL_ALL) from "))
        XCTAssertTrue(shared.header.contains("Device: Nautic"))
        let reads = shared.log.components(separatedBy: "\n").filter { $0.contains("[libdc INFO] ") }
        XCTAssertEqual(reads.map { String($0.suffix(lines[0].count)) }, lines)
        XCTAssertTrue(shared.log.hasSuffix(" After the relaunch\n"))
    }

    /// A full log build 32 left on disk: a meta.json without a format, and lines with the time only.
    func testABuild32FullLogIsMarkedUndated() throws {
        let fullLog = directory.appendingPathComponent("full-log")
        try FileManager.default.createDirectory(at: fullLog, withIntermediateDirectories: true)
        let since = Date(timeIntervalSince1970: 1_795_000_000)
        let meta = #"{"since":\#(since.timeIntervalSinceReferenceDate),"device":"Nautic","droppedLines":0,"droppedBytes":0}"#
        try Data(meta.utf8).write(to: fullLog.appendingPathComponent("meta.json"))
        let old = ["13:33:45.456 Connecting to Nautic", "13:33:45.746 [libdc INFO] \(read)"]
        try Data((old.joined(separator: "\n") + "\n").utf8).write(to: fullLog.appendingPathComponent("segment-000000.log"))

        let log = makeLog()
        XCTAssertTrue(log.usedFullLogging)
        log.append("After the update")
        let shared = try sharedLog(log.makeShareItems())
        XCTAssertTrue(shared.header.contains("from \(LogStamp.string(since)):"), shared.header)
        let lines = shared.log.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 4, "\(lines)")
        XCTAssertEqual(Array(lines.prefix(2)), old.map { "undated " + $0 })
        XCTAssertTrue(lines[2].contains(" ===== Session started"), lines[2])
        XCTAssertTrue(lines[3].hasSuffix(" After the update"), lines[3])

        // Marked once: a relaunch leaves them as they are.
        let relaunched = makeLog()
        let again = try sharedLog(relaunched.makeShareItems()).log.split(separator: "\n").map(String.init)
        XCTAssertEqual(again, lines)
    }

    func testClearEndsTheFullLog() throws {
        let log = makeLog()
        log.appendLibdc(level: "INFO", message: read)
        _ = log.makeShareItems()
        log.clear()
        log.flush()
        XCTAssertFalse(log.usedFullLogging)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shareDirectory.path))
        XCTAssertFalse(makeLog().usedFullLogging)
    }

    func testAFullLogOverItsCapKeepsItsStartAndNewestLines() throws {
        let store = FullLogStore(directory: directory.appendingPathComponent("full-log"), maxBytes: 800, segmentBytes: 100)
        store.start(since: Date(), device: "Nautic", seed: [])
        // 10 bytes a line, so 10 a segment: 2 segments at the start and the newest 6 stay.
        for i in 0..<200 { store.append([String(format: "line %04d", i)]) }

        let parts = try XCTUnwrap(store.exportParts(to: directory.appendingPathComponent("out"), header: ["header"]))
        XCTAssertEqual(parts.map(\.lastPathComponent),
                       ["part-000-header.txt", "part-001.txt", "part-002.txt", "part-003-truncated.txt"] + (4...9).map { String(format: "part-%03d.txt", $0) })
        let header = try String(contentsOf: parts[0], encoding: .utf8)
        XCTAssertTrue(header.hasPrefix("header\nFull log: 9 part(s) after this header, 0.0 MB, part-001.txt to part-009.txt."), header)
        XCTAssertTrue(header.contains(" [log truncated: 120 lines (0.0 MB) dropped here to stay within 0.0 MB], at the -truncated part."))
        let lines = try joined(parts.dropFirst())
        XCTAssertEqual(Array(lines[0..<20]), (0..<20).map { String(format: "line %04d", $0) })
        XCTAssertEqual(lines[20], "[log truncated: 120 lines (0.0 MB) dropped here to stay within 0.0 MB]")
        XCTAssertEqual(Array(lines[21...]), (140..<200).map { String(format: "line %04d", $0) })

        let restored = FullLogStore(directory: directory.appendingPathComponent("full-log"), maxBytes: 800, segmentBytes: 100)
        let again = try XCTUnwrap(restored.exportParts(to: directory.appendingPathComponent("again"), header: ["header"]))
        XCTAssertEqual(try again.map { try Data(contentsOf: $0) }, try parts.map { try Data(contentsOf: $0) })
    }

    /// Build 33 opens a log build 32's 32 MiB cap truncated with its own larger cap: the gap stays the one place lines went.
    func testALogReopenedWithALargerCapKeepsItsGap() throws {
        let folder = directory.appendingPathComponent("full-log")
        let old = FullLogStore(directory: folder, maxBytes: 800, segmentBytes: 100)
        old.start(since: Date(), device: "Nautic", seed: [])
        for i in 0..<200 { old.append([String(format: "line %04d", i)]) }

        let store = FullLogStore(directory: folder, maxBytes: 1_200, segmentBytes: 100)
        for i in 200..<300 { store.append([String(format: "line %04d", i)]) }
        let parts = try XCTUnwrap(store.exportParts(to: directory.appendingPathComponent("out"), header: ["header"]))
        XCTAssertEqual(parts.filter { $0.lastPathComponent.contains("truncated") }.map(\.lastPathComponent), ["part-003-truncated.txt"])
        let lines = try joined(parts.dropFirst())
        XCTAssertEqual(Array(lines[0..<20]), (0..<20).map { String(format: "line %04d", $0) })
        XCTAssertEqual(lines[20], "[log truncated: 180 lines (0.0 MB) dropped here to stay within 0.0 MB]")
        XCTAssertEqual(Array(lines[21...]), (200..<300).map { String(format: "line %04d", $0) })
    }

    func testAnExportLeavesOutLinesWrittenAfterIt() throws {
        let store = FullLogStore(directory: directory.appendingPathComponent("full-log"), maxBytes: 10_000, segmentBytes: 100)
        store.start(since: Date(), device: "Nautic", seed: [])
        for i in 0..<15 { store.append([String(format: "line %04d", i)]) }
        let parts = try XCTUnwrap(store.exportParts(to: directory.appendingPathComponent("out"), header: ["header"]))
        // The open segment, which this lands in, was copied, not linked.
        store.append(["line 0015"])
        XCTAssertEqual(try joined(parts.dropFirst()), (0..<15).map { String(format: "line %04d", $0) })
    }

    // MARK: - Helpers

    private func count(of line: String, in text: String) -> Int {
        text.components(separatedBy: "\n").filter { $0.hasSuffix(line) }.count
    }

    private func isStamped(_ line: String) -> Bool {
        stamp.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    private func joined<S: Sequence>(_ parts: S) throws -> [String] where S.Element == URL {
        try parts.map { try String(contentsOf: $0, encoding: .utf8) }.joined().split(separator: "\n").map(String.init)
    }

    /// The log lines of a text Share log gives: what follows the header's blank line.
    private func logLines(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n").dropFirst().joined(separator: "\n\n").split(separator: "\n").map(String.init)
    }

    /// A full log's header and its parts joined, from the zip Share log gives or from the parts.
    private func sharedLog(_ items: [Any]) throws -> (header: String, log: String) {
        var parts: [(name: String, data: Data)]
        if items.count == 1, let url = items.first as? URL, url.pathExtension == "zip" {
            parts = try Self.unzip(url).map { ($0.key, $0.value) }
        } else {
            parts = try items.map { try XCTUnwrap($0 as? URL) }.map { ($0.lastPathComponent, try Data(contentsOf: $0)) }
        }
        parts.sort { $0.name < $1.name }
        let header = try XCTUnwrap(parts.first)
        XCTAssertTrue(header.name.hasSuffix("part-000-header.txt"), header.name)
        return (String(decoding: header.data, as: UTF8.self), parts.dropFirst().map { String(decoding: $0.data, as: UTF8.self) }.joined())
    }

    /// The files of a zip by path, from its central directory: stored or deflated entries, no ZIP64.
    static func unzip(_ url: URL) throws -> [String: Data] {
        let bytes = [UInt8](try Data(contentsOf: url))
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        let end = try XCTUnwrap(stride(from: bytes.count - 22, through: max(0, bytes.count - 22 - 65_535), by: -1)
            .first { u32($0) == 0x0605_4B50 }, "no end of central directory")
        var offset = u32(end + 16)
        var files: [String: Data] = [:]
        for _ in 0..<u16(end + 10) {
            XCTAssertEqual(u32(offset), 0x0201_4B50)
            let method = u16(offset + 10)
            let compressed = u32(offset + 20)
            let size = u32(offset + 24)
            let nameLength = u16(offset + 28)
            let local = u32(offset + 42)
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            offset += 46 + nameLength + u16(offset + 30) + u16(offset + 32)
            guard !name.hasSuffix("/"), !name.hasPrefix("__MACOSX") else { continue }
            XCTAssertEqual(u32(local), 0x0403_4B50)
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            let payload = Array(bytes[start..<(start + compressed)])
            switch method {
            case 0:
                files[name] = Data(payload)
            case 8:
                var out = [UInt8](repeating: 0, count: max(size, 1))
                let decoded = compression_decode_buffer(&out, out.count, payload, payload.count, nil, COMPRESSION_ZLIB)
                XCTAssertEqual(decoded, size, name)
                files[name] = Data(out.prefix(size))
            default:
                XCTFail("\(name): compression method \(method)")
            }
        }
        return files
    }
}
