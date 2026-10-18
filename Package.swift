// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RevenueKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "RevenueKit", targets: ["RevenueKit"]),
               .executable(name: "revenue-probe", targets: ["RevenueProbe"])],
    targets: [
        .target(name: "RevenueKit"),
        .executableTarget(name: "RevenueProbe", dependencies: ["RevenueKit"]),
        .testTarget(name: "RevenueKitTests", dependencies: ["RevenueKit"]),
    ]
)
