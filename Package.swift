// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "LibDCSwift",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "LibDCSwift",
            targets: ["LibDCSwift"]
        ),
        .library(
            name: "LibDCBridge",
            type: .dynamic,
            targets: ["LibDCBridge"]
        )
    ],
    targets: [
        .target(
            name: "Clibdivecomputer",
            path: "libdivecomputer",
            exclude: [
                "doc",
                "m4",
                "src/serial_win32.c"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include/libdivecomputer"),
                .headerSearchPath("src"),
                .define("HAVE_PTHREAD_H"),
                // Without this, ERROR/WARNING/INFO/DEBUG in context-private.h
                // compile to no-ops (see the #ifdef ENABLE_LOGGING there) and
                // dc_context_log is never called — every protocol-level
                // validation failure (e.g. in shearwater_common.c) surfaces
                // to callers as a bare DC_STATUS_PROTOCOL with zero detail
                // about which check actually failed.
                .define("ENABLE_LOGGING")
            ]
        ),
        .target(
            name: "LibDCBridge",
            dependencies: ["Clibdivecomputer"],
            path: "Sources/LibDCBridge",
            sources: [
                "src/configuredc.c",
                "src/BLEBridge.m"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("../../libdivecomputer/include"),
                .headerSearchPath("../../libdivecomputer/src"),
                .define("OBJC_OLD_DISPATCH_PROTOTYPES", to: "1")
            ],
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("Foundation")
            ]
        ),
        .target(
            name: "LibDCSwift",
            dependencies: ["LibDCBridge", "Clibdivecomputer"],
            path: "Sources/LibDCSwift",
            sources: [
                "LibDCSwift.swift",
                "Logger.swift",
                "BLEManager.swift",
                "Models/DeviceConfiguration.swift",
                "Models/DiveData.swift",
                "Models/StoredDevice.swift",
                "Models/SampleData.swift",
                "Models/DeviceFingerprint.swift",
                "ViewModels/DiveDataViewModel.swift",
                "Parser/GenericParser.swift",
                "DiveLogRetriever.swift"
            ],
            cSettings: [
                .headerSearchPath("../LibDCBridge/include"),
                .headerSearchPath("../Clibdivecomputer/include")
            ],
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("Foundation")
            ]
        )
    ]
) 
