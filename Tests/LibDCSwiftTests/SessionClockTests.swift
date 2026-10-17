import XCTest
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// Reefnet Sensus dates dives by device ticks, so the real driver runs over a serial fake through a session.
final class SessionClockTests: XCTestCase {

    /// The Sensus wire protocol: 0x0A gets "OK" + a 10-byte handshake, 0x40 gets "DATA" + memory + sum + "END".
    final class FakeSensus {
        static let memorySize = 32768
        var handshake: [UInt8]
        var memory: [UInt8]
        private var tx: [UInt8] = []
        private var txIndex = 0
        private let lock = NSLock()

        init(model: UInt8 = 1, serial: UInt16, devtime: UInt32, dives: [(offset: Int, bytes: [UInt8])]) {
            handshake = Array("OK".utf8) + [0x30 + model, 0x31, 0x00, 0x00]
                + [UInt8(serial & 0xFF), UInt8(serial >> 8)]
                + (0..<4).map { UInt8((devtime >> (8 * UInt32($0))) & 0xFF) }
            memory = [UInt8](repeating: 0, count: Self.memorySize)
            for dive in dives { memory.replaceSubrange(dive.offset..<(dive.offset + dive.bytes.count), with: dive.bytes) }
        }

        func hostWrote(_ bytes: UnsafeRawBufferPointer) {
            lock.lock(); defer { lock.unlock() }
            for b in bytes {
                switch b {
                case 0x0A:
                    tx += handshake
                case 0x40:
                    let sum = memory.reduce(UInt16(0)) { $0 &+ UInt16($1) }
                    tx += Array("DATA".utf8) + memory + [UInt8(sum & 0xFF), UInt8(sum >> 8)] + Array("END".utf8)
                default:
                    break
                }
            }
        }

        func hostRead(into buffer: UnsafeMutableRawPointer, size: Int) -> Int {
            lock.lock(); defer { lock.unlock() }
            let n = min(size, tx.count - txIndex)
            guard n > 0 else { return 0 }
            tx.withUnsafeBufferPointer { buffer.copyMemory(from: $0.baseAddress! + txIndex, byteCount: n) }
            txIndex += n
            return n
        }
    }

    /// 0xFF, interval, LE32 tick timestamp, 0xFE, then depths (a temperature byte every sixth) ending in 17 shallow ones.
    static func dive(timestamp: UInt32, interval: UInt8 = 10) -> [UInt8] {
        var bytes: [UInt8] = [0xFF, interval] + (0..<4).map { UInt8((timestamp >> (8 * UInt32($0))) & 0xFF) } + [0xFE]
        let depths: [UInt8] = [30, 50, 70, 90, 90, 70, 50, 30] + [UInt8](repeating: 0, count: 17)
        for (i, depth) in depths.enumerated() {
            bytes.append(depth)
            if i % 6 == 0 { bytes.append(72) }
        }
        return bytes
    }

    private var keepAlive: [AnyObject] = []

    override func tearDown() {
        keepAlive.removeAll()
        super.tearDown()
    }

    private static func fake(_ userdata: UnsafeMutableRawPointer?) -> FakeSensus {
        Unmanaged<FakeSensus>.fromOpaque(userdata!).takeUnretainedValue()
    }

    private func openSession(_ fake: FakeSensus, lease: DiveComputerSessionLease = DiveComputerSessionLease()) throws -> DiveComputerSession {
        keepAlive.append(fake)
        var context: OpaquePointer?
        XCTAssertEqual(dc_context_new(&context), DC_STATUS_SUCCESS)
        var cbs = dc_custom_cbs_t()
        cbs.read = { userdata, data, size, actual in
            let n = SessionClockTests.fake(userdata).hostRead(into: data!, size: size)
            actual?.pointee = n
            return n == 0 ? DC_STATUS_TIMEOUT : DC_STATUS_SUCCESS
        }
        cbs.write = { userdata, data, size, actual in
            SessionClockTests.fake(userdata).hostWrote(UnsafeRawBufferPointer(start: data, count: size))
            actual?.pointee = size
            return DC_STATUS_SUCCESS
        }
        var iostream: OpaquePointer?
        XCTAssertEqual(dc_custom_open(&iostream, context, DC_TRANSPORT_SERIAL, &cbs, Unmanaged.passUnretained(fake).toOpaque()), DC_STATUS_SUCCESS)
        let session = try DiveComputerSession.open(
            iostream: try XCTUnwrap(iostream), context: try XCTUnwrap(context),
            family: DC_FAMILY_REEFNET_SENSUS, model: 1,
            displayName: "Reefnet Sensus", storageKey: "serial:sensus",
            deviceStorage: DeviceStorage(userDefaults: isolatedSuite("dev")), lease: lease)
        addTeardownBlock { session.close() }
        return session
    }

