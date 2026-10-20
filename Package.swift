// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Keep the dependency-free Apple backend available by default. MLX is opt-in for Apple Silicon.
let useMLX = ProcessInfo.processInfo.environment["OPENFILES_MLX"] == "1"
var dependencies: [Package.Dependency] = []
var appDependencies: [Target.Dependency] = ["OpenFilesCore"]
var checkDependencies: [Target.Dependency] = ["OpenFilesCore"]
var additionalTargets: [Target] = []
if useMLX {
    #if !os(macOS) || !arch(arm64)
    fatalError("OPENFILES_MLX=1 requires an Apple Silicon Mac.")
    #elseif !compiler(>=6.3)
    fatalError("OPENFILES_MLX=1 requires Swift 6.3 or later (the pinned MLX runtime requires 6.3).")
    #else
    dependencies = [
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "48114eedf3c3d4a682a6b1d644cc5af5c2945d10"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.0")
    ]
    additionalTargets = [.target(name: "OpenFilesMLX", dependencies: [
        "OpenFilesCore",
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "Tokenizers", package: "swift-transformers")
    ])]
    appDependencies.append("OpenFilesMLX")
    checkDependencies.append("OpenFilesMLX")
    #endif
}
let package = Package(
    name: "OpenFiles",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "OpenFiles", targets: ["OpenFiles"]), .library(name: "OpenFilesCore", targets: ["OpenFilesCore"]), .library(name: "OpenFilesCloud", targets: ["OpenFilesCloud"])],
    dependencies: dependencies,
    targets: [
        .target(name: "OpenFilesCore"),
        .target(name: "OpenFilesCloud"),
        .executableTarget(name: "OpenFiles", dependencies: appDependencies + ["OpenFilesCloud"]),
        .executableTarget(name: "OpenFilesBenchmark", dependencies: ["OpenFilesCore"], path: "Benchmarks/OpenFilesBenchmark"),
        .executableTarget(name: "OpenFilesChecks", dependencies: checkDependencies, path: "Tests/OpenFilesChecks", resources: [.copy("Fixtures")]),
        .executableTarget(name: "OpenFilesCloudChecks", dependencies: ["OpenFilesCloud"], path: "Tests/OpenFilesCloudChecks")
    ] + additionalTargets
)
