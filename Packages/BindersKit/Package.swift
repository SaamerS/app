// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BindersKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "BindersKit", targets: ["BindersKit"]),
    ],
    targets: [
        .target(name: "BindersKit"),
        // Fixtures: the coding tools' own help text and option lists, as checked for their built-in agents.
        .testTarget(name: "BindersKitTests", dependencies: ["BindersKit"], resources: [.copy("Fixtures")]),
    ]
)