    private func isolatedSuite(_ name: String) -> UserDefaults {
        let suiteName = "com.libdcswift.tests.clock.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func download(_ session: DiveComputerSession, viewModel: DiveDataViewModel) -> DiveDownloadResult? {
        let done = expectation(description: "download")
        var result: DiveDownloadResult?
        DiveLogRetriever.retrieveDiveLogs(session: session, viewModel: viewModel) { result = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        let drained = expectation(description: "drain")
        DispatchQueue.main.async { DispatchQueue.main.async { drained.fulfill() } }
        wait(for: [drained], timeout: 2)
        return result
    }

    func testTheDownloadDatesDivesFromTheDeviceClock() throws {
        let devtime: UInt32 = 5_000_000
        let older: UInt32 = devtime - 86_400, newer: UInt32 = devtime - 3_600
        let fake = FakeSensus(serial: 0x1234, devtime: devtime,
                              dives: [(100, Self.dive(timestamp: older)), (400, Self.dive(timestamp: newer))])
        let session = try openSession(fake)
        let viewModel = DiveDataViewModel(fingerprintStore: DeviceFingerprintStorage(userDefaults: isolatedSuite("fp")))

        let before = Date().timeIntervalSince1970.rounded(.down)
        let result = try XCTUnwrap(download(session, viewModel: viewModel))
        let after = Date().timeIntervalSince1970.rounded(.up)

        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.divesDownloaded, 2)
        XCTAssertEqual(session.devicePtr.pointee.have_clock, 1)
        XCTAssertEqual(session.devicePtr.pointee.clock.devtime, devtime)
        let dates = viewModel.dives.map(\.datetime.timeIntervalSince1970).sorted()
        XCTAssertEqual(dates.count, 2)
        // The host read its clock during the handshake, between before and after.
        XCTAssertGreaterThanOrEqual(dates[0], before - 86_400)
        XCTAssertLessThanOrEqual(dates[0], after - 86_400)
        XCTAssertGreaterThanOrEqual(dates[1], before - 3_600)
        XCTAssertLessThanOrEqual(dates[1], after - 3_600)

        let commit = try XCTUnwrap(result.fingerprintCommit)
        XCTAssertEqual(commit.fingerprint, Data((0..<4).map { UInt8((newer >> (8 * UInt32($0))) & 0xFF) }))
        XCTAssertEqual(commit.serial, "00001234")
        XCTAssertEqual(commit.deviceType, "Reefnet Sensus")
    }

    func testAHardwareModelNoDescriptorKnowsParsesWithTheOpenedDescriptor() throws {
        XCTAssertFalse(DeviceConfiguration.hasDescriptor(family: DC_FAMILY_REEFNET_SENSUS, model: 7))
        let fake = FakeSensus(model: 7, serial: 1, devtime: 1_000_000, dives: [(200, Self.dive(timestamp: 999_000))])
        let session = try openSession(fake)
        let viewModel = DiveDataViewModel(fingerprintStore: DeviceFingerprintStorage(userDefaults: isolatedSuite("fp")))

        let result = try XCTUnwrap(download(session, viewModel: viewModel))
        XCTAssertEqual(session.devicePtr.pointee.devinfo.model, 7)
        XCTAssertEqual(result.outcome, .completed)
        XCTAssertEqual(result.parseFailureCount, 0)
        XCTAssertEqual(viewModel.dives.count, 1)
        XCTAssertNotNil(result.fingerprintCommit)
    }

    // MARK: - Parser

    private func parse(_ bytes: [UInt8], clock: GenericParser.DeviceClock?) throws -> DiveData {
        try bytes.withUnsafeBufferPointer {
            try GenericParser.parseDiveData(dcFamily: DC_FAMILY_REEFNET_SENSUS, model: 1, diveNumber: 1,
                                            diveData: $0.baseAddress!, dataSize: bytes.count, clock: clock)
        }
    }

    func testTheClockPairPlacesTheDiveRelativeToTheHostTime() throws {
        let systime: dc_ticks_t = 1_760_000_000
        let dive = try parse(Self.dive(timestamp: 46_400), clock: .init(devtime: 50_000, systime: systime))
        XCTAssertEqual(dive.datetime, Date(timeIntervalSince1970: TimeInterval(systime - 3_600)))
        XCTAssertEqual(dive.divetime, 250)
    }

    func testWithoutTheClockTheTicksReadAsSecondsSince1970() throws {
        let dive = try parse(Self.dive(timestamp: 46_400), clock: nil)
        XCTAssertEqual(dive.datetime, Date(timeIntervalSince1970: 46_400))
    }

    func testParsersWithoutAClockHookIgnoreIt() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "suunto_nautic_1787752091", withExtension: "sbem"))
        let bytes = [UInt8](try Data(contentsOf: url))
        let parsed: (GenericParser.DeviceClock?) throws -> DiveData = { clock in
            try bytes.withUnsafeBufferPointer {
                try GenericParser.parseDiveData(dcFamily: DC_FAMILY_SUUNTO_NAUTIC, model: 1, diveNumber: 1,
                                                diveData: $0.baseAddress!, dataSize: bytes.count, clock: clock)
            }
        }
        let with = try parsed(.init(devtime: 1, systime: 2))
        let without = try parsed(nil)
        XCTAssertEqual(with.datetime, without.datetime)
        XCTAssertEqual(with.profile.count, without.profile.count)
    }
}
