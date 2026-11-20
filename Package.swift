// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "WatchTunerDSP", platforms: [.iOS(.v18), .macOS(.v15), .watchOS(.v11)], products: [.library(name: "TunerDSP", targets: ["TunerDSP"])], targets: [.target(name: "TunerDSP"), .testTarget(name: "TunerDSPTests", dependencies: ["TunerDSP"])])
