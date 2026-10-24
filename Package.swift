// swift-tools-version: 6.0
import PackageDescription

// SwiftPM builds the libraries, the tests, the tools and the probes. It does not
// build the app: a menu bar bundle needs an Info.plist and a signature, which
// build.sh adds. App/ is therefore deliberately not a target here.

// Swift 6 language mode, the same mode build.sh compiles the app in. The radio is
// the only cross-thread code in the project and it says so out loud (see the
// @unchecked Sendable note in Adapters/Radio.swift), so strict concurrency costs
// nothing here and catches the next queue hop that forgets to hand over a value.

let package = Package(
    name: "Waylock",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure decisions. Foundation only, so it needs no radio and no permission.
        .target(name: "WaylockCore", path: "Core"),

        // The adapters that talk to macOS and are shared by the app and the tools.
        // Only CoreBluetooth is linked: Locker (IOKit) lives in App/ and is not here.
        .target(
            name: "WaylockAdapters",
            dependencies: ["WaylockCore"],
            path: "Adapters",
            linkerSettings: [.linkedFramework("CoreBluetooth")]
        ),

        // Radio-dependent commands whose output is read as evidence.
        .executableTarget(
            name: "waylock-tools",
            dependencies: ["WaylockCore", "WaylockAdapters"],
            path: "Tools",
            exclude: ["Probes"]   // the probes are their own targets, below
        ),

        // Single-file probes. They share a directory and each names its one source,
        // because both define top-level state and could not live in one module.
        .executableTarget(
            name: "waylock-scan",
            path: "Tools/Probes",
            exclude: ["watch.swift"],
            sources: ["scan.swift"]
        ),
        .executableTarget(
            name: "waylock-watch",
            path: "Tools/Probes",
            exclude: ["scan.swift"],
            sources: ["watch.swift"]
        ),

        .testTarget(
            name: "CoreTests",
            dependencies: ["WaylockCore"],
            path: "Tests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
