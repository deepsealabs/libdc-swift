#if os(macOS)
import Foundation
import IOKit

struct ProbeStep: Hashable {
    enum Outcome: Hashable {
        case ok
        case failed
        // Failed, but the step isn't one this port's families use, so it doesn't decide the result.
        case informational
        case skipped
    }

    let name: String
    let outcome: Outcome
    let detail: String

    static func ok(_ name: String, _ detail: String = "") -> ProbeStep {
        ProbeStep(name: name, outcome: .ok, detail: detail)
    }

    static func failed(_ name: String, _ detail: String) -> ProbeStep {
        ProbeStep(name: name, outcome: .failed, detail: detail)
    }

    static func skipped(_ name: String, _ detail: String) -> ProbeStep {
        ProbeStep(name: name, outcome: .skipped, detail: detail)
    }

    var informational: ProbeStep {
        outcome == .failed ? ProbeStep(name: name, outcome: .informational, detail: detail) : self
    }

    func renamed(_ prefix: String) -> ProbeStep {
        ProbeStep(name: "\(prefix) \(name)", outcome: outcome, detail: detail)
    }

    var line: String {
        let mark: String
        switch outcome {
        case .ok: mark = "ok"
        case .failed: mark = "FAILED"
        case .informational: mark = "FAILED (informational)"
        case .skipped: mark = "skipped"
        }
        return detail.isEmpty ? "\(name): \(mark)" : "\(name): \(mark), \(detail)"
    }
}

extension Array where Element == ProbeStep {
    var firstFailure: ProbeStep? { first { $0.outcome == .failed } }
}

enum ProbeText {
    static func ioReturn(_ code: IOReturn) -> String {
        if code == kIOReturnSuccess { return "kIOReturnSuccess" }
        let hex = String(format: "0x%08x", UInt32(bitPattern: code))
        let name = ioReturnNames.first { $0.0 == code }.map { "\($0.1) \(hex)" } ?? hex
        return "\(name) \(String(cString: mach_error_string(code)))"
    }

    static func errno(_ code: Int32) -> String {
        let name = errnoNames.first { $0.0 == code }?.1 ?? "errno \(code)"
        return "\(name) \(String(cString: strerror(code)))"
    }

    static func hex4(_ value: Int?) -> String {
        guard let value else { return "????" }
        return String(format: "%04x", value)
    }

    static func vidPid(_ vendorID: Int?, _ productID: Int?) -> String {
        "\(hex4(vendorID)):\(hex4(productID))"
    }

    static func hex<C: Collection>(_ bytes: C, limit: Int) -> String where C.Element == UInt8 {
        let head = bytes.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
        return bytes.count > limit ? head + " …" : head
    }

    static func milliseconds(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    // Arrays, not dictionaries: a duplicate literal key would trap at launch.
    private static let ioReturnNames: [(IOReturn, String)] = [
        (kIOReturnError, "kIOReturnError"),
        (kIOReturnNoMemory, "kIOReturnNoMemory"),
        (kIOReturnNoResources, "kIOReturnNoResources"),
        (kIOReturnNoDevice, "kIOReturnNoDevice"),
        (kIOReturnNotPrivileged, "kIOReturnNotPrivileged"),
        (kIOReturnBadArgument, "kIOReturnBadArgument"),
        (kIOReturnExclusiveAccess, "kIOReturnExclusiveAccess"),
        (kIOReturnUnsupported, "kIOReturnUnsupported"),
        (kIOReturnNotOpen, "kIOReturnNotOpen"),
        (kIOReturnBusy, "kIOReturnBusy"),
        (kIOReturnTimeout, "kIOReturnTimeout"),
        (kIOReturnNotReady, "kIOReturnNotReady"),
        (kIOReturnNotPermitted, "kIOReturnNotPermitted"),
        (kIOReturnAborted, "kIOReturnAborted"),
        (kIOReturnNotResponding, "kIOReturnNotResponding"),
        (kIOReturnNotFound, "kIOReturnNotFound")
    ]

    private static let errnoNames: [(Int32, String)] = [
        (EPERM, "EPERM"), (ENOENT, "ENOENT"), (EIO, "EIO"), (ENXIO, "ENXIO"),
        (EACCES, "EACCES"), (EBUSY, "EBUSY"), (ENODEV, "ENODEV"), (EINVAL, "EINVAL"),
        (ENOTTY, "ENOTTY"), (EAGAIN, "EAGAIN"), (ENOTSUP, "ENOTSUP"), (ETIMEDOUT, "ETIMEDOUT")
    ]
}

/// Properties come from CreateCFProperty or SearchCFProperty only, never IORegistryEntryGetProperty.
enum Registry {
    static func property(_ entry: io_registry_entry_t, _ key: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    static func string(_ entry: io_registry_entry_t, _ keys: String...) -> String? {
        keys.lazy.compactMap { property(entry, $0) as? String }.first
    }

    static func int(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        (property(entry, key) as? NSNumber)?.intValue
    }

    static func searchParents(_ entry: io_registry_entry_t, _ key: String) -> CFTypeRef? {
        IORegistryEntrySearchCFProperty(
            entry, kIOServicePlane, key as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        )
    }

    static func className(_ object: io_object_t) -> String {
        (IOObjectCopyClass(object)?.takeRetainedValue() as String?) ?? "?"
    }

    static func name(_ entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return "?" }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    static func label(_ entry: io_registry_entry_t) -> String {
        let cls = className(entry)
        let entryName = name(entry)
        return entryName == cls ? cls : "\(entryName)<\(cls)>"
    }

    // A dext attaches as a generic IOUserService; IOUserClass is the driver's own class name.
    static func driverLabel(_ entry: io_registry_entry_t) -> String {
        string(entry, "IOUserClass").map { "\($0) (dext)" } ?? label(entry)
    }

    static func isUSBInterface(_ entry: io_registry_entry_t) -> Bool {
        conforms(entry, to: "IOUSBHostInterface") || conforms(entry, to: "IOUSBInterface")
    }

    static func isUserClient(_ entry: io_registry_entry_t) -> Bool {
        conforms(entry, to: "IOUserClient")
    }

    static func registryID(_ entry: io_registry_entry_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        return id
    }

    /// Retained, so the caller releases it; 0 when the device has gone.
    static func service(registryID: UInt64) -> io_service_t {
        IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(registryID))
    }

