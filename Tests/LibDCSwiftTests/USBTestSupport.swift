#if os(macOS)
import XCTest
import IOKit
import IOKit.usb
import Clibdivecomputer
import LibDCBridge
@testable import LibDCSwift

/// IOUSBFamily codes Swift can't import: iokit_usb_err(0x4f) and iokit_usb_err(0x51).
enum USBReturn {
    static let pipeStalled = IOReturn(bitPattern: 0xE000_404F)
    static let transactionTimeout = IOReturn(bitPattern: 0xE000_4051)
}

/// A claimed USB interface with bulk transfer rules (max-size packets, a short packet ends a transfer, a bigger one overruns it, silence waits out the timeout); it logs every call.
final class FakeUSBDevice: NSObject, USBDeviceIO, @unchecked Sendable {
    struct Setup: Equatable, CustomStringConvertible {
        var bmRequestType: UInt8
        var bRequest: UInt8
        var wValue: UInt16
        var wIndex: UInt16
        var wLength: UInt16

        init(bmRequestType: UInt8, bRequest: UInt8, wValue: UInt16 = 0, wIndex: UInt16 = 0, wLength: UInt16 = 0) {
            self.bmRequestType = bmRequestType
            self.bRequest = bRequest
            self.wValue = wValue
            self.wIndex = wIndex
            self.wLength = wLength
        }

        init(_ control: dc_usb_control_t) {
            self.init(bmRequestType: control.bmRequestType, bRequest: control.bRequest, wValue: control.wValue,
                      wIndex: control.wIndex, wLength: control.wLength)
        }

        var description: String {
            String(format: "%02x %02x %04x %04x %u", bmRequestType, bRequest, wValue, wIndex, wLength)
        }
    }

    enum Call: Equatable {
        case read(length: UInt32, timeout: UInt32)
        case write([UInt8], timeout: UInt32)
        case control(Setup, data: [UInt8], timeout: UInt32)
        case clearStall(endpoint: UInt8)
        case abort
        case close
    }

    static let endpointIn: UInt8 = 0x82
    static let endpointOut: UInt8 = 0x02

    let packetSize: UInt16
    /// With nothing to send, a read waits out its real timeout (for ever at 0); otherwise it times out at once, so tests don't wait.
    var waitsOnSilence = false
    /// After a response that fills its last packet, the device sends a zero-length packet to end the transfer.
    var sendsZeroLengthPacket = false
    /// Returned, in order, by the next IN transfers instead of any data.
    var readFailures: [IOReturn] = []
    var writeResult: IOReturn = kIOReturnSuccess
    /// What the device does with a control transfer: its result, the data stage it fills for a read request, and a response to queue on the IN endpoint.
    var onControl: ((Setup, [UInt8]) -> (result: IOReturn, dataStage: [UInt8], response: [UInt8]?))?

    private let condition = NSCondition()
    private var log: [Call] = []
    private var responses: [[UInt8]] = []
    private var current: [UInt8] = []
    private var currentOffset = 0
    private var zeroLengthPacketOwed = false
    private var abortCount = 0
    private var detached = false
    private(set) var closeCount = 0

    init(packetSize: UInt16 = 64) {
        self.packetSize = packetSize
    }

    var calls: [Call] {
        condition.lock(); defer { condition.unlock() }
        return log
    }

    var controls: [Setup] {
        calls.compactMap { if case .control(let setup, _, _) = $0 { return setup } else { return nil } }
    }

    var reads: [(length: UInt32, timeout: UInt32)] {
        calls.compactMap { if case .read(let length, let timeout) = $0 { return (length, timeout) } else { return nil } }
    }

    var aborts: Int {
        calls.filter { $0 == .abort }.count
    }

    var isClosed: Bool {
        condition.lock(); defer { condition.unlock() }
        return closeCount > 0
    }

    /// Queues bytes to send on the IN endpoint, as one transfer's worth.
    func queue(_ response: [UInt8]) {
        condition.lock()
        responses.append(response)
        condition.broadcast()
        condition.unlock()
    }

    /// The device goes away: its registry entry is gone and transfers fail with kIOReturnNoDevice; a blocked one returns kIOReturnAborted, as on an unplug.
    func detach() {
        condition.lock()
        detached = true
        condition.broadcast()
        condition.unlock()
    }

    private func record(_ call: Call) {
        condition.lock()
        log.append(call)
        condition.unlock()
    }

    // MARK: - USBDeviceIO

    func maxPacketSize(endpoint: UInt8) -> UInt16 {
        endpoint == Self.endpointIn || endpoint == Self.endpointOut ? packetSize : 0
    }

    var isAttached: Bool {
        condition.lock(); defer { condition.unlock() }
        return !detached
    }

