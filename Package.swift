// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "PSyncCore",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PSyncCore", targets: ["PSyncCore"])
    ],
    targets: [
        .target(
            name: "PSyncCore",
            path: "PSync",
            sources: [
                "Core/Protocol/ProtocolConstants.swift",
                "Core/Protocol/ProtocolMessage.swift",
                "Core/Models/Models.swift",
                "Core/Coordinator/GlobalPhotoRegistry.swift",
                "Core/Coordinator/TransferScheduler.swift",
                "Core/Coordinator/CoordinatorService.swift",
                "Core/Photo/PhotoFingerprint.swift"
            ]
        ),
        .testTarget(
            name: "PSyncCoreTests",
            dependencies: ["PSyncCore"],
            path: "PSyncTests",
            sources: [
                "ABCTransferScenarioTests.swift",
                "ABTransferScenarioTests.swift",
                "PhotoDedupWithImageDataTests.swift",
                "TransferProtocolTests.swift"
            ]
        )
    ]
)
