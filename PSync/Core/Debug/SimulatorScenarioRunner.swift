import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 用启动参数驱动模拟器联调，对应 `ABTransferScenarioTests` / `ABCTransferScenarioTests`。
/// 启动示例：`-psync-scenario ab -psync-role A -psync-join 4242`
@MainActor
enum SimulatorScenarioRunner {
    private static let statusFileName = "psync-scenario-status.txt"

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-psync-scenario")
    }

    static func argumentValue(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag), args.indices.contains(index + 1) else {
            return nil
        }
        return args[index + 1]
    }

    static func attach(to session: SessionManager) {
        guard isRequested else { return }
        Task { @MainActor in
            await run(on: session)
        }
    }

    private static func run(on session: SessionManager) async {
        let scenario = (argumentValue("-psync-scenario") ?? "ab").lowercased()
        let role = (argumentValue("-psync-role") ?? "A").uppercased()
        let joinCode = argumentValue("-psync-join") ?? "4242"
        let expectedMembers = scenario == "abc" ? 3 : 2
        let expectedReceive = expectedReceiveCount(scenario: scenario, role: role)

        writeStatus("BOOT scenario=\(scenario) role=\(role) join=\(joinCode) device=\(session.identity.deviceId.prefix(8))")
        print("[SCENARIO] boot scenario=\(scenario) role=\(role) join=\(joinCode) expectedMembers=\(expectedMembers) expectedReceive=\(expectedReceive)")

        do {
            try loadPhotos(into: session, scenario: scenario, role: role)
        } catch {
            fail(session, "load_photos \(error)")
            return
        }

        session.joinCodeInput = joinCode
        await session.startSharing()
        guard session.isSharing else {
            fail(session, "startSharing failed phase=\(session.sessionState.phase)")
            return
        }
        writeStatus("SHARING phase=\(session.sessionState.phase)")

        let discoverDeadline = Date().addingTimeInterval(30)
        while session.sessionState.members.count < expectedMembers {
            if Date() > discoverDeadline {
                stuck(session, "discovery members=\(session.sessionState.members.count)/\(expectedMembers)")
                return
            }
            logTick(session, stage: "discover")
            try? await Task.sleep(for: .milliseconds(500))
        }

        writeStatus("MEMBERS_READY count=\(session.sessionState.members.count)")
        print("[SCENARIO] members ready: \(session.sessionState.members.map { $0.deviceId.prefix(8) + ":\($0.confirmed)" }.joined(separator: ","))")

        let confirmDeadline = Date().addingTimeInterval(25)
        var didConfirm = false
        while true {
            if session.sessionState.phase == .syncingMetadata
                || session.sessionState.phase == .transferring
                || session.sessionState.phase == .awaitingGroupSync
                || session.sessionState.phase == .completed {
                break
            }
            if Date() > confirmDeadline {
                stuck(session, "confirm_or_advance still=\(session.sessionState.phase)")
                return
            }
            let localConfirmed = session.sessionState.members.first {
                $0.deviceId == session.identity.deviceId
            }?.confirmed == true
            if session.sessionState.phase == .waitingConfirmation, !localConfirmed, !didConfirm {
                print("[SCENARIO] confirmSharing now")
                session.confirmSharing()
                didConfirm = true
            }
            logTick(session, stage: "confirm")
            try? await Task.sleep(for: .milliseconds(400))
        }

        let transferDeadline = Date().addingTimeInterval(45)
        while true {
            if isSuccess(session, expectedReceive: expectedReceive) {
                pass(session, expectedReceive: expectedReceive)
                return
            }
            if Date() > transferDeadline {
                stuck(session, "transfer phase=\(session.sessionState.phase) recv=\(session.sessionState.photosReceived)/\(session.sessionState.photosToReceive)")
                return
            }
            switch session.sessionState.phase {
            case .failed(let msg):
                fail(session, "phase_failed \(msg)")
                return
            case .waitingConfirmation:
                stuck(session, "regressed_to_waitingConfirmation")
                return
            default:
                break
            }
            logTick(session, stage: "transfer")
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    private static func loadPhotos(into session: SessionManager, scenario: String, role: String) throws {
        let jpeg1 = try ScenarioJPEG.make(red: 0.92, green: 0.18, blue: 0.12)
        let jpeg2 = try ScenarioJPEG.make(red: 0.12, green: 0.72, blue: 0.22)
        let jpeg3 = try ScenarioJPEG.make(red: 0.10, green: 0.28, blue: 0.88)
        let jpeg4 = try ScenarioJPEG.make(red: 0.95, green: 0.85, blue: 0.15)

        let photos: [Data]
        switch (scenario, role) {
        case ("ab", "A"), ("abc", "A"):
            photos = [jpeg1, jpeg2]
        case ("ab", "B"), ("abc", "B"):
            photos = [jpeg2, jpeg3]
        case ("abc", "C"):
            photos = [jpeg1, jpeg3, jpeg4]
        default:
            throw ScenarioError.invalidRole("scenario=\(scenario) role=\(role)")
        }
        session.replaceSelectedPhotos(withStillImages: photos)
        print("[SCENARIO] loaded \(photos.count) photos for role \(role)")
    }

    private static func expectedReceiveCount(scenario: String, role: String) -> Int {
        switch (scenario, role) {
        case ("ab", "A"), ("ab", "B"):
            return 1
        case ("abc", "A"), ("abc", "B"):
            return 2
        case ("abc", "C"):
            return 1
        default:
            return 0
        }
    }

    private static func isSuccess(_ session: SessionManager, expectedReceive: Int) -> Bool {
        let received = session.sessionState.photosReceived
        let toReceive = session.sessionState.photosToReceive
        switch session.sessionState.phase {
        case .completed, .awaitingGroupSync, .transferring:
            return toReceive == expectedReceive && received >= expectedReceive
        default:
            return false
        }
    }

    private static func logTick(_ session: SessionManager, stage: String) {
        let members = session.sessionState.members
            .map { "\($0.deviceId.prefix(8)):\($0.confirmed ? "Y" : "N")" }
            .joined(separator: ",")
        let line = "[SCENARIO] tick \(stage) phase=\(session.sessionState.phase) members=\(members) recv=\(session.sessionState.photosReceived)/\(session.sessionState.photosToReceive)"
        print(line)
        writeStatus(line)
    }

    private static func pass(_ session: SessionManager, expectedReceive: Int) {
        let line = "PASS phase=\(session.sessionState.phase) recv=\(session.sessionState.photosReceived)/\(session.sessionState.photosToReceive) expected=\(expectedReceive) members=\(session.sessionState.members.count)"
        print("[SCENARIO] \(line)")
        writeStatus(line)
    }

    private static func stuck(_ session: SessionManager, _ reason: String) {
        let line = "STUCK \(reason) phase=\(session.sessionState.phase) members=\(session.sessionState.members.count) recv=\(session.sessionState.photosReceived)/\(session.sessionState.photosToReceive)"
        print("[SCENARIO] \(line)")
        writeStatus(line)
    }

    private static func fail(_ session: SessionManager, _ reason: String) {
        let line = "FAIL \(reason) phase=\(session.sessionState.phase)"
        print("[SCENARIO] \(line)")
        writeStatus(line)
    }

    private static func writeStatus(_ line: String) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = docs.appendingPathComponent(statusFileName)
        let text = line + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}

private enum ScenarioError: Error {
    case invalidRole(String)
}

private enum ScenarioJPEG {
    static func make(width: Int = 48, height: Int = 36, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ScenarioError.invalidRole("jpeg context")
        }
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw ScenarioError.invalidRole("jpeg image")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw ScenarioError.invalidRole("jpeg dest")
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw ScenarioError.invalidRole("jpeg finalize")
        }
        return data as Data
    }
}
