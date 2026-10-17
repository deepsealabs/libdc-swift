#if os(macOS)
import Foundation
import IOKit
import IOKit.serial

/// A serial port or a known cable's USB device came or went.
public enum RegistryChange: Sendable {
    case arrived
    case removed
}

/// Where `IOKitCableDiscovery` reads the registry; tests pass a fake that serves `RegistrySnapshot` fixtures.
public protocol RegistrySource: AnyObject {
    func snapshot() -> RegistrySnapshot
    /// Calls `changed` on `queue` as serial ports and known cables come and go, until `stopWatching()`; false if it can't watch.
    func startWatching(on queue: DispatchQueue, changed: @escaping (RegistryChange) -> Void) -> Bool
    func stopWatching()
}

/// Serial ports and known USB-serial cables from the IORegistry, following hot-plug; it never opens a port.
public final class IOKitCableDiscovery: CableDiscovering {
    private let source: RegistrySource
    private let settle: DispatchTimeInterval
    private let queue = DispatchQueue(label: "com.libdcswift.cable.discovery")
    private let feed = CableEndpointFeed()
    private var running = false
    private var refreshPending = false
    private let startedLock = NSLock()
    private var started = false

    /// `settle` is how long an arrival waits before the registry is read again: a USB device appears before its serial port does, and reading at once would show it as `driverMissing`.
    public init(source: RegistrySource = IOKitRegistrySource(), settle: DispatchTimeInterval = .milliseconds(500)) {
        self.source = source
        self.settle = settle
    }

    deinit {
        let source = source
        queue.async { source.stopWatching() }
    }

    public var endpoints: [CableEndpoint] { feed.endpoints }

    public func updates() -> AsyncStream<[CableEndpoint]> { feed.updates() }

    /// Reads the registry before it returns, then follows changes.
    public func start() {
        queue.sync {
            guard !running else { return }
            running = true
            setStarted(true)
            let watching = source.startWatching(on: queue) { [weak self] change in self?.changed(change) }
            if !watching { logWarning("Cable discovery can't watch the registry; call refresh() to update it") }
            refreshNow()
        }
    }

    public func stop() {
        queue.sync {
            guard running else { return }
            running = false
            setStarted(false)
            source.stopWatching()
        }
    }

    /// Reads the registry again now.
    public func refresh() {
        queue.sync { refreshNow() }
    }

    /// Ignored while stopped: a discovery that isn't reading the registry can't tell an unplug.
    public func cancelOnRemoval(of endpointID: CableEndpoint.ID, session: DiveComputerSession) {
        startedLock.lock()
        let watching = started
        startedLock.unlock()
        guard watching else {
            logWarning("Cable discovery isn't started; \(endpointID) won't be watched for an unplug")
            return
        }
        feed.watch(endpointID, session: session)
    }

    private func setStarted(_ value: Bool) {
        startedLock.lock()
        started = value
        startedLock.unlock()
    }

    private func changed(_ change: RegistryChange) {
        switch change {
        case .removed:
            // At once, so a download on a pulled cable is cancelled promptly.
            refreshNow()
        case .arrived:
            guard !refreshPending else { return }
            refreshPending = true
            queue.asyncAfter(deadline: .now() + settle) { [weak self] in
                guard let self else { return }
                self.refreshPending = false
                self.refreshNow()
            }
        }
    }

    private func refreshNow() {
        guard running else { return }
        feed.replace(source.snapshot().endpoints)
    }
}

/// The live IORegistry. Reads use IORegistryEntryCreateCFProperty and IORegistryEntrySearchCFProperty only, never IORegistryEntryGetProperty.
public final class IOKitRegistrySource: RegistrySource {
    private final class Subscription {
        let change: RegistryChange
        let handler: (RegistryChange) -> Void
        var iterator: io_iterator_t = 0
        var active = true

        init(change: RegistryChange, handler: @escaping (RegistryChange) -> Void) {
            self.change = change
            self.handler = handler
        }

        /// Draining re-arms the notification; the first drain only arms it, for services already there.
        func drain(notify: Bool) {
            IOKitRegistrySource.drain(iterator) { _ in }
            if notify, active { handler(change) }
        }
    }

    private var port: IONotificationPortRef?
    private var subscriptions: [Subscription] = []

    public init() {}

    deinit { stopWatching() }

    private static let usbDeviceClasses = [kIOUSBHostDeviceClass, "IOUSBDevice"]
    private static let kIOUSBHostDeviceClass = "IOUSBHostDevice"
    private static let vendorIDKey = "idVendor"
    private static let productIDKey = "idProduct"
    // Older and newer USB families name these differently.
    private static let serialNumberKeys = ["USB Serial Number", "kUSBSerialNumberString"]
    private static let productNameKeys = ["USB Product Name", "kUSBProductString"]

    public func snapshot() -> RegistrySnapshot {
        var ports: [RegistrySnapshot.Port] = []
        Self.forEachService(IOServiceMatching(kIOSerialBSDServiceValue)) { service in
            guard let callout = Self.string(service, kIOCalloutDeviceKey) else { return }
            ports.append(RegistrySnapshot.Port(calloutPath: callout, baseName: Self.string(service, kIOTTYBaseNameKey),
                                               parent: Self.parent(of: service)))
        }
        var seen = Set<UInt64>()
        var cables: [RegistrySnapshot.USBDevice] = []
        for className in Self.usbDeviceClasses {
            Self.forEachService(IOServiceMatching(className)) { device in
                guard let vid = Self.number(device, Self.vendorIDKey), let pid = Self.number(device, Self.productIDKey),
                      CableHints.hint(vendorID: vid, productID: pid) != nil else { return }
                let id = Self.registryID(device)
                guard seen.insert(id).inserted else { return }
                cables.append(RegistrySnapshot.USBDevice(
                    registryID: id, vendorID: vid, productID: pid,
                    serialNumber: Self.serialNumberKeys.lazy.compactMap { Self.string(device, $0) }.first,
                    productName: Self.productNameKeys.lazy.compactMap { Self.string(device, $0) }.first))
            }
        }
        return RegistrySnapshot(ports: ports, cableDevices: cables)
    }

