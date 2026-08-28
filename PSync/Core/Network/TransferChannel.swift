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

    typealias TransferCompleteHandler = (String, Data, Data?, String, String?, String?) -> Void
    typealias TransferProgressHandler = (String, Int64, Int64) -> Void
    typealias TransferFailedHandler = (String, String) -> Void

    private var onComplete: TransferCompleteHandler?
    private var onProgress: TransferProgressHandler?
    private var onFailed: TransferFailedHandler?

    func startServer(
        onComplete: @escaping TransferCompleteHandler,
        onProgress: @escaping TransferProgressHandler,
        onFailed: @escaping TransferFailedHandler = { _, _ in }
    ) throws {
        self.onComplete = onComplete
        self.onProgress = onProgress
        self.onFailed = onFailed

        let params = NWParameters.tcp
        params.includePeerToPeer = true
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
        if transferPort == 0, let assignedPort = listener.port {
            transferPort = assignedPort.rawValue
        }
    }

    func waitUntilReady(timeout: TimeInterval = 2.0) async -> Bool {
        if transferPort > 0 { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if transferPort > 0 { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return transferPort > 0
    }

    func sendPhoto(
        to host: String,
        port: UInt16,
        transferId: String,
        contentHash: String,
        stillData: Data,
        pairedVideoData: Data = Data(),
        stillFilename: String? = nil,
        pairedVideoFilename: String? = nil,
        chunkSize: Int = ProtocolConstants.defaultChunkSize
    ) async throws {
        let payload = PhotoTransferFrame.encode(
            transferId: transferId,
            contentHash: contentHash,
            stillData: stillData,
            pairedVideoData: pairedVideoData,
            stillFilename: stillFilename,
            pairedVideoFilename: pairedVideoFilename
        )
        let dataSize = stillData.count + pairedVideoData.count
        // #region agent log
        DebugSessionLogger.log(
            hypothesisId: "A",
            location: "TransferChannel.sendPhoto",
            message: "tcp_send_start",
            data: [
                "host": host,
                "port": Int(port),
                "transferId": transferId,
                "contentHash": String(contentHash.prefix(12)),
                "bytes": dataSize,
                "frameBytes": payload.count,
                "pairedVideoBytes": pairedVideoData.count,
                "stillName": stillFilename ?? "",
                "videoName": pairedVideoFilename ?? ""
            ]
        )
        // #endregion

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: {
                let params = NWParameters.tcp
                params.includePeerToPeer = true
                params.allowLocalEndpointReuse = true
                return params
            }()
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            let finish: (Result<Void, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success:
                    // #region agent log
                    DebugSessionLogger.log(
                        hypothesisId: "A",
                        location: "TransferChannel.sendPhoto",
                        message: "tcp_send_ok",
                        data: ["transferId": transferId, "bytes": dataSize]
                    )
                    // #endregion
                    continuation.resume()
                case .failure(let error):
                    // #region agent log
                    DebugSessionLogger.log(
                        hypothesisId: "A",
                        location: "TransferChannel.sendPhoto",
                        message: "tcp_send_error",
                        data: ["transferId": transferId, "error": error.localizedDescription]
                    )
                    // #endregion
                    continuation.resume(throwing: error)
                }
                // 等最后一帧 isComplete 刷出后再关，避免大文件被截断
                connection.cancel()
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Self.sendPayloadInChunks(
                        connection: connection,
                        payload: payload,
                        chunkSize: max(chunkSize, 64 * 1024),
                        queue: self.queue,
                        completion: finish
                    )
                case .failed(let error):
                    finish(.failure(error))
                case .waiting(let error):
                    // #region agent log
                    DebugSessionLogger.log(
                        hypothesisId: "G",
                        location: "TransferChannel.sendPhoto",
                        message: "tcp_waiting",
                        data: ["transferId": transferId, "error": String(describing: error)],
                        runId: "post-fix"
                    )
                    // #endregion
                    if Self.isConnectionRefused(error) {
                        finish(.failure(error))
                    }
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

    private static func sendPayloadInChunks(
        connection: NWConnection,
        payload: Data,
        chunkSize: Int,
        queue: DispatchQueue,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let total = payload.count
        if total == 0 {
            connection.send(
                content: nil,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        completion(.failure(error))
                    } else {
                        completion(.success(()))
                    }
                }
            )
            return
        }

        func sendOffset(_ offset: Int) {
            let end = min(offset + chunkSize, total)
            let chunk = payload.subdata(in: offset..<end)
            let isLast = end >= total
            connection.send(
                content: chunk,
                contentContext: .defaultMessage,
                isComplete: isLast,
                completion: .contentProcessed { error in
                    if let error {
                        completion(.failure(error))
                        return
                    }
                    if isLast {
                        completion(.success(()))
                    } else {
                        queue.async {
                            sendOffset(end)
                        }
                    }
                }
            )
        }

        sendOffset(0)
    }

    private func handleIncomingTransfer(_ connection: NWConnection) {
        connection.start(queue: queue)
        var buffer = Data()
        var completed = false

        func failIfIncomplete(_ reason: String) {
            guard !completed else { return }
            guard let parsed = PhotoTransferFrame.parse(buffer) else {
                // #region agent log
                DebugSessionLogger.log(
                    hypothesisId: "B",
                    location: "TransferChannel.handleIncomingTransfer",
                    message: "tcp_receive_error",
                    data: ["error": reason, "bufferBytes": buffer.count]
                )
                // #endregion
                return
            }
            let received = parsed.body.count
            let expected = Int(parsed.header.totalSize)
            guard received < expected else { return }
            completed = true
            // #region agent log
            DebugSessionLogger.log(
                hypothesisId: "B",
                location: "TransferChannel.handleIncomingTransfer",
                message: "tcp_receive_incomplete",
                data: [
                    "transferId": parsed.header.transferId,
                    "error": reason,
                    "bodyBytes": received,
                    "expectedBytes": expected
                ],
                runId: "post-fix"
            )
            // #endregion
            onFailed?(parsed.header.transferId, reason)
        }

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data, !data.isEmpty {
                    buffer.append(data)
                    if let parsed = PhotoTransferFrame.parse(buffer) {
                        // #region agent log
                        DebugSessionLogger.log(
                            hypothesisId: "B",
                            location: "TransferChannel.handleIncomingTransfer",
                            message: "tcp_receive_frame",
                            data: [
                                "transferId": parsed.header.transferId,
                                "contentHash": String(parsed.header.contentHash.prefix(12)),
                                "bodyBytes": parsed.body.count,
                                "expectedBytes": Int(parsed.header.totalSize)
                            ]
                        )
                        // #endregion
                        self.onProgress?(parsed.header.transferId, Int64(parsed.body.count), parsed.header.totalSize)
                        if Int64(parsed.body.count) >= parsed.header.totalSize {
                            completed = true
                            let payload = Data(parsed.body.prefix(Int(parsed.header.totalSize)))
                            let split = PhotoTransferFrame.splitPayload(payload, header: parsed.header)
                            self.onComplete?(
                                parsed.header.transferId,
                                split.still,
                                split.pairedVideo,
                                parsed.header.contentHash,
                                parsed.header.stillFilename,
                                parsed.header.pairedVideoFilename
                            )
                            connection.cancel()
                            return
                        }
                    }
                }

                if let error {
                    failIfIncomplete(error.localizedDescription)
                    connection.cancel()
                    return
                }

                if isComplete {
                    failIfIncomplete("peer closed before full frame")
                    connection.cancel()
                    return
                }

                if connection.state != .cancelled {
                    receive()
                }
            }
        }
        receive()
    }

    private static func isConnectionRefused(_ error: NWError) -> Bool {
        if case .posix(let code) = error {
            return code == .ECONNREFUSED
        }
        return false
    }
}
