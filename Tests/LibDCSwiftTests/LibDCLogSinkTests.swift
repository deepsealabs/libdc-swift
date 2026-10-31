import XCTest
@testable import LibDCSwift

/// libdivecomputer's ERROR lines reach the host log sink, not only the console. A tester's
/// Share log depends on this to say why a download failed (e.g. "Invalid logbook end
/// pointer" behind a bare DC_STATUS_DATAFORMAT).
final class LibDCLogSinkTests: XCTestCase {

    private static var received: [(level: String, message: String)] = []

    override func tearDown() {
        set_libdc_log_sink(nil)
        Self.received = []
        super.tearDown()
    }

    func testParserErrorReachesSinkWithLevelAndSource() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "suunto_nautic_1787752091", withExtension: "sbem"))
        let dive = Data("SBEM9999".utf8) + (try Data(contentsOf: url)).dropFirst(8)

        var context: OpaquePointer?
        XCTAssertEqual(dc_context_new(&context), DC_STATUS_SUCCESS)
        defer { dc_context_free(context) }
        attach_libdc_log(context)
        set_libdc_log_sink { level, message in
            LibDCLogSinkTests.received.append((String(cString: level!), String(cString: message!)))
        }

        _ = try? dive.withUnsafeBytes { raw in
            try GenericParser.parseDiveData(
                family: .suuntoNautic, model: 0, diveNumber: 1,
                diveData: raw.bindMemory(to: UInt8.self).baseAddress!, dataSize: dive.count,
                context: context)
        }

        let error = try XCTUnwrap(Self.received.first { $0.message.contains("Unexpected magic") },
                                  "parser ERROR never reached the sink: \(Self.received)")
        XCTAssertEqual(error.level, "ERROR")
        XCTAssertTrue(error.message.hasPrefix("suunto_nautic_parser.c:"), "file:line prefix, no build path: \(error.message)")

        // Cleared sink: console only, nothing more delivered.
        set_libdc_log_sink(nil)
        let count = Self.received.count
        _ = try? dive.withUnsafeBytes { raw in
            try GenericParser.parseDiveData(
                family: .suuntoNautic, model: 0, diveNumber: 1,
                diveData: raw.bindMemory(to: UInt8.self).baseAddress!, dataSize: dive.count,
                context: context)
        }
        XCTAssertEqual(Self.received.count, count)
    }
}
