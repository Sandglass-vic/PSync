import Foundation
import Network

/// P2P 照片数据传输通道 - TCP chunked transfer with resume support
final class TransferChannel: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.psync.transfer", qos: .userInitiated)
    private var listener: NWListener?
    private var transferPort: UInt16 = 0
    private var activeTransfers: [String: TransferContext] = [:]
    private let lock = NSLock()

    var port: UInt16 { transferPort }

    struct TransferContext {
        let transferId: String
        let contentHash: String
        let fileURL: URL?
        var receivedData: Data
        let expectedSize: Int64
        var bytesReceived: Int64
    }

    typealias TransferCompleteHandler = (String, Data, String) -> Void
    typealias TransferProgressHandler = (String, Int64, Int64) -> Void

    private var onComplete: TransferCompleteHandler?
    private var onProgress: TransferProgressHandler?

    func startServer(
        onComplete: @escaping TransferCompleteHandler,
        onProgress: @escaping TransferProgressHandler
    ) throws {
        self.onComplete = onComplete
        self.onProgress = onProgress

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let port = listener.port {
                self?.transferPort = port.rawValue
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleIncomingTransfer(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
        Thread.sleep(forTimeInterval: 0.1)
    }

    func sendPhoto(
        to host: String,
        port: UInt16,
        transferId: String,
        contentHash: String,
        fileURL: URL,
        chunkSize: Int = ProtocolConstants.defaultChunkSize
    ) async throws {
        let data = try Data(contentsOf: fileURL)
        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var offset = 0
                    let totalSize = data.count
                    let header = "\(transferId)|\(contentHash)|\(totalSize)\n"
                    var payload = Data(header.utf8)
                    payload.append(data)

                    connection.send(content: payload, completion: .contentProcessed { error in
                        if let error {
                            continuation.resume(throwing: error)
                        } else {
                            continuation.resume()
                        }
                        connection.cancel()
                    })
                case .failed(let error):
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        activeTransfers.removeAll()
        lock.unlock()
    }

    private func handleIncomingTransfer(_ connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data()

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, _, error in
                guard let self else { return }
                if let data {
                    buffer.append(data)
                    if let newlineIndex = buffer.firstIndex(of: 0x0A) {
                        let headerData = buffer[..<newlineIndex]
                        if let header = String(data: headerData, encoding: .utf8) {
                            let parts = header.split(separator: "|", maxSplits: 2)
                            if parts.count == 3,
                               let totalSize = Int64(parts[2]) {
                                let transferId = String(parts[0])
                                let contentHash = String(parts[1])
                                let photoData = buffer[(newlineIndex + 1)...]
                                self.onProgress?(transferId, Int64(photoData.count), totalSize)
                                if Int64(photoData.count) >= totalSize {
                                    self.onComplete?(transferId, Data(photoData.prefix(Int(totalSize))), contentHash)
                                    connection.cancel()
                                    return
                                }
                            }
                        }
                    }
                }
                if error == nil && connection.state != .cancelled {
                    receive()
                }
            }
        }
        receive()
    }
}
