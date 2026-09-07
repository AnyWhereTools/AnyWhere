// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AnyWhereCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.library(name: "AnyWhereCore", targets: ["AnyWhereCore"])],
    targets: [
        .target(name: "AnyWhereCore", resources: [.process("Localizable.xcstrings")]),
        .testTarget(name: "AnyWhereCoreTests", dependencies: ["AnyWhereCore"],
                    resources: [.copy("Fixtures")]),
    ]
)
