import XCTest
import Clibdivecomputer
import LibDCBridge

/// `find_descriptor_by_name_transport`: BLE is the old `find_descriptor_by_name`, cable transports match "Vendor Product".
final class DescriptorTransportLookupTests: XCTestCase {

    private struct Match: Equatable {
        let vendor: String
        let product: String
        let family: dc_family_t
        let model: UInt32
    }

    private func lookup(_ name: String, _ transport: dc_transport_t) -> (dc_status_t, Match?) {
        var descriptor: OpaquePointer?
        let rc = find_descriptor_by_name_transport(&descriptor, name, transport)
        guard rc == DC_STATUS_SUCCESS, let descriptor else { return (rc, nil) }
        defer { dc_descriptor_free(descriptor) }
        return (rc, Self.match(descriptor))
    }

    private static func match(_ descriptor: OpaquePointer) -> Match {
        Match(
            vendor: String(cString: dc_descriptor_get_vendor(descriptor)),
            product: String(cString: dc_descriptor_get_product(descriptor)),
            family: dc_descriptor_get_type(descriptor),
            model: dc_descriptor_get_model(descriptor)
        )
    }

    // Every name_patterns prefix, names that fall through to the BLE filter, and names nothing matches.
    private static let bleNames = [
        "Predator", "Perdix 2", "Petrel 3", "Petrel", "Perdix", "Teric", "Peregrine TX", "Peregrine",
        "NERD 2", "NERD", "Tern", "EON Steel", "Suunto D5", "EON Core", "Suunto Nautic 123", "Suunto Ocean",
        "G2", "HUD", "G3", "Aladin", "A1", "A2", "Luna 2.0 AI", "Luna 2.0", "Mares Genius", "Sirius",
        "Quad Ci", "Puck4", "CARESIO_1", "GOA_2", "Leonardo", "Donatello", "Michelangelo", "Neon", "Nepto",
        "OSTC 3", "OSTC s#", "OSTC s ", "OSTC 4-", "OSTC 2-", "OSTC + ", "OSTC", "COSMIQ", "S1",
        "McLean Extreme", "DiveComputer", "DS", "IX5M", "RATIO-",
        "Perdix 3", "Galileo 3", "G2 TEK", "FH020399", "EON Steel Black", "Suunto Vyper",
        "", "Not A Dive Computer",
    ]

    func testBLEMatchesTheOldSymbolForEveryName() {
        for name in Self.bleNames {
            var old: OpaquePointer?
            let oldRC = find_descriptor_by_name(&old, name)
            let (newRC, newMatch) = lookup(name, DC_TRANSPORT_BLE)
            XCTAssertEqual(newRC, oldRC, name)
            XCTAssertEqual(newMatch, old.map(Self.match), name)
            if let old { dc_descriptor_free(old) }
        }
    }

    func testSerialMatchesVendorAndProduct() {
        XCTAssertEqual(lookup("Suunto Vyper", DC_TRANSPORT_SERIAL).1,
                       Match(vendor: "Suunto", product: "Vyper", family: DC_FAMILY_SUUNTO_VYPER, model: 0x0A))
        XCTAssertEqual(lookup("Suunto Vyper Air", DC_TRANSPORT_SERIAL).1?.family, DC_FAMILY_SUUNTO_VYPER2,
                       "a longer product isn't cut short at a shorter one's prefix")
        XCTAssertEqual(lookup("Shearwater Predator", DC_TRANSPORT_SERIAL).1?.family, DC_FAMILY_SHEARWATER_PREDATOR)
    }

    func testSerialRejectsPartialAndBareNames() {
        XCTAssertEqual(lookup("Suunto Vyp", DC_TRANSPORT_SERIAL).0, DC_STATUS_UNSUPPORTED)
        XCTAssertEqual(lookup("Vyper", DC_TRANSPORT_SERIAL).0, DC_STATUS_UNSUPPORTED)
        XCTAssertEqual(lookup("SuuntoVyper", DC_TRANSPORT_SERIAL).0, DC_STATUS_UNSUPPORTED)
        XCTAssertEqual(lookup("Suunto Vyper ", DC_TRANSPORT_SERIAL).0, DC_STATUS_UNSUPPORTED)
    }

    func testTransportMustBeSupportedByTheDescriptor() {
        XCTAssertEqual(lookup("Suunto EON Steel", DC_TRANSPORT_SERIAL).0, DC_STATUS_UNSUPPORTED)
        XCTAssertEqual(lookup("Suunto EON Steel", DC_TRANSPORT_USBHID).1,
                       Match(vendor: "Suunto", product: "EON Steel", family: DC_FAMILY_SUUNTO_EONSTEEL, model: 0))
        XCTAssertEqual(lookup("Suunto Vyper", DC_TRANSPORT_USBHID).0, DC_STATUS_UNSUPPORTED)
    }

    func testUSBTransportsNeverMatchByFilter() {
        // Their filters read a VID/PID struct; a bare advertised name must not reach them.
        XCTAssertEqual(lookup("EON Steel", DC_TRANSPORT_USBHID).0, DC_STATUS_UNSUPPORTED)
        XCTAssertEqual(lookup("G2", DC_TRANSPORT_USBHID).0, DC_STATUS_UNSUPPORTED)
        XCTAssertEqual(lookup("Cobalt", DC_TRANSPORT_USB).0, DC_STATUS_UNSUPPORTED)
    }

    func testDuplicateProductsResolveToTheFirstInTableOrder() {
        // "Uwatec Aladin 2G" is listed as model 0x13 and again as 0x15.
        XCTAssertEqual(lookup("Uwatec Aladin 2G", DC_TRANSPORT_IRDA).1?.model, 0x13)
    }

    func testBluetoothFallsBackToTheNameFilter() {
        XCTAssertEqual(lookup("Shearwater Predator", DC_TRANSPORT_BLUETOOTH).1?.product, "Predator")
        XCTAssertEqual(lookup("Predator", DC_TRANSPORT_BLUETOOTH).1?.product, "Predator")
    }

    func testInvalidArguments() {
        var descriptor: OpaquePointer?
        XCTAssertEqual(find_descriptor_by_name_transport(&descriptor, nil, DC_TRANSPORT_SERIAL), DC_STATUS_INVALIDARGS)
        XCTAssertEqual(find_descriptor_by_name_transport(nil, "Suunto Vyper", DC_TRANSPORT_SERIAL), DC_STATUS_INVALIDARGS)
        XCTAssertEqual(lookup("Suunto Vyper", DC_TRANSPORT_NONE).0, DC_STATUS_INVALIDARGS)
        let serialOrHID = dc_transport_t(DC_TRANSPORT_SERIAL.rawValue | DC_TRANSPORT_USBHID.rawValue)
        XCTAssertEqual(lookup("Suunto Vyper", serialOrHID).0, DC_STATUS_INVALIDARGS)
        XCTAssertNil(descriptor)
    }
}
