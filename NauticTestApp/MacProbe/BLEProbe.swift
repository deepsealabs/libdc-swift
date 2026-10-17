#if os(macOS)
import Foundation
import CoreBluetooth
import LibDCSwift

struct BLEScanResult: Hashable {
    var state = "not started"
    var authorization = BLEScanner.authorizationText(CBManager.authorization)
    var peripheralsSeen = 0
    var diveComputers: [String] = []
    var started = false
    var scanned = false
    var finished = false
    var note: String?

    var running: Bool { started && !finished }
}

/// Delegate callbacks arrive on the main queue.
final class BLEScanner: NSObject, CBCentralManagerDelegate {
    var onUpdate: ((BLEScanResult) -> Void)?
    private(set) var result = BLEScanResult()
    private var central: CBCentralManager?
    private var seen: Set<UUID> = []
    private var diveComputers: [UUID: String] = [:]
    private var scanSeconds: Double = 10
    private var generation = 0
    private let knownServices = Set(DeviceConfiguration.getKnownServiceUUIDs())

    func start(seconds: Double = 10) {
        scanSeconds = seconds
        generation += 1
        seen = []
        diveComputers = [:]
        result = BLEScanResult(state: "waiting for state", started: true)
        publish()
        if let central {
            centralManagerDidUpdateState(central)
        } else {
            // Creating the manager is what raises the Bluetooth permission prompt.
            central = CBCentralManager(delegate: self, queue: .main)
        }
        let token = generation
        // Long enough to answer the first-run permission prompt.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, token == self.generation, !self.result.scanned, !self.result.finished else { return }
            self.finish(note: "never reached poweredOn within 30 s")
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        result.state = Self.stateText(central.state)
        result.authorization = Self.authorizationText(CBManager.authorization)
        switch central.state {
        case .poweredOn:
            guard !result.scanned, !result.finished else { break }
            result.scanned = true
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            let token = generation
            DispatchQueue.main.asyncAfter(deadline: .now() + scanSeconds) { [weak self] in
                guard let self, token == self.generation else { return }
                central.stopScan()
                self.finish(note: nil)
            }
        case .unknown, .resetting:
            break
        default:
            if !result.finished { finish(note: nil) }
        }
        publish()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        seen.insert(peripheral.identifier)
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name
        let services = Set((advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? [])
        let knownName = name.map { DeviceConfiguration.fromName($0) != nil } ?? false
        if !services.isDisjoint(with: knownServices) || knownName {
            diveComputers[peripheral.identifier] = name ?? peripheral.identifier.uuidString
        }
        result.peripheralsSeen = seen.count
        result.diveComputers = diveComputers.values.sorted()
        publish()
    }

    private func finish(note: String?) {
        result.finished = true
        result.note = note
        publish()
    }

    private func publish() {
        onUpdate?(result)
    }

    static func stateText(_ state: CBManagerState) -> String {
        switch state {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "poweredOff"
        case .poweredOn: return "poweredOn"
        @unknown default: return "state \(state.rawValue)"
        }
    }

    static func authorizationText(_ authorization: CBManagerAuthorization) -> String {
        switch authorization {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .allowedAlways: return "allowedAlways"
        @unknown default: return "authorization \(authorization.rawValue)"
        }
    }
}
#endif
