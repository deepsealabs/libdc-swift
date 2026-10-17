#if os(macOS)
import XCTest
import IOKit
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

enum EONSteelWire {
    static let packetSize = 64
    static let reportID: UInt8 = 0x3f
    static let headerSize = 12
    static let cmdInit: UInt16 = 0x0000
    static let cmdFileOpen: UInt16 = 0x0010
    static let cmdFileRead: UInt16 = 0x0110
    static let cmdFileClose: UInt16 = 0x0510
    static let cmdFileStat: UInt16 = 0x0710
    static let cmdDirOpen: UInt16 = 0x0810
    static let cmdDirReaddir: UInt16 = 0x0910
    static let cmdDirClose: UInt16 = 0x0a10

    static func u16(_ bytes: [UInt8], _ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
    static func u32(_ bytes: [UInt8], _ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(bytes[at + $1]) << (8 * UInt32($1)) } }
    static func le16(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xff), UInt8(value >> 8)] }
    static func le32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> (8 * UInt32($0))) } }

    /// libdivecomputer's checksum_crc32r: reflected CRC-32 (0xEDB88320), as suunto_eonsteel_send computes it.
    static func crc32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1 }
        }
        return ~crc
    }
}

/// An EON Steel family computer on USB HID, built from suunto_eonsteel.c: INIT, the dive directory, and `dives` served as files. Values are synthetic.
final class FakeEONSteel: @unchecked Sendable {
    typealias Wire = EONSteelWire

    /// ASCII digits at version + 0x10, which the driver reads as DEVINFO's serial.
    let serialDigits: String
    let firmware: UInt32
    /// Newest first or not: the driver sorts by name.
    var dives: [(name: String, bytes: [UInt8])]
    /// Answers INIT, then nothing, as a computer pulled off its clip does.
    var silentAfterInit = false

    private let lock = NSLock()
    private var commandLog: [UInt16] = []
    private var crcFailures = 0
    private var otherFailures: [String] = []
    private var openFile: [UInt8]?
    private var readOffset = 0
    private static let initMagic: UInt32 = 0x00a5_0000

    init(serialDigits: String = "0001234567", firmware: UInt32 = 0x0201_0300, dives: [(name: String, bytes: [UInt8])] = []) {
        self.serialDigits = serialDigits
        self.firmware = firmware
        self.dives = dives
    }

    var commands: [UInt16] {
        lock.lock(); defer { lock.unlock() }
        return commandLog
    }

    /// Packets whose CRC or framing didn't match what suunto_eonsteel_send builds.
    var malformed: [String] {
        lock.lock(); defer { lock.unlock() }
        return (crcFailures > 0 ? ["\(crcFailures) bad CRCs"] : []) + otherFailures
    }

    func attach(to device: FakeHIDDevice) {
        device.computer = { [self] id, bytes in answer(reportID: id, bytes: bytes) }
    }

    /// The 48-byte version block CMD_INIT returns.
    var version: [UInt8] {
        var block = [UInt8](repeating: 0, count: 0x30)
        block.replaceSubrange(0x10..<(0x10 + serialDigits.utf8.count), with: Array(serialDigits.utf8))
        block.replaceSubrange(0x20..<0x24, with: Wire.le32(firmware).reversed())
        return block
    }

    func answer(reportID: Int, bytes: [UInt8]) -> [[UInt8]] {
        lock.lock(); defer { lock.unlock() }
        guard reportID == Int(Wire.reportID), bytes.count == Wire.packetSize, bytes[0] == Wire.reportID else {
            otherFailures.append("report id \(reportID), \(bytes.count) bytes, byte 0 \(bytes.first ?? 0)")
            return []
        }
        let size = Int(Wire.u32(bytes, 10))
        let crcEnd = 14 + size
        // The driver writes 64 of its 68 bytes, so the CRC goes out only for short commands, as every command here is.
        guard Int(bytes[1]) == size + Wire.headerSize, crcEnd + 4 <= bytes.count else {
            otherFailures.append("length byte \(bytes[1]) for \(size) data bytes")
            return []
        }
        if Wire.crc32(bytes[2..<crcEnd]) != Wire.u32(bytes, crcEnd) { crcFailures += 1 }
        let command = Wire.u16(bytes, 2)
        let magic = Wire.u32(bytes, 4)
        let sequence = Wire.u16(bytes, 8)
        let data = Array(bytes[14..<crcEnd])
        commandLog.append(command)
        if silentAfterInit, command != Wire.cmdInit { return [] }

        let payload: [UInt8]
        switch command {
        case Wire.cmdInit:
            return Self.packets(command: command, magic: Self.initMagic, sequence: sequence, payload: version)
        case Wire.cmdDirOpen:
            let path = String(decoding: data.dropFirst(4).prefix { $0 != 0 }, as: UTF8.self)
            if path != "0:/dives" { otherFailures.append("opened directory \(path)") }
            payload = []
        case Wire.cmdDirReaddir:
            var entries: [UInt8] = []
            for dive in dives {
                let name = Array(dive.name.utf8)
                entries += Wire.le32(1) + Wire.le32(UInt32(name.count)) + name + [0]
            }
            payload = Wire.le32(UInt32(dives.count)) + Wire.le32(1) + entries
        case Wire.cmdFileOpen:
            let path = String(decoding: data.dropFirst(4).prefix { $0 != 0 }, as: UTF8.self)
            openFile = dives.first { "0:/dives/" + $0.name == path }?.bytes
            readOffset = 0
            if openFile == nil { otherFailures.append("opened \(path)") }
            payload = []
        case Wire.cmdFileStat:
            payload = Wire.le32(0) + Wire.le32(UInt32(openFile?.count ?? 0))
        case Wire.cmdFileRead:
            let file = openFile ?? []
            let ask = Int(Wire.u32(data, 4))
            let chunk = Array(file[min(readOffset, file.count)..<min(readOffset + ask, file.count)])
            readOffset += chunk.count
            payload = Wire.le32(Wire.u32(data, 0)) + Wire.le32(UInt32(chunk.count)) + chunk
        case Wire.cmdFileClose, Wire.cmdDirClose:
            openFile = nil
            payload = []
        default:
            otherFailures.append(String(format: "unknown command %04x", command))
            return []
        }
        // The driver checks the reply's magic is its own plus 5.
        return Self.packets(command: command, magic: magic &+ 5, sequence: sequence, payload: payload)
    }

