import XCTest
import Clibdivecomputer
import LibDCBridge
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
    /// must resolve through the real `find_descriptor_by_model` (configuredc.c),
    /// the same lookup `create_parser_for_device` uses, or the device can
    /// never be opened/parsed again.
    ///
    /// Pre-existing, pre-dating this test, and carved out by name below
    /// (`knownUnresolved`) rather than silently excluded, so a regression in
    /// any OTHER entry still fails: libdivecomputer's own HW_OSTC3
    /// descriptors share model `0` across OSTC 2/3/Plus/Sport/2 TR (its wire
    /// protocol doesn't discriminate the sub-model), so `supportedModels`
    /// assigns each a distinct picker-UI-only byte that never resolves. OSTC 4
    /// is a different kind of mismatch: `supportedModels` has `0x3B`, but the
    /// libdivecomputer descriptor for OSTC 4 is model `0x43`.
    func testEverySupportedModelHasAMatchingDescriptor() throws {
        let knownUnresolved: Set<String> = [
            "Heinrichs Weikamp OSTC 3", "Heinrichs Weikamp OSTC 4", "Heinrichs Weikamp OSTC Plus",
            "Heinrichs Weikamp OSTC 2", "Heinrichs Weikamp OSTC Sport", "Heinrichs Weikamp OSTC 2 TR",
        ]

        var missing: [String] = []
        var unexpectedlyResolved: [String] = []
        for entry in DeviceConfiguration.supportedModels {
            var descriptor: OpaquePointer?
            let status = find_descriptor_by_model(&descriptor, entry.family.asDCFamily, entry.modelID)
            defer { if let descriptor { dc_descriptor_free(descriptor) } }
            let resolved = status == DC_STATUS_SUCCESS
            if knownUnresolved.contains(entry.name) {
                if resolved { unexpectedlyResolved.append(entry.name) }
            } else if !resolved {
                missing.append("\(entry.name) (family \(entry.family), model \(entry.modelID))")
            }
        }
        XCTAssertTrue(missing.isEmpty, "no descriptor for: \(missing.joined(separator: ", "))")
        XCTAssertTrue(unexpectedlyResolved.isEmpty,
            "now resolves (update the knownUnresolved set above): \(unexpectedlyResolved.joined(separator: ", "))")
    }

    // MARK: - BLE-advertised name patterns (configuredc.c name_patterns)

    /// `find_descriptor_by_name`'s `name_patterns` table is order-sensitive:
    /// several prefixes are substrings of a longer, more specific one (e.g.
    /// "Perdix" of "Perdix 2"), so a row checked in the wrong order would
    /// silently resolve to the wrong product. Each case asserts both the
    /// resolved (family, model) and that it matches the descriptor for the
    /// vendor/product the row names, computed independently of `fromName`.
    private struct NoSuchDescriptor: Error, CustomStringConvertible {
        let vendor: String
        let product: String
        var description: String { "no descriptor for \(vendor) \(product)" }
    }

    private func descriptorModel(vendor: String, product: String) throws -> (family: DeviceConfiguration.DeviceFamily, model: UInt32) {
        var iterator: OpaquePointer?
        XCTAssertEqual(dc_descriptor_iterator_new(&iterator, nil), DC_STATUS_SUCCESS)
        defer { dc_iterator_free(iterator) }
        var descriptor: OpaquePointer?
        while dc_iterator_next(iterator, &descriptor) == DC_STATUS_SUCCESS {
            defer { dc_descriptor_free(descriptor) }
            guard let descriptor,
                  let v = dc_descriptor_get_vendor(descriptor), let p = dc_descriptor_get_product(descriptor),
                  String(cString: v) == vendor, String(cString: p) == product else { continue }
            guard let family = DeviceConfiguration.DeviceFamily(dcFamily: dc_descriptor_get_type(descriptor)) else {
                throw NoSuchDescriptor(vendor: vendor, product: product)
            }
            return (family, dc_descriptor_get_model(descriptor))
        }
        throw NoSuchDescriptor(vendor: vendor, product: product)
    }

    func testRealisticAdvertisedNamesResolveToTheirDescriptorInNamePatternOrder() throws {
        let cases: [(name: String, vendor: String, product: String)] = [
            // Order-sensitive: a shorter row's prefix is a substring of these.
            ("Perdix 2 034521", "Shearwater", "Perdix 2"),
            ("Petrel 3 012345", "Shearwater", "Petrel 3"),
            ("Petrel 019283", "Shearwater", "Petrel 2"),
            ("Perdix 998877", "Shearwater", "Perdix"),
            // Advertised name omits the hardware's real "TX" suffix.
            ("Peregrine 556677", "Shearwater", "Peregrine TX"),
            ("Peregrine TX 556677", "Shearwater", "Peregrine TX"),
            // OSTC: generic "OSTC" must stay the catch-all, checked last.
            ("OSTC 4-99887", "Heinrichs Weikamp", "OSTC 4"),
            ("OSTC s#1234", "Heinrichs Weikamp", "OSTC Sport"),
            ("OSTC s 1234", "Heinrichs Weikamp", "OSTC Sport"),
            ("OSTC + 1234", "Heinrichs Weikamp", "OSTC 2"),
            ("OSTC1234", "Heinrichs Weikamp", "OSTC 2"),
            // Prefix-matched vendor codes.
            ("CARESIO_0012", "Cressi", "Cartesio"),
            ("GOA_0034", "Cressi", "Goa"),
            // Exact-match single entries named in the design doc.
            ("Puck4", "Mares", "Puck 4"),
            ("DS", "Ratio", "iX3M 2021 GPS Easy"),
            ("IX5M", "Ratio", "iX3M 2021 GPS Easy"),
            ("RATIO-7788", "Ratio", "iX3M 2021 GPS Easy"),
        ]
        for (name, vendor, product) in cases {
            let expected = try descriptorModel(vendor: vendor, product: product)
            let resolved = DeviceConfiguration.fromName(name)
            XCTAssertEqual(resolved?.family, expected.family, "\(name) family")
            XCTAssertEqual(resolved?.model, expected.model, "\(name) model")
        }
    }

    /// `name_patterns`' own "NERD"/"NERD 2" rows never match: the real
    /// descriptor table spells the product "Nerd"/"Nerd 2", and the lookup's
    /// vendor/product check is a case-sensitive `strcmp`. Pre-existing, found
    /// while writing the table above; unrelated to cable transports.
    func testNERDNamePatternRowsNeverMatchDueToACasingMismatch() {
        XCTAssertNil(DeviceConfiguration.fromName("NERD 2 445566"))
        XCTAssertNil(DeviceConfiguration.fromName("NERD 112233"))
    }

    func testDeviceFamilyRoundTripsThroughDCFamily() {
        for family in DeviceConfiguration.DeviceFamily.allCases {
            XCTAssertEqual(DeviceConfiguration.DeviceFamily(dcFamily: family.asDCFamily), family)
        }
    }
}
