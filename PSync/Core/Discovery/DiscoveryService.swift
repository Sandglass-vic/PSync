import Foundation
import Network

/// 跨平台 UDP 设备发现服务
/// iOS 使用 Network.framework 封装，Android 未来可使用 DatagramSocket 实现相同协议
final class DiscoveryService: @unchecked Sendable {
    typealias AdvertisementHandler = (DiscoveryAdvertisementPayload) -> Void

    private var broadcastConnection: NWConnection?
    private var listener: NWListener?
    private var multicastGroup: NWConnection?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.psync.discovery", qos: .userInitiated)
    private let deduplicator = DeviceDeduplicator()

    private var currentAdvertisement: DiscoveryAdvertisementPayload?
    private var onAdvertisement: AdvertisementHandler?

    func startAdvertising(_ advertisement: DiscoveryAdvertisementPayload, onReceived: @escaping AdvertisementHandler) {
        stop()
        currentAdvertisement = advertisement
        onAdvertisement = onReceived

        startBroadcastListener(onReceived: onReceived)
        startMulticastListener(onReceived: onReceived)
        startBroadcastTimer()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        broadcastConnection?.cancel()
        broadcastConnection = nil
        listener?.cancel()
        listener = nil
        multicastGroup?.cancel()
        multicastGroup = nil
        deduplicator.reset()
        currentAdvertisement = nil
        onAdvertisement = nil
    }

    private func startBroadcastTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: ProtocolConstants.discoveryBroadcastInterval)
        timer.setEventHandler { [weak self] in
            self?.sendAdvertisement()
        }
        timer.resume()
        self.timer = timer
        sendAdvertisement()
    }

    private func sendAdvertisement() {
        guard let ad = currentAdvertisement,
              let data = try? JSONEncoder.psync.encode(ad) else { return }

        sendUDP(data: data, host: "255.255.255.255", port: ProtocolConstants.discoveryPort)
        sendUDP(data: data, host: ProtocolConstants.multicastGroup, port: ProtocolConstants.multicastPort)
    }

    private func sendUDP(data: Data, host: String, port: UInt16) {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .udp
        )
        connection.stateUpdateHandler = { state in
            if case .ready = state {
                connection.send(content: data, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        connection.start(queue: queue)
    }

    private func startBroadcastListener(onReceived: @escaping AdvertisementHandler) {
        do {
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            params.requiredInterfaceType = .wifi

            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: ProtocolConstants.discoveryPort)!)
            listener.newConnectionHandler = { [weak self] connection in
                self?.receiveUDP(on: connection, handler: onReceived)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            // Fallback: try without required interface
            do {
                let listener = try NWListener(using: .udp, on: NWEndpoint.Port(rawValue: ProtocolConstants.discoveryPort)!)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.receiveUDP(on: connection, handler: onReceived)
                }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                print("[Discovery] Failed to start listener: \(error)")
            }
        }
    }

    private func startMulticastListener(onReceived: @escaping AdvertisementHandler) {
        let host = NWEndpoint.Host(ProtocolConstants.multicastGroup)
        let port = NWEndpoint.Port(rawValue: ProtocolConstants.multicastPort)!
        let connection = NWConnection(host: host, port: port, using: .udp)
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.receiveUDP(on: connection, handler: onReceived)
            }
        }
        connection.start(queue: queue)
        multicastGroup = connection
    }

    private func receiveUDP(on connection: NWConnection, handler: @escaping AdvertisementHandler) {
        connection.receiveMessage { [weak self] data, _, _, error in
            if let data, error == nil {
                self?.handleReceivedData(data, handler: handler)
            }
            if connection.state != .cancelled {
                self?.receiveUDP(on: connection, handler: handler)
            }
        }
    }

    private func handleReceivedData(_ data: Data, handler: AdvertisementHandler) {
        guard let ad = try? JSONDecoder.psync.decode(DiscoveryAdvertisementPayload.self, from: data) else { return }
        guard ad.protocolVersion == ProtocolConstants.protocolVersion else { return }
        guard deduplicator.shouldProcess(deviceId: ad.deviceId, sessionId: ad.sessionId) else { return }
        handler(ad)
    }
}
