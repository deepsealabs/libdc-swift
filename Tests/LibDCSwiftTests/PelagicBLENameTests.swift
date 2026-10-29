import XCTest
@testable import LibDCSwift

/// Pelagic computers advertise their serial ("FQ001062") as the BLE name; the
/// first two characters encode the model ID.
final class PelagicBLENameTests: XCTestCase {

    func testI770RResolves() {
        let r = DeviceConfiguration.fromName("FQ001062")
        XCTAssertEqual(r?.family, .oceanicAtom2)
        XCTAssertEqual(r?.model, 0x4651)
    }

    func testI470TCResolvesToItsOwnModel() {
        let r = DeviceConfiguration.fromName("GC004024")
        XCTAssertEqual(r?.family, .oceanicAtom2)
        XCTAssertEqual(r?.model, 0x4743)
    }

    func testBLEModelMissingFromCatalogStillResolves() {
        XCTAssertFalse(DeviceConfiguration.supportedModels.contains { $0.modelID == 0x4552 })
        let r = DeviceConfiguration.fromName("ER001234")
        XCTAssertEqual(r?.family, .oceanicAtom2)
        XCTAssertEqual(r?.model, 0x4552)
    }

    func testI330RResolvesToPelagicFamily() {
        let r = DeviceConfiguration.fromName("GD012345")
        XCTAssertEqual(r?.family, .pelagicI330R)
        XCTAssertEqual(r?.model, 0x4744)
    }

    func testSerialOnlyModelDoesNotResolve() {
        // 0x4559 is the Aqualung i300, which has no BLE transport.
        XCTAssertNil(DeviceConfiguration.fromName("EY012345"))
    }

    func testEveryBLECatalogPelagicModelResolvesFromItsSerialName() {
        let serialOnly: Set<UInt32> = [0x4456, 0x4458]
        for model in DeviceConfiguration.supportedModels
        where (model.family == .oceanicAtom2 || model.family == .pelagicI330R) && !serialOnly.contains(model.modelID) {
            let prefix = String(UnicodeScalar(UInt8(model.modelID >> 8))) + String(UnicodeScalar(UInt8(model.modelID & 0xFF)))
            let r = DeviceConfiguration.fromName(prefix + "000123")
            XCTAssertEqual(r?.family, model.family, model.name)
            XCTAssertEqual(r?.model, model.modelID, model.name)
        }
    }
}
