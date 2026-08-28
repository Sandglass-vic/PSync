import Foundation
import Network

/// TCP 控制通道 - 传输 JSON 协议消息
final class ControlChannel: @unchecked Sendable {
    typealias MessageHandler = (ProtocolEnvelope) -> Void

    private let queue = DispatchQueue(label: "com.psync.control", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [String: NWConnection] = [:]
    private var connectionByObject: [ObjectIdentifier: String] = [:]
    private var receiveBuffers: [String: Data] = [:]
    private var onMessage: MessageHandler?
    private var port: UInt16 = 0

    var controlPort: UInt16 { port }

    private static func peerToPeerParameters() -> NWParameters {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        params.allowLocalEndpointReuse = true
        return params
    }

    func startServer(onMessage: @escaping MessageHandler) throws -> UInt16 {
        self.onMessage = onMessage
        let listener = try NWListener(using: Self.peerToPeerParameters())
        listener.newConnectionHandler = { [weak self] connection in
            self?.acceptConnection(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let assignedPort = listener.port {
                self?.port = assignedPort.rawValue
            }
        }
        listener.start(queue: queue)
        self.listener = listener

        Thread.sleep(forTimeInterval: 0.1)
        if port == 0, let assignedPort = listener.port {
            port = assignedPort.rawValue
        }
        return port
    }

    func registerBonjourAdvertisement(
        deviceId: String,
        joinCode: String,
        sessionId: String,
        displayName: String,
        avatarId: Int
    ) {
        guard let listener else { return }
        let name = BonjourAdvertisement.serviceName(deviceId: deviceId, joinCode: joinCode)
        listener.service = NWListener.Service(
            name: name,
            type: ProtocolConstants.bonjourServiceType,
            txtRecord: BonjourAdvertisement.txtRecord(
                deviceId: deviceId,
                joinCode: joinCode,
                sessionId: sessionId,
                displayName: displayName,
                avatarId: avatarId
            )
        )
        print("[Bonjour] advertising service \(name)")
    }

    func connect(to host: String, port: UInt16, deviceId: String) {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: Self.peerToPeerParameters()
        )
        startOutgoing(connection, deviceId: deviceId)
    }

    func connect(to endpoint: NWEndpoint, deviceId: String) {
        let connection = NWConnection(to: endpoint, using: Self.peerToPeerParameters())
        startOutgoing(connection, deviceId: deviceId)
    }

    func send(_ envelope: ProtocolEnvelope, to deviceId: String) throws {
        guard let connection = connections[deviceId] else { return }
        let data = try ProtocolCodec.encode(envelope)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func broadcast(_ envelope: ProtocolEnvelope, excluding deviceId: String? = nil) {
        for (id, connection) in connections where id != deviceId {
            if let data = try? ProtocolCodec.encode(envelope) {
                connection.send(content: data, completion: .contentProcessed { _ in })
            }
        }
    }

    /// 从已建立的控制连接解析对端可达地址（旧项目复用已建立的 P2P 链路，而非静态 Wi‑Fi IP）
    func peerNetworkHost(for deviceId: String) -> String? {
        guard let connection = connections[deviceId],
              let path = connection.currentPath,
              let remoteEndpoint = path.remoteEndpoint else { return nil }
        return Self.hostString(from: remoteEndpoint)
    }

    private static func hostString(from endpoint: NWEndpoint) -> String? {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let addr):
                return "\(addr)"
            case .ipv6(let addr):
                return "\(addr)"
            case .name(let name, _):
                return name
            @unknown default:
                return nil
            }
        default:
            return nil
        }
    }

    func disconnect(deviceId: String) {
        if let connection = connections[deviceId] {
            connectionByObject.removeValue(forKey: ObjectIdentifier(connection))
        }
        connections[deviceId]?.cancel()
        connections.removeValue(forKey: deviceId)
        receiveBuffers.removeValue(forKey: deviceId)
    }

    func stop() {
        for (_, connection) in connections {
            connection.cancel()
        }
        connections.removeAll()
        connectionByObject.removeAll()
        receiveBuffers.removeAll()
        listener?.cancel()
        listener = nil
    }

    private func startOutgoing(_ connection: NWConnection, deviceId: String) {
        connections[deviceId] = connection
        connectionByObject[ObjectIdentifier(connection)] = deviceId
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.receive(on: connection, deviceId: deviceId)
            }
        }
        connection.start(queue: queue)
    }

    private func acceptConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        let provisionalId = UUID().uuidString
        connections[provisionalId] = connection
        connectionByObject[ObjectIdentifier(connection)] = provisionalId
        receive(on: connection, deviceId: provisionalId)
    }

    private func bindConnection(_ connection: NWConnection, to deviceId: String) {
        let objectId = ObjectIdentifier(connection)
        if let provisionalId = connectionByObject[objectId], provisionalId != deviceId {
            connections.removeValue(forKey: provisionalId)
            receiveBuffers.removeValue(forKey: provisionalId)
        }
        connections[deviceId] = connection
        connectionByObject[objectId] = deviceId
        if receiveBuffers[deviceId] == nil, let provisionalId = connectionByObject[objectId] {
            receiveBuffers[deviceId] = receiveBuffers[provisionalId]
            receiveBuffers.removeValue(forKey: provisionalId)
        }
    }

    private func receive(on connection: NWConnection, deviceId: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                var activeDeviceId = deviceId
                var buffer = self.receiveBuffers[activeDeviceId] ?? Data()
                buffer.append(data)
                self.receiveBuffers[activeDeviceId] = buffer

                if let envelopes = try? ProtocolCodec.decodeMessages(from: &buffer) {
                    self.receiveBuffers[activeDeviceId] = buffer
                    for envelope in envelopes {
                        if envelope.deviceId != activeDeviceId {
                            self.bindConnection(connection, to: envelope.deviceId)
                            activeDeviceId = envelope.deviceId
                        }
                        self.onMessage?(envelope)
                    }
                }
            }
            if error == nil && connection.state != .cancelled {
                let currentId = self.connectionByObject[ObjectIdentifier(connection)] ?? deviceId
                self.receive(on: connection, deviceId: currentId)
            }
        }
    }
}
