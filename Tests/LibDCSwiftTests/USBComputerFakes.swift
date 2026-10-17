#if os(macOS)
import XCTest
import IOKit
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// An Atomic Aquatics Cobalt as atomics_cobalt.c talks to it: vendor requests 0x01 (version), 0x09 (newest dive) and 0x0A (next), each answered on bulk IN under a 16-bit additive checksum.
final class FakeCobalt: @unchecked Sendable {
    static let vendorDeviceOut = USBControl.vendorDeviceOut
    static let cmdVersion: UInt8 = 0x01
    static let cmdFirstDive: UInt8 = 0x09
    static let cmdNextDive: UInt8 = 0x0A

    let version: [UInt8]
    /// Newest first, as the computer sends them.
    let dives: [[UInt8]]
    /// Answers nothing from this command on, as a computer that left its PC mode would.
    var silentFrom: UInt8?
    private let lock = NSLock()
    private var log: [UInt8] = []
    private var broken: [String] = []
    private var next = 0
    private var silent = false

    /// `serialDigits` is the 8 ASCII digits the version block starts with; `model` 0 is a Cobalt, 2 a Cobalt 2.
    init(serialDigits: String = "00012345", firmware: (UInt16, UInt16) = (2, 7), model: UInt16 = 2, dives: [[UInt8]] = []) {
        precondition(serialDigits.utf8.count == 8 && serialDigits.allSatisfy(\.isNumber))
        version = Array(serialDigits.utf8) + Self.le16(firmware.0) + Self.le16(firmware.1) + Self.le16(model)
        self.dives = dives
    }

    var commands: [UInt8] {
        lock.lock(); defer { lock.unlock() }
        return log
    }

    /// Control requests that weren't the vendor, device, OUT, no-data request the driver builds.
    var malformed: [String] {
        lock.lock(); defer { lock.unlock() }
        return broken
    }

    func attach(to device: FakeUSBDevice) {
        device.onControl = { [self] setup, _ in self.handle(setup) }
    }

    private func handle(_ setup: FakeUSBDevice.Setup) -> (result: IOReturn, dataStage: [UInt8], response: [UInt8]?) {
        lock.lock()
        defer { lock.unlock() }
        if setup.bmRequestType != Self.vendorDeviceOut || setup.wValue != 0 || setup.wIndex != 0 || setup.wLength != 0 {
            broken.append(setup.description)
        }
        log.append(setup.bRequest)
        if setup.bRequest == silentFrom { silent = true }
        if silent { return (kIOReturnSuccess, [], nil) }
        switch setup.bRequest {
        case Self.cmdVersion:
            return (kIOReturnSuccess, [], Self.withChecksum(version))
        case Self.cmdFirstDive, Self.cmdNextDive:
            if setup.bRequest == Self.cmdFirstDive { next = 0 }
            guard next < dives.count else { return (kIOReturnSuccess, [], [0xFF, 0xFF]) }
            defer { next += 1 }
            return (kIOReturnSuccess, [], Self.withChecksum(dives[next]))
        default:
            return (USBReturn.pipeStalled, [], nil)
        }
    }

    static func withChecksum(_ bytes: [UInt8]) -> [UInt8] {
        bytes + le16(UInt16(truncatingIfNeeded: bytes.reduce(0) { $0 &+ Int($1) }))
    }

    static func le16(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8)]
    }
}

/// A synthetic dive as atomics_cobalt_parser.c reads it: a 228-byte header, one 18-byte gas mix, one 16-byte segment per sample; the 6 bytes at 0x14 are its fingerprint.
enum CobaltDive {
    static let headerSize = 228
    static let atmosphericMbar: UInt16 = 1013
    static let gasMixID: UInt8 = 1

