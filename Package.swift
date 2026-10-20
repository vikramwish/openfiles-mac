// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "OpenFiles",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OpenFiles", targets: ["OpenFiles"]), .library(name: "OpenFilesCore", targets: ["OpenFilesCore"]), .library(name: "OpenFilesCloud", targets: ["OpenFilesCloud"])],
    targets: [
        .target(name: "OpenFilesCore"),
        .target(name: "OpenFilesCloud"),
        .executableTarget(name: "OpenFiles", dependencies: ["OpenFilesCore", "OpenFilesCloud"]),
        .executableTarget(name: "OpenFilesBenchmark", dependencies: ["OpenFilesCore"], path: "Benchmarks/OpenFilesBenchmark"),
        .executableTarget(name: "OpenFilesChecks", dependencies: ["OpenFilesCore"], path: "Tests/OpenFilesChecks", resources: [.copy("Fixtures")]),
        .executableTarget(name: "OpenFilesCloudChecks", dependencies: ["OpenFilesCloud"], path: "Tests/OpenFilesCloudChecks")
    ]
)
