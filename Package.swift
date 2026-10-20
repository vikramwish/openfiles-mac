// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "OpenFiles",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OpenFiles", targets: ["OpenFiles"]), .library(name: "OpenFilesCore", targets: ["OpenFilesCore"])],
    targets: [
        .target(name: "OpenFilesCore"),
        .executableTarget(name: "OpenFiles", dependencies: ["OpenFilesCore"]),
        .executableTarget(name: "OpenFilesBenchmark", dependencies: ["OpenFilesCore"], path: "Benchmarks/OpenFilesBenchmark"),
        .executableTarget(name: "OpenFilesChecks", dependencies: ["OpenFilesCore"], path: "Tests/OpenFilesChecks", resources: [.copy("Fixtures")])
    ]
)
