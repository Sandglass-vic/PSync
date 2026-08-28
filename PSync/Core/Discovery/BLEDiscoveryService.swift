import CoreBluetooth
import Foundation

/// BLE 近距离发现：广播 + 扫描，类似 AirDrop 的第一阶段
final class BLEDiscoveryService: NSObject, @unchecked Sendable {
    typealias PeerHandler = (BLEAdvertisementCodec.Payload) -> Void

    private let queue = DispatchQueue(label: "com.psync.ble.discovery", qos: .userInitiated)
    private var central: CBCentralManager?
    private var peripheral: CBPeripheralManager?
    private var isCentralReady = false
    private var isPeripheralReady = false
    private var joinCode = ""
    private var localDeviceFingerprint = Data()
    private var onPeerDiscovered: PeerHandler?
    private var seenPeers = Set<String>()
    private var pendingAdvertisementName: String?
    private var advertisedService: CBMutableService?

    func start(
        joinCode: String,
        deviceId: String,
        sessionId: String,
        avatarId: Int,
        onPeerDiscovered: @escaping PeerHandler
    ) {
        stop()
        self.joinCode = joinCode
        localDeviceFingerprint = BLEAdvertisementCodec.deviceFingerprint(deviceId)
        self.onPeerDiscovered = onPeerDiscovered

        pendingAdvertisementName = BLEAdvertisementCodec.encodeLocalName(
            joinCode: joinCode,
            deviceId: deviceId,
            sessionId: sessionId,
            avatarId: avatarId
        )

        central = CBCentralManager(delegate: self, queue: queue)
        peripheral = CBPeripheralManager(delegate: self, queue: queue)
        print("[BLE] start joinCode=\(joinCode)")
    }

    func stop() {
        central?.stopScan()
        if let service = advertisedService {
            peripheral?.remove(service)
        }
        peripheral?.stopAdvertising()
        central = nil
        peripheral = nil
        advertisedService = nil
        isCentralReady = false
        isPeripheralReady = false
        onPeerDiscovered = nil
        pendingAdvertisementName = nil
        seenPeers.removeAll()
    }

    private func startScanningIfReady() {
        guard isCentralReady else { return }
        // 不按 Service UUID 过滤：iOS 常把 Local Name 放在 scan response，
        // 带 UUID 过滤时经常拿不到 Local Name，导致静默丢弃。
        central?.scanForPeripherals(
            withServices: nil,
            options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: true,
            ]
        )
        print("[BLE] scanning (unfiltered)")
    }

    private func startAdvertisingIfReady() {
        guard isPeripheralReady, let localName = pendingAdvertisementName else { return }

        // 注册 GATT service，提高 Service UUID 出现在广播中的概率
        let service = CBMutableService(type: BLEAdvertisementCodec.serviceUUID, primary: true)
        peripheral?.removeAllServices()
        peripheral?.add(service)
        advertisedService = service

        // CBPeripheralManager 仅支持 Local Name / Service UUIDs
        let advertisement: [String: Any] = [
            CBAdvertisementDataServiceUUIDsKey: [BLEAdvertisementCodec.serviceUUID],
            CBAdvertisementDataLocalNameKey: localName,
        ]
        peripheral?.startAdvertising(advertisement)
        print("[BLE] advertising name=\(localName)")
    }

    private func handleAdvertisement(_ payload: BLEAdvertisementCodec.Payload, peripheralId: UUID, rssi: NSNumber) {
        guard payload.joinCode == joinCode else { return }
        guard payload.deviceFingerprint.prefix(2) != localDeviceFingerprint.prefix(2) else { return }

        let peerKey = peripheralId.uuidString
        guard seenPeers.insert(peerKey).inserted else { return }

        print("[BLE] peer nearby rssi=\(rssi) code=\(payload.joinCode)")
        onPeerDiscovered?(payload)
    }
}

extension BLEDiscoveryService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        isCentralReady = central.state == .poweredOn
        if isCentralReady {
            startScanningIfReady()
        } else {
            print("[BLE] central state=\(central.state.rawValue)")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let peripheralName = peripheral.name
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let overflowUUIDs = advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? []
        let allUUIDs = serviceUUIDs + overflowUUIDs
        let isPSyncService = allUUIDs.contains(BLEAdvertisementCodec.serviceUUID)

        let candidates = [localName, peripheralName].compactMap { $0 }
        for name in candidates {
            if let payload = BLEAdvertisementCodec.decodeLocalName(name) {
                handleAdvertisement(payload, peripheralId: peripheral.identifier, rssi: RSSI)
                return
            }
        }

        // 调试：看到疑似 PSync 广播但解不出名字时打日志
        if isPSyncService || candidates.contains(where: { $0.hasPrefix("PS") }) {
            print("[BLE] raw discover name=\(localName ?? "-") peripheralName=\(peripheralName ?? "-") uuids=\(allUUIDs) rssi=\(RSSI)")
        }
    }
}

extension BLEDiscoveryService: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        isPeripheralReady = peripheral.state == .poweredOn
        if isPeripheralReady {
            startAdvertisingIfReady()
        } else {
            print("[BLE] peripheral state=\(peripheral.state.rawValue)")
        }
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            print("[BLE] advertising failed: \(error.localizedDescription)")
        } else {
            print("[BLE] advertising started OK")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            print("[BLE] add service failed: \(error.localizedDescription)")
        }
    }
}
