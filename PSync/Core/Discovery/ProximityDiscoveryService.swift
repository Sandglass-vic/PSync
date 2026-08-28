import Foundation
import Network

/// AirDrop 式发现：BLE 快速发现附近设备 + Bonjour/AWDL 建立连接
final class ProximityDiscoveryService: @unchecked Sendable {
    typealias DiscoveryHandler = (DiscoveryAdvertisementPayload, NWEndpoint) -> Void

    private let ble = BLEDiscoveryService()
    private let bonjour = BonjourDiscoveryService()

    func start(
        joinCode: String,
        deviceId: String,
        sessionId: String,
        avatarId: Int,
        onDiscovered: @escaping DiscoveryHandler
    ) {
        stop()

        bonjour.startBrowsing(joinCode: joinCode, localDeviceId: deviceId, onDiscovered: onDiscovered)

        ble.start(
            joinCode: joinCode,
            deviceId: deviceId,
            sessionId: sessionId,
            avatarId: avatarId
        ) { payload in
            print("[Proximity] BLE found peer code=\(payload.joinCode) — waiting Bonjour/AWDL for TCP…")
        }
        print("[Proximity] started BLE + Bonjour discovery")
    }

    func stop() {
        ble.stop()
        bonjour.stop()
    }
}