    /// One reply as the computer frames it: 64-byte reports of 0x3f, a length byte and up to 62 bytes of header and payload.
    static func packets(command: UInt16, magic: UInt32, sequence: UInt16, payload: [UInt8]) -> [[UInt8]] {
        let body = Wire.le16(command) + Wire.le32(magic) + Wire.le16(sequence) + Wire.le32(UInt32(payload.count)) + payload
        var reports: [[UInt8]] = []
        var offset = 0
        repeat {
            let chunk = Array(body[offset..<min(offset + Wire.packetSize - 2, body.count)])
            var report = [Wire.reportID, UInt8(chunk.count)] + chunk
            report += [UInt8](repeating: 0, count: Wire.packetSize - report.count)
            reports.append(report)
            offset += chunk.count
        } while offset < body.count
        return reports
    }
}

/// A Scubapro G2 family computer on USB HID, built from uwatec_smart.c: the handshake and the dump's model, serial, clock and size, with no dives. Values are synthetic.
final class FakeG2: @unchecked Sendable {
    static let outputSize = 32
    static let inputSize = 64

    var model: UInt8
    let serial: UInt32
    let devtime: UInt32
    var silent = false

    private let lock = NSLock()
    private var commandLog: [UInt8] = []
    private var badReports: [String] = []

    init(model: UInt8 = 0x32, serial: UInt32 = 0x0012_D687, devtime: UInt32 = 0x0100_0000) {
        self.model = model
        self.serial = serial
        self.devtime = devtime
    }

    var commands: [UInt8] {
        lock.lock(); defer { lock.unlock() }
        return commandLog
    }

    var malformed: [String] {
        lock.lock(); defer { lock.unlock() }
        return badReports
    }

    func attach(to device: FakeHIDDevice) {
        device.computer = { [self] id, bytes in answer(reportID: id, bytes: bytes) }
    }

    // uwatec_smart_usbhid_send writes [0, size + 1, cmd, data] padded to 33; with the zero report ID dropped, 32 bytes arrive.
    func answer(reportID: Int, bytes: [UInt8]) -> [[UInt8]] {
        lock.lock(); defer { lock.unlock() }
        guard reportID == 0, bytes.count == Self.outputSize, bytes[0] >= 1 else {
            badReports.append("report id \(reportID), \(bytes.count) bytes")
            return []
        }
        let command = bytes[1]
        commandLog.append(command)
        if silent { return [] }
        let payload: [UInt8]
        switch command {
        case 0x1B, 0x1C: payload = [0x01]
        case 0x10: payload = [model]
        case 0x11: payload = [0x01]
        case 0x13: payload = [0x14]
        case 0x14: payload = EONSteelWire.le32(serial)
        case 0x1A: payload = EONSteelWire.le32(devtime)
        case 0xC6: payload = EONSteelWire.le32(0)
        default:
            badReports.append(String(format: "unknown command %02x", command))
            return []
        }
        var report = [UInt8(payload.count)] + payload
        report += [UInt8](repeating: 0, count: Self.inputSize - report.count)
        return [report]
    }
}

enum HIDFixtures {
    static let eonSteelID: UInt64 = 0x1_0000_0E05
    static let g2ID: UInt64 = 0x1_0000_0062

    static let eonSteelDevice = RegistrySnapshot.HIDDevice(registryID: eonSteelID, vendorID: 0x1493, productID: 0x0030,
                                                           productName: "EON Steel")

    static var eonSteel: CableEndpoint {
        CableEndpoint.usbHIDDevice(registryID: eonSteelID, vendorID: 0x1493, productID: 0x0030, productName: "EON Steel")!
    }

    static var g2: CableEndpoint {
        CableEndpoint.usbHIDDevice(registryID: g2ID, vendorID: 0x2e6c, productID: 0x3201, productName: "G2")!
    }

    static func model(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> DCModel {
        try XCTUnwrap(DeviceCatalog.models(for: .usbHID).first { $0.name == name }, "no USB HID model \(name)", file: file, line: line)
    }
}

/// Hands out a fresh fake per open, as IOKitHIDDevice.make creates a fresh IOHIDDevice; a cancelled one can't be scheduled again.
final class FakeHIDFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let make: () -> FakeHIDDevice?
    private var made: [FakeHIDDevice] = []
    private var requested: [CableEndpoint.ID] = []

    init(_ make: @escaping () -> FakeHIDDevice?) {
        self.make = make
    }

    var devices: [FakeHIDDevice] {
        lock.lock(); defer { lock.unlock() }
        return made
    }

    var requests: [CableEndpoint.ID] {
        lock.lock(); defer { lock.unlock() }
        return requested
    }

    var factory: HIDDeviceFactory {
        { [self] endpoint in
            let device = make()
            lock.lock()
            requested.append(endpoint.id)
            if let device { made.append(device) }
            lock.unlock()
            return device
        }
    }
}
#endif
