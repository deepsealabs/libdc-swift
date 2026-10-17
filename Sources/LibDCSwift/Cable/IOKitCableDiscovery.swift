#if os(macOS)
import Foundation
import IOKit
import IOKit.serial
import IOKit.hid

/// A serial port, a known cable's USB device, or a USB HID or raw USB computer came or went.
public enum RegistryChange: Sendable {
    case arrived
    case removed
}

/// Where `IOKitCableDiscovery` reads the registry; tests pass a fake that serves `RegistrySnapshot` fixtures.
public protocol RegistrySource: AnyObject {
    func snapshot() -> RegistrySnapshot
    /// Calls `changed` on `queue` as serial ports, known cables, HID devices and raw USB computers come and go, until `stopWatching()`; false if it can't watch.
    func startWatching(on queue: DispatchQueue, changed: @escaping (RegistryChange) -> Void) -> Bool
    func stopWatching()
}

/// Serial ports, known USB-serial cables, and USB HID and raw USB dive computers, following hot-plug; it never opens a port or device. A cable missing altogether may be held back by an Apple silicon laptop's "Allow accessory to connect?" prompt.
public final class IOKitCableDiscovery: CableDiscovering {
    private let source: RegistrySource
    private let settle: DispatchTimeInterval
    private let driverGrace: DispatchTimeInterval
    private let queue = DispatchQueue(label: "com.libdcswift.cable.discovery")
    private let feed = CableEndpointFeed()
    private var running = false
    private var refreshPending = false
    /// When each known cable with no port may be listed as `driverMissing`.
    private var portlessDue: [CableEndpoint.ID: DispatchTime] = [:]
    private var recheckAt: DispatchTime?
    private let startedLock = NSLock()
    private var started = false

