import XCTest
import Clibdivecomputer
@testable import LibDCSwift

/// `DeviceConfiguration.fromName` resolves a BLE advertisement name to a
/// family/model using three paths, in order: the Oceanic/Aqualung/Sherwood
/// serial-encoded name, a Suunto Nautic/Ocean prefix, and libdivecomputer's
/// product-name descriptor lookup. Covers each path plus the descriptor
/// table every `supportedModels` entry must resolve against.
final class DescriptorMatchingTests: XCTestCase {

    // MARK: - Oceanic/Aqualung/Sherwood serial-encoded BLE name

    func testOceanicBLENameResolvesToItsEncodedModel() {
        // 'F' = 0x46, 'H' = 0x48 -> modelID 0x4648 = Aqualung i300C.
        let result = DeviceConfiguration.fromName("FH020399")
        XCTAssertEqual(result?.family, .oceanicAtom2)
        XCTAssertEqual(result?.model, 0x4648)
    }

    func testOceanicBLENameRequiresAllTrailingCharactersToBeDigits() {
        XCTAssertNil(DeviceConfiguration.fromName("FH02a399"), "a non-digit tail must not be read as a serial")
    }

    func testOceanicBLENameWithUnknownModelCodeFallsThroughToDescriptorLookup() {
        // 'Z','Z' isn't a registered Oceanic model code, and "ZZ123456" also
        // isn't a libdivecomputer product name, so the whole chain must miss.
        XCTAssertNil(DeviceConfiguration.fromName("ZZ123456"))
    }

    func testOceanicBLENameTooShortIsNotMatched() {
        XCTAssertNil(DeviceConfiguration.fromName("F"))
    }

    // MARK: - Suunto Nautic/Ocean family prefix

    func testSuuntoOceanPrefixMatchesRegardlessOfTheTrailingSerial() {
        let result = DeviceConfiguration.fromName("Suunto Ocean 1787752091")
        XCTAssertEqual(result?.family, .suuntoNautic)
        XCTAssertEqual(result?.model, 1)
    }

    func testSuuntoNauticPrefixMatchesRegardlessOfTheTrailingSerial() {
        let result = DeviceConfiguration.fromName("Suunto Nautic ABC123")
        XCTAssertEqual(result?.family, .suuntoNautic)
        XCTAssertEqual(result?.model, 0)
    }

    func testSuuntoOceanIsCheckedBeforeSuuntoNauticSoItIsNeverShadowed() {
        // "Suunto Ocean" has "Suunto Nautic" nowhere in it; this guards the
        // prefix order itself (Ocean checked first) against a future edit
        // that reorders the two checks and makes Ocean fall through to
        // the generic Nautic model by accident.
        XCTAssertEqual(DeviceConfiguration.fromName("Suunto Ocean XYZ")?.model, 1)
    }

    // MARK: - libdivecomputer product-name descriptor lookup

    func testKnownProductNamesResolveToTheirDescriptor() {
        let cases: [(name: String, family: DeviceConfiguration.DeviceFamily)] = [
            ("Suunto EON Steel", .suuntoEonSteel),
            ("Shearwater Perdix", .shearwaterPetrel),
            ("Shearwater Peregrine", .shearwaterPetrel),
            ("McLean Extreme", .mcleanExtreme),
        ]
        for (name, family) in cases {
            let result = DeviceConfiguration.fromName(name)
            XCTAssertEqual(result?.family, family, "\(name)")
        }
    }

    func testUnknownNameResolvesToNothing() {
        XCTAssertNil(DeviceConfiguration.fromName("Not A Real Dive Computer"))
        XCTAssertNil(DeviceConfiguration.fromName(""))
    }

    // MARK: - supportedModels <-> descriptor table

    /// Every `(family, model)` pair a stored device or auto-detect can produce
    /// must round-trip through libdivecomputer's own descriptor iterator, or
    /// `create_parser_for_device`'s `find_descriptor_by_model` lookup
    /// (configuredc.c) fails and the device can never be opened/parsed again.
    ///
    /// Pre-existing, pre-dating this test: libdivecomputer's own HW_OSTC3
    /// descriptors carry model 0 for every variant except OSTC 4/5 (its wire
    /// protocol doesn't discriminate the sub-model at the descriptor level),
    /// so these six `supportedModels` entries -- picker-UI-only hardware
    /// model bytes -- don't resolve through `find_descriptor_by_model`.
    /// Carved out by name rather than silently excluding the whole family, so
    /// a regression in any OTHER HW_OSTC3 (or other family) entry still fails.
    func testEverySupportedModelHasAMatchingDescriptor() throws {
        let knownUnresolved: Set<String> = [
            "Heinrichs Weikamp OSTC 3", "Heinrichs Weikamp OSTC 4", "Heinrichs Weikamp OSTC Plus",
            "Heinrichs Weikamp OSTC 2", "Heinrichs Weikamp OSTC Sport", "Heinrichs Weikamp OSTC 2 TR",
        ]

        var byFamilyAndModel: Set<String> = []
        var descIterator: OpaquePointer?
        XCTAssertEqual(dc_descriptor_iterator_new(&descIterator, nil), DC_STATUS_SUCCESS)
        defer { dc_iterator_free(descIterator) }

        var descriptor: OpaquePointer?
        while dc_iterator_next(descIterator, &descriptor) == DC_STATUS_SUCCESS {
            defer { dc_descriptor_free(descriptor) }
            guard let descriptor else { continue }
            let family = dc_descriptor_get_type(descriptor)
            let model = dc_descriptor_get_model(descriptor)
            byFamilyAndModel.insert("\(family.rawValue)-\(model)")
        }

        var missing: [String] = []
        var unexpectedlyResolved: [String] = []
        for entry in DeviceConfiguration.supportedModels {
            let key = "\(entry.family.asDCFamily.rawValue)-\(entry.modelID)"
            let resolved = byFamilyAndModel.contains(key)
            if knownUnresolved.contains(entry.name) {
                if resolved { unexpectedlyResolved.append(entry.name) }
            } else if !resolved {
                missing.append("\(entry.name) (family \(entry.family), model \(entry.modelID))")
            }
        }
        XCTAssertTrue(missing.isEmpty, "no descriptor for: \(missing.joined(separator: ", "))")
        XCTAssertTrue(unexpectedlyResolved.isEmpty,
            "now resolves (update findDescriptorByModel exception list): \(unexpectedlyResolved.joined(separator: ", "))")
    }

    func testDeviceFamilyRoundTripsThroughDCFamily() {
        for family in DeviceConfiguration.DeviceFamily.allCases {
            XCTAssertEqual(DeviceConfiguration.DeviceFamily(dcFamily: family.asDCFamily), family)
        }
    }
}