    /// `depthsMbar` is each sample's pressure above the surface, in millibar; `trailer` follows the last whole segment, where the parser stops.
    static func make(year: UInt16, month: UInt8, day: UInt8, hour: UInt8, minute: UInt8, depthsMbar: [UInt16],
                     interval: UInt8 = 30, temperatureF: UInt8 = 72, oxygenPercent: UInt8 = 32,
                     trailer: [UInt8] = []) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: headerSize)
        func put16(_ value: UInt16, at offset: Int) {
            header[offset] = UInt8(value & 0xFF)
            header[offset + 1] = UInt8(value >> 8)
        }
        put16(year, at: 0x14)
        header[0x16] = month
        header[0x17] = day
        header[0x18] = hour
        header[0x19] = minute
        header[0x1A] = interval
        header[0x1B] = temperatureF
        header[0x24] = 2 // open circuit nitrox
        put16(atmosphericMbar, at: 0x26)
        header[0x2A] = 1 // gas mixes
        header[0x2B] = 0 // gas switches
        put16(UInt16(depthsMbar.count), at: 0x50)
        put16(atmosphericMbar + (depthsMbar.max() ?? 0), at: 0x56)
        put16(UInt16(depthsMbar.count * Int(interval) / 60), at: 0x58)

        var gas = [UInt8](repeating: 0, count: 18)
        gas[0] = gasMixID
        gas[2] = 3 // wet volume in 1/10 litre
        gas[4] = oxygenPercent
        gas.replaceSubrange(6..<8, with: FakeCobalt.le16(3000)) // psi
        gas.replaceSubrange(8..<10, with: FakeCobalt.le16(120))
        gas.replaceSubrange(12..<14, with: FakeCobalt.le16(1)) // the primary tank's sensor
        gas.replaceSubrange(14..<16, with: FakeCobalt.le16(700))

        var segments: [UInt8] = []
        for (i, depth) in depthsMbar.enumerated() {
            var segment = [UInt8](repeating: 0, count: 16)
            segment.replaceSubrange(0..<2, with: FakeCobalt.le16(atmosphericMbar + depth))
            segment.replaceSubrange(2..<4, with: FakeCobalt.le16(UInt16(max(500, 3000 - 4 * i))))
            segment[4] = gasMixID
            segment[5] = 40 // NDL minutes
            segment[8] = temperatureF
            segments += segment
        }
        return header + gas + segments + trailer
    }

    /// `count` samples down to `maxMbar` and back, as a plain profile.
    static func profile(_ count: Int, maxMbar: UInt16) -> [UInt16] {
        (0..<count).map { i in
            let half = Double(count - 1) / 2
            return UInt16((1 - abs(Double(i) - half) / max(half, 1)) * Double(maxMbar) * 0.9 + Double(maxMbar) * 0.1)
        }
    }

    /// The fingerprint atomics_cobalt.c reports: the 6 bytes at 0x14.
    static func fingerprint(_ dive: [UInt8]) -> Data {
        Data(dive[0x14..<0x1A])
    }

    /// What the parser makes of `millibar` above the surface: depth in salt water.
    static func depthMetres(_ millibar: UInt16) -> Double {
        Double(millibar) * (100_000.0 / 1000.0) / (1025.0 * 9.80665)
    }
}

enum USBFixtures {
    static let cobaltID: UInt64 = 0x1_0000_0C0B
    static let cobaltDevice = RegistrySnapshot.USBDevice(registryID: cobaltID, vendorID: 0x0471, productID: 0x0888)
    static let layout = USBComputers.all[0]

    static var cobalt: CableEndpoint {
        CableEndpoint.usbDevice(registryID: cobaltID, vendorID: 0x0471, productID: 0x0888)!
    }

    static func model(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> DCModel {
        try XCTUnwrap(DeviceCatalog.models(for: .usb).first { $0.name == name }, "no USB model \(name)", file: file, line: line)
    }

}

/// Hands out a fresh fake per open, as IOKitUSBDevice.make opens the interface again each time.
final class FakeUSBFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let make: () throws -> FakeUSBDevice
    private var made: [FakeUSBDevice] = []
    private var requested: [(id: CableEndpoint.ID, layout: USBInterfaceLayout)] = []

    init(_ make: @escaping () throws -> FakeUSBDevice) {
        self.make = make
    }

    convenience init(_ cobalt: FakeCobalt, configure: @escaping (FakeUSBDevice) -> Void = { _ in }) {
        self.init {
            let device = FakeUSBDevice()
            cobalt.attach(to: device)
            configure(device)
            return device
        }
    }

    var devices: [FakeUSBDevice] {
        lock.lock(); defer { lock.unlock() }
        return made
    }

    var requests: [(id: CableEndpoint.ID, layout: USBInterfaceLayout)] {
        lock.lock(); defer { lock.unlock() }
        return requested
    }

    var factory: USBDeviceFactory {
        { [self] endpoint, layout in
            lock.lock()
            requested.append((endpoint.id, layout))
            lock.unlock()
            let device = try make()
            lock.lock()
            made.append(device)
            lock.unlock()
            return device
        }
    }
}
#endif