    /// Visits and releases every object; the object is only valid inside `body`.
    static func drain(_ iterator: io_iterator_t, _ body: (io_object_t) -> Void) {
        while true {
            let object = IOIteratorNext(iterator)
            guard object != 0 else { return }
            body(object)
            IOObjectRelease(object)
        }
    }

    static func matching(_ dictionary: CFDictionary, _ body: (io_object_t) -> Void) -> kern_return_t {
        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, dictionary, &iterator)
        guard kr == KERN_SUCCESS else { return kr }
        drain(iterator, body)
        IOObjectRelease(iterator)
        return KERN_SUCCESS
    }

    static func children(_ entry: io_registry_entry_t, recursive: Bool = false, _ body: (io_object_t) -> Void) {
        var iterator: io_iterator_t = 0
        let options = IOOptionBits(recursive ? kIORegistryIterateRecursively : 0)
        guard IORegistryEntryCreateIterator(entry, kIOServicePlane, options, &iterator) == KERN_SUCCESS else { return }
        drain(iterator, body)
        IOObjectRelease(iterator)
    }

    static func conforms(_ object: io_object_t, to className: String) -> Bool {
        IOObjectConformsTo(object, className) != 0
    }
}

/// Callbacks arrive on the main queue.
final class IOKitNotifier {
    enum Event {
        case added
        case removed
    }

    typealias Handler = (_ event: Event, _ service: io_service_t) -> Void

    private final class Subscription {
        let event: Event
        let handler: Handler
        var iterator: io_iterator_t = 0
        var armed = false

        init(event: Event, handler: @escaping Handler) {
            self.event = event
            self.handler = handler
        }

        func drain() {
            // The first drain only arms the notification: those services were already present.
            let deliver = armed
            Registry.drain(iterator) { if deliver { handler(event, $0) } }
            armed = true
        }
    }

    private let port: IONotificationPortRef?
    private var subscriptions: [Subscription] = []

    init() {
        port = IONotificationPortCreate(kIOMainPortDefault)
        if let port { IONotificationPortSetDispatchQueue(port, .main) }
    }

    deinit {
        subscriptions.forEach { IOObjectRelease($0.iterator) }
        if let port { IONotificationPortDestroy(port) }
    }

    /// Returns nil on success, otherwise the failing IOReturn as text.
    func watch(className: String, handler: @escaping Handler) -> String? {
        guard let port else { return "IONotificationPortCreate returned NULL" }
        for event in [Event.added, .removed] {
            let subscription = Subscription(event: event, handler: handler)
            let type = event == .added ? kIOFirstMatchNotification : kIOTerminatedNotification
            let callback: IOServiceMatchingCallback = { refcon, _ in
                guard let refcon else { return }
                Unmanaged<Subscription>.fromOpaque(refcon).takeUnretainedValue().drain()
            }
            let kr = IOServiceAddMatchingNotification(
                port, type, IOServiceMatching(className), callback,
                Unmanaged.passUnretained(subscription).toOpaque(), &subscription.iterator
            )
            guard kr == KERN_SUCCESS else { return "\(className) \(type): \(ProbeText.ioReturn(kr))" }
            subscriptions.append(subscription)
            subscription.drain()
        }
        return nil
    }
}
#endif
