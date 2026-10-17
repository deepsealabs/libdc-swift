// swift-tools-version:5.10
import PackageDescription

// Shared with LibDCBridge so libdc_has_custom_baud() sees what serial_posix.c was built with.
let customBaudDefine = CSetting.define("HAVE_IOKIT_SERIAL_IOSS_H", .when(platforms: [.macOS]))

let package = Package(
    name: "LibDCSwift",
    platforms: [
        .iOS(.v16),
        .macOS(.v13)
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
        ),
        .plugin(
            name: "ClibdcVerGeneratorPlugin",
            targets: ["ClibdcVerGeneratorPlugin"]
        )
    ],
    targets: [
        .target(
            name: "Clibdivecomputer",
            path: "libdivecomputer",
            // Exclude everything that isn't a library source. examples/ each
            // carry their own main(); doc/, m4/ and contrib/ hold no library
            // code; serial_win32.c is Windows-only.
            exclude: [
                "doc",
                "m4",
                "examples",
                "contrib",
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
                .define("ENABLE_LOGGING"),
                // Never HAVE_CONFIG_H (a local ./configure leaves an untracked config.h); other feature macros stay unset.
                customBaudDefine,
                .define("HAVE_CLOCK_GETTIME", .when(platforms: [.macOS]))
            ]
        ),
        .target(
            name: "LibDCBridge",
            dependencies: ["Clibdivecomputer"],
            path: "Sources/LibDCBridge",
            sources: [
                "src/configuredc.c",
                "src/BLEBridge.m",
                "src/transport_caps.c",
                "src/cable_open.c",
                "src/USBBridge.m"
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("../../libdivecomputer/include"),
                .headerSearchPath("../../libdivecomputer/src"),
                .define("OBJC_OLD_DISPATCH_PROTOTYPES", to: "1"),
                customBaudDefine
            ],
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("Foundation"),
                .linkedFramework("IOKit", .when(platforms: [.macOS]))
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
                "DiveLogRetriever.swift",
                "SuuntoNauticExplorer.swift",
                "AutoSync/AutoSyncPolicy.swift",
                "AutoSync/NauticSyncLink.swift",
                "AutoSync/NauticAutoSync.swift",
                "AutoSync/CoreBluetoothNauticConnector.swift",
                "Session/DiveComputerSession.swift",
                "Transport/DCTransport.swift",
                "Transport/DeviceCatalog.swift",
                "Transport/DiveComputerIdentity.swift",
                "Streams/DCIOStreamBackend.swift",
                "Streams/DCCustomStream.swift",
                "Streams/TapStream.swift",
                "Streams/DCRecording.swift",
                "Streams/ScriptedStream.swift",
                "Cable/CableEndpoint.swift",
                "Cable/CableError.swift",
                "Cable/CableDiscovery.swift",
                "Cable/IOKitCableDiscovery.swift",
                "Cable/SerialCableSession.swift",
                "Cable/HIDDeviceIO.swift",
                "Cable/HIDStream.swift",
                "Cable/HIDCableSession.swift",
                "Cable/USBComputers.swift"
            ],
            cSettings: [
                .headerSearchPath("../LibDCBridge/include"),
                .headerSearchPath("../Clibdivecomputer/include")
            ],
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("Foundation"),
                .linkedFramework("IOKit", .when(platforms: [.macOS]))
            ]
        ),
        .plugin(
            name: "ClibdcVerGeneratorPlugin",
            capability: .command(
                    intent:  .custom(
                        verb: "libdc-version-header",
                        description: "Generate libdivecomputer version.h"
                    ),
                    permissions: [
                        .writeToPackageDirectory(reason: "The plugin generates the libdivecomputer version.h file")
                    ]

            )
        ),
        .testTarget(
            name: "LibDCSwiftTests",
            dependencies: ["LibDCSwift", "LibDCBridge", "Clibdivecomputer"],
            path: "Tests/LibDCSwiftTests",
            resources: [
                .copy("Fixtures/suunto_nautic_1787752091.sbem"),
                .copy("Fixtures/logbook_entries_multi.bin"),
                .copy("Fixtures/suunto_nautic_1787752091.golden.json"),
                .copy("Fixtures/reefnet_sensus_synthetic.dcrec"),
                .copy("Fixtures/hw_ostc_mk2_synthetic.dcrec"),
                .copy("Fixtures/Hardware")
            ]
        )
    ]
)
