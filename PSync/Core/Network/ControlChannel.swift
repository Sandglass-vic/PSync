import Foundation
import Network

/// TCP 控制通道 - 传输 JSON 协议消息
final class ControlChannel: @unchecked Sendable {
    typealias MessageHandler = (ProtocolEnvelope) -> Void

    private let queue = DispatchQueue(label: "com.psync.control", qos: .userInitiated)
    private var listener: NWListener?
    private var connections: [String: NWConnection] = [:]
    private var receiveBuffers: [String: Data] = [:]
    private var onMessage: MessageHandler?
    private var port: UInt16 = 0

    var controlPort: UInt16 { port }

    func startServer(onMessage: @escaping MessageHandler) throws -> UInt16 {
        self.onMessage = onMessage
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params)
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

        // Wait briefly for port assignment
        Thread.sleep(forTimeInterval: 0.1)
        if port == 0, let assignedPort = listener.port {
            port = assignedPort.rawValue
        }
        return port
    }

    func connect(to host: String, port: UInt16, deviceId: String) {
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        connections[deviceId] = connection
        connection.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.receive(on: connection, deviceId: deviceId)
            }
        }
        connection.start(queue: queue)
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

    func disconnect(deviceId: String) {
        connections[deviceId]?.cancel()
        connections.removeValue(forKey: deviceId)
        receiveBuffers.removeValue(forKey: deviceId)
    }

    func stop() {
        for (_, connection) in connections {
            connection.cancel()
        }
        connections.removeAll()
        receiveBuffers.removeAll()
        listener?.cancel()
        listener = nil
    }

    private func acceptConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        let deviceId = UUID().uuidString
        connections[deviceId] = connection
        receive(on: connection, deviceId: deviceId)
    }

    private func receive(on connection: NWConnection, deviceId: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                var buffer = self.receiveBuffers[deviceId] ?? Data()
                buffer.append(data)
                self.receiveBuffers[deviceId] = buffer

                if let envelopes = try? ProtocolCodec.decodeMessages(from: &buffer) {
                    self.receiveBuffers[deviceId] = buffer
                    for envelope in envelopes {
                        self.onMessage?(envelope)
                    }
                }
            }
            if error == nil && connection.state != .cancelled {
                self.receive(on: connection, deviceId: deviceId)
            }
        }
    }
}
