// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "swift-resource-pool",
    platforms: [
        .macOS(.v14),
        .iOS(.v16),
        .tvOS(.v17),
        .watchOS(.v10)
    ],
    products: [
        .library(
            name: "ResourcePool",
            targets: ["ResourcePool"]
        )
    ],
    targets: [
        .target(
            name: "ResourcePool"
        ),
        .testTarget(
            name: "ResourcePoolTests",
            dependencies: ["ResourcePool"]
        )
    ],
    swiftLanguageVersions: [.v5]
)

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("StrictUnsafe"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault")
//    .unsafeFlags(["-warnings-as-errors"]),
]

for index in package.targets.indices {
    package.targets[index].swiftSettings = (package.targets[index].swiftSettings ?? []) + swiftSettings
}