    public func startWatching(on queue: DispatchQueue, changed: @escaping (RegistryChange) -> Void) -> Bool {
        stopWatching()
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return false }
        IONotificationPortSetDispatchQueue(port, queue)
        self.port = port
        var matchings: [() -> CFDictionary?] = [{ IOServiceMatching(kIOSerialBSDServiceValue) }]
        for vendor in CableHints.vendorIDs.sorted() {
            matchings.append {
                guard let dictionary = IOServiceMatching(Self.kIOUSBHostDeviceClass) as NSMutableDictionary? else { return nil }
                dictionary[Self.vendorIDKey] = NSNumber(value: vendor)
                return dictionary
            }
        }
        let callback: IOServiceMatchingCallback = { refcon, _ in
            guard let refcon else { return }
            Unmanaged<Subscription>.fromOpaque(refcon).takeUnretainedValue().drain(notify: true)
        }
        for matching in matchings {
            for (type, change) in [(kIOFirstMatchNotification, RegistryChange.arrived), (kIOTerminatedNotification, .removed)] {
                guard let dictionary = matching() else { continue }
                let subscription = Subscription(change: change, handler: changed)
                let status = IOServiceAddMatchingNotification(port, type, dictionary, callback,
                                                              Unmanaged.passUnretained(subscription).toOpaque(),
                                                              &subscription.iterator)
                guard status == KERN_SUCCESS else {
                    logWarning("IOServiceAddMatchingNotification failed: \(status)")
                    stopWatching()
                    return false
                }
                subscriptions.append(subscription)
                subscription.drain(notify: false)
            }
        }
        return true
    }

    public func stopWatching() {
        for subscription in subscriptions {
            subscription.active = false
            if subscription.iterator != 0 { IOObjectRelease(subscription.iterator) }
        }
        subscriptions.removeAll()
        if let port {
            IONotificationPortDestroy(port)
            self.port = nil
        }
    }

    // MARK: - Registry reads

    // Walks providers rather than trusting an inherited idVendor: on Intel Macs the Bluetooth controller is itself a USB device.
    private static func parent(of service: io_service_t) -> RegistrySnapshot.Port.Parent {
        var entry = service
        IOObjectRetain(entry)
        defer { IOObjectRelease(entry) }
        for _ in 0..<32 {
            var next: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &next) == KERN_SUCCESS else { return .none }
            IOObjectRelease(entry)
            entry = next
            if usbDeviceClasses.contains(where: { IOObjectConformsTo(entry, $0) != 0 }) {
                guard let vid = searchNumber(service, vendorIDKey), let pid = searchNumber(service, productIDKey) else { return .none }
                return .usb(RegistrySnapshot.USBDevice(
                    registryID: registryID(entry), vendorID: vid, productID: pid,
                    serialNumber: serialNumberKeys.lazy.compactMap { searchString(service, $0) }.first,
                    productName: productNameKeys.lazy.compactMap { searchString(service, $0) }.first))
            }
            if className(entry).contains("Bluetooth") || name(entry).contains("Bluetooth") {
                return .bluetooth
            }
        }
        return .none
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func search(_ entry: io_registry_entry_t, _ key: String) -> CFTypeRef? {
        IORegistryEntrySearchCFProperty(entry, kIOServicePlane, key as CFString, kCFAllocatorDefault,
                                        IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    }

    private static func string(_ entry: io_registry_entry_t, _ key: String) -> String? {
        property(entry, key) as? String
    }

    private static func number(_ entry: io_registry_entry_t, _ key: String) -> UInt16? {
        (property(entry, key) as? NSNumber).map { UInt16(truncatingIfNeeded: $0.intValue) }
    }

    private static func searchString(_ entry: io_registry_entry_t, _ key: String) -> String? {
        search(entry, key) as? String
    }

    private static func searchNumber(_ entry: io_registry_entry_t, _ key: String) -> UInt16? {
        (search(entry, key) as? NSNumber).map { UInt16(truncatingIfNeeded: $0.intValue) }
    }

    private static func registryID(_ entry: io_registry_entry_t) -> UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(entry, &id)
        return id
    }

    private static func className(_ entry: io_object_t) -> String {
        (IOObjectCopyClass(entry)?.takeRetainedValue() as String?) ?? ""
    }

    private static func name(_ entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &buffer) == KERN_SUCCESS else { return "" }
        return String(cString: buffer)
    }

    private static func forEachService(_ matching: CFDictionary?, _ body: (io_service_t) -> Void) {
        guard let matching else { return }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        drain(iterator, body)
        IOObjectRelease(iterator)
    }

    /// Visits and releases each object; it is valid only inside `body`.
    static func drain(_ iterator: io_iterator_t, _ body: (io_object_t) -> Void) {
        while case let object = IOIteratorNext(iterator), object != 0 {
            body(object)
            IOObjectRelease(object)
        }
    }
}
#endif