    func transfer(endpoint: UInt8, data: UnsafeMutableRawPointer, length: UInt32, actual: UnsafeMutablePointer<UInt32>,
                  timeout: UInt32) -> Int32 {
        actual.pointee = 0
        if endpoint & 0x80 == 0 {
            let bytes = Array(UnsafeRawBufferPointer(start: data, count: Int(length)))
            record(.write(bytes, timeout: timeout))
            guard isAttached else { return kIOReturnNoDevice }
            if writeResult == kIOReturnSuccess { actual.pointee = length }
            return writeResult
        }
        condition.lock()
        defer { condition.unlock() }
        log.append(.read(length: length, timeout: timeout))
        if detached { return kIOReturnNoDevice }
        if !readFailures.isEmpty { return readFailures.removeFirst() }
        let deadline = timeout > 0 ? Date().addingTimeInterval(Double(timeout) / 1000) : Date.distantFuture
        let aborted = abortCount
        while true {
            if currentOffset < current.count {
                let packet = min(current.count - currentOffset, Int(packetSize))
                guard packet <= Int(length) else {
                    currentOffset += packet
                    return kIOReturnOverrun
                }
                current.withUnsafeBufferPointer { data.copyMemory(from: $0.baseAddress! + currentOffset, byteCount: packet) }
                currentOffset += packet
                if currentOffset == current.count, packet == Int(packetSize) { zeroLengthPacketOwed = sendsZeroLengthPacket }
                actual.pointee = UInt32(packet)
                return kIOReturnSuccess
            }
            if zeroLengthPacketOwed {
                zeroLengthPacketOwed = false
                return kIOReturnSuccess
            }
            if !responses.isEmpty {
                current = responses.removeFirst()
                currentOffset = 0
                if current.isEmpty { zeroLengthPacketOwed = true }
                continue
            }
            if !waitsOnSilence { return USBReturn.transactionTimeout }
            if abortCount != aborted { return kIOReturnAborted }
            if detached { return kIOReturnAborted }
            if !condition.wait(until: deadline) { return USBReturn.transactionTimeout }
        }
    }

    func control(_ setup: UnsafePointer<dc_usb_control_t>, data: UnsafeMutableRawPointer?, timeout: UInt32) -> Int32 {
        let request = Setup(setup.pointee)
        let length = Int(request.wLength)
        let input = data.map { Array(UnsafeRawBufferPointer(start: $0, count: length)) } ?? []
        record(.control(request, data: input, timeout: timeout))
        guard isAttached else { return kIOReturnNoDevice }
        guard let onControl else { return kIOReturnSuccess }
        let reply = onControl(request, input)
        if reply.result == kIOReturnSuccess, request.bmRequestType & 0x80 != 0, let data {
            let count = min(reply.dataStage.count, length)
            reply.dataStage.withUnsafeBufferPointer { data.copyMemory(from: $0.baseAddress!, byteCount: count) }
        }
        if let response = reply.response { queue(response) }
        return reply.result
    }

    func clearStall(endpoint: UInt8) -> Int32 {
        record(.clearStall(endpoint: endpoint))
        return kIOReturnSuccess
    }

    func abortTransfers() {
        condition.lock()
        log.append(.abort)
        abortCount += 1
        condition.broadcast()
        condition.unlock()
    }

    func close() {
        condition.lock()
        log.append(.close)
        closeCount += 1
        condition.unlock()
    }
}

/// When something happened, set on one thread and read on another.
final class Instant: @unchecked Sendable {
    private let lock = NSLock()
    private var time = DispatchTime.now()

    func mark() {
        lock.lock(); time = .now(); lock.unlock()
    }

    var value: DispatchTime {
        lock.lock(); defer { lock.unlock() }
        return time
    }
}

/// The control ioctl's requests and the Cobalt's commands, as libdivecomputer builds them.
enum USBControl {
    /// DC_IOCTL_IOR('u', 0, DC_IOCTL_SIZE_VARIABLE) and DC_IOCTL_IOW, which Swift can't import.
    static let controlRead: UInt32 = (1 << 30) | (UInt32(UInt8(ascii: "u")) << 8)
    static let controlWrite: UInt32 = (2 << 30) | (UInt32(UInt8(ascii: "u")) << 8)
    /// DC_USB_REQUEST_VENDOR | DC_USB_RECIPIENT_DEVICE | DC_USB_ENDPOINT_OUT.
    static let vendorDeviceOut: UInt8 = 0x40

    /// A vendor, device, OUT request with no data stage, as the 8-byte setup usb.c reads.
    static func command(_ bRequest: UInt8) -> [UInt8] {
        [vendorDeviceOut, bRequest, 0, 0, 0, 0, 0, 0]
    }
}
#endif