    /// `settle`: how long an arrival waits before the registry is read again (a USB device appears before its port). `driverGrace`: how long a cable arriving after `start()` goes without a port before it's `driverMissing` (a DriverKit driver can take seconds).
    public init(source: RegistrySource = IOKitRegistrySource(), settle: DispatchTimeInterval = .milliseconds(500),
                driverGrace: DispatchTimeInterval = .seconds(3)) {
        self.source = source
        self.settle = settle
        self.driverGrace = driverGrace
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
            refreshNow(initial: true)
        }
    }

    public func stop() {
        queue.sync {
            guard running else { return }
            running = false
            setStarted(false)
            portlessDue.removeAll()
            recheckAt = nil
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

    /// Cables already plugged in at `start()` are listed at once; later ones wait out `driverGrace` before showing `driverMissing`.
    private func refreshNow(initial: Bool = false) {
        guard running else { return }
        let now = DispatchTime.now()
        let endpoints = source.snapshot().endpoints
        var due: [CableEndpoint.ID: DispatchTime] = [:]
        var held: [DispatchTime] = []
        for endpoint in endpoints where endpoint.status == .driverMissing {
            let when = portlessDue[endpoint.id] ?? (initial ? now : now + driverGrace)
            due[endpoint.id] = when
            if now < when { held.append(when) }
        }
        portlessDue = due
        feed.replace(endpoints.filter { endpoint in due[endpoint.id].map { now >= $0 } ?? true })
        if let next = held.min() { scheduleRecheck(at: next) }
    }

    private func scheduleRecheck(at deadline: DispatchTime) {
        if let pending = recheckAt, pending <= deadline { return }
        recheckAt = deadline
        queue.asyncAfter(deadline: deadline) { [weak self] in
            guard let self, self.recheckAt == deadline else { return }
            self.recheckAt = nil
            self.refreshNow()
        }
    }
}

/// The live IORegistry. Reads use IORegistryEntryCreateCFProperty on the entry itself, never a search up the tree or IORegistryEntryGetProperty. HID devices come from an IOHIDManager matching `HIDVendors` only, which is never opened.
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
    private var hidWatch: HIDWatch?

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
        var computers: [RegistrySnapshot.USBDevice] = []
        for className in Self.usbDeviceClasses {
            Self.forEachService(IOServiceMatching(className)) { device in
                guard let vid = Self.number(device, Self.vendorIDKey), let pid = Self.number(device, Self.productIDKey) else { return }
                let cable = CableHints.hint(vendorID: vid, productID: pid) != nil
                guard cable || USBComputers.layout(vendorID: vid, productID: pid) != nil else { return }
                let id = Self.registryID(device)
                guard seen.insert(id).inserted else { return }
                let entry = RegistrySnapshot.USBDevice(
                    registryID: id, vendorID: vid, productID: pid,
                    serialNumber: Self.serialNumberKeys.lazy.compactMap { Self.string(device, $0) }.first,
                    productName: Self.productNameKeys.lazy.compactMap { Self.string(device, $0) }.first)
                if cable { cables.append(entry) } else { computers.append(entry) }
            }
        }
        let hid = hidWatch?.devices ?? Self.hidDevices(in: Self.makeHIDManager())
        return RegistrySnapshot(ports: ports, cableDevices: cables, hidDevices: hid, usbComputers: computers)
    }

    public func startWatching(on queue: DispatchQueue, changed: @escaping (RegistryChange) -> Void) -> Bool {
        stopWatching()
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return false }
        IONotificationPortSetDispatchQueue(port, queue)
        self.port = port
        var matchings: [() -> CFDictionary?] = [{ IOServiceMatching(kIOSerialBSDServiceValue) }]
        for vendor in CableHints.vendorIDs.union(USBComputers.vendorIDs).sorted() {
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
        hidWatch = HIDWatch(queue: queue, handler: changed)
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
        hidWatch?.stop()
        hidWatch = nil
    }

    // MARK: - HID

    // Matching only these vendors means no keyboard or mouse is ever enumerated, so nothing here can raise Input Monitoring.
    static func makeHIDManager() -> IOHIDManager {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matching = HIDVendors.vendorIDs.map { [kIOHIDVendorIDKey: NSNumber(value: $0)] as NSDictionary } as CFArray
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching)
        return manager
    }

    // Matching runs when it is set, so an unscheduled manager already has the devices.
    static func hidDevices(in manager: IOHIDManager) -> [RegistrySnapshot.HIDDevice] {
        guard let devices = IOHIDManagerCopyDevices(manager) as NSSet? else { return [] }
        return devices.allObjects.map { hidDevice($0 as! IOHIDDevice) }
    }

    static func hidDevice(_ device: IOHIDDevice) -> RegistrySnapshot.HIDDevice {
        func number(_ key: String) -> NSNumber? { IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber }
        func string(_ key: String) -> String? { IOHIDDeviceGetProperty(device, key as CFString) as? String }
        return RegistrySnapshot.HIDDevice(
            registryID: registryID(IOHIDDeviceGetService(device)),
            vendorID: UInt16(truncatingIfNeeded: number(kIOHIDVendorIDKey)?.intValue ?? 0),
            productID: UInt16(truncatingIfNeeded: number(kIOHIDProductIDKey)?.intValue ?? 0),
            serialNumber: string(kIOHIDSerialNumberKey), productName: string(kIOHIDProductKey),
            primaryUsagePage: number(kIOHIDPrimaryUsagePageKey).map { UInt32(truncatingIfNeeded: $0.intValue) })
    }

    /// HID devices as they come and go, kept as they read on arrival because a removed device may no longer answer property reads.
    private final class HIDWatch {
        private let manager = IOKitRegistrySource.makeHIDManager()
        private let handler: (RegistryChange) -> Void
        private let lock = NSLock()
        private var present: [UInt64: RegistrySnapshot.HIDDevice] = [:]
        private var registryIDs: [UnsafeMutableRawPointer: UInt64] = [:]
        private var active = true

        /// Starts on the caller's `queue` and calls back on it.
        init(queue: DispatchQueue, handler: @escaping (RegistryChange) -> Void) {
            self.handler = handler
            if let devices = IOHIDManagerCopyDevices(manager) as NSSet? {
                for device in devices.allObjects.map({ $0 as! IOHIDDevice }) { _ = add(device) }
            }
            // Released by the cancel handler, after the last callback.
            let context = Unmanaged.passRetained(self).toOpaque()
            IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
                guard let context else { return }
                Unmanaged<HIDWatch>.fromOpaque(context).takeUnretainedValue().arrived(device)
            }, context)
            IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
                guard let context else { return }
                Unmanaged<HIDWatch>.fromOpaque(context).takeUnretainedValue().removed(device)
            }, context)
            IOHIDManagerSetDispatchQueue(manager, queue)
            IOHIDManagerSetCancelHandler(manager) { Unmanaged<HIDWatch>.fromOpaque(context).release() }
            IOHIDManagerActivate(manager)
        }

        var devices: [RegistrySnapshot.HIDDevice] {
            lock.lock(); defer { lock.unlock() }
            return Array(present.values)
        }

        func stop() {
            lock.lock()
            active = false
            lock.unlock()
            IOHIDManagerCancel(manager)
        }

        /// True for a registry entry not listed yet.
        private func add(_ device: IOHIDDevice) -> Bool {
            let read = IOKitRegistrySource.hidDevice(device)
            lock.lock(); defer { lock.unlock() }
            registryIDs[Unmanaged.passUnretained(device).toOpaque()] = read.registryID
            guard present[read.registryID] == nil else { return false }
            present[read.registryID] = read
            return true
        }

        // Activation reports the devices already listed again; only new registry entries are arrivals.
        private func arrived(_ device: IOHIDDevice) {
            let new = add(device)
            lock.lock()
            let notify = new && active
            lock.unlock()
            if notify { handler(.arrived) }
        }

        private func removed(_ device: IOHIDDevice) {
            let key = Unmanaged.passUnretained(device).toOpaque()
            let serviceID = IOKitRegistrySource.registryID(IOHIDDeviceGetService(device))
            lock.lock()
            let registryID = registryIDs.removeValue(forKey: key) ?? serviceID
            let notify = present.removeValue(forKey: registryID) != nil && active
            lock.unlock()
            if notify { handler(.removed) }
        }
    }

    // MARK: - Registry reads

    // Walks providers, then reads only that device's entry: on Intel Macs the Bluetooth controller is a USB device, and a search would give a CH340 its hub's serial.
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
                guard let vid = number(entry, vendorIDKey), let pid = number(entry, productIDKey) else { return .none }
                return .usb(RegistrySnapshot.USBDevice(
                    registryID: registryID(entry), vendorID: vid, productID: pid,
                    serialNumber: serialNumberKeys.lazy.compactMap { string(entry, $0) }.first,
                    productName: productNameKeys.lazy.compactMap { string(entry, $0) }.first))
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

    private static func string(_ entry: io_registry_entry_t, _ key: String) -> String? {
        property(entry, key) as? String
    }

    private static func number(_ entry: io_registry_entry_t, _ key: String) -> UInt16? {
        (property(entry, key) as? NSNumber).map { UInt16(truncatingIfNeeded: $0.intValue) }
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
