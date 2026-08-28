import XCTest
#if canImport(PSync)
@testable import PSync
#else
@testable import PSyncCore
#endif

final class TransferProtocolTests: XCTestCase {
    func testCodecRoundTripsControlMessages() throws {
        try assertRoundTrip(
            type: .photoManifest,
            payload: PhotoManifestPayload(photos: [
                PhotoMetadataPayload(
                    photoId: "p1",
                    contentHash: "hash-live",
                    fileHash: "file-live",
                    size: 2048,
                    width: 100,
                    height: 80,
                    format: "HEIC",
                    ownerDeviceId: "A",
                    isLivePhoto: true
                )
            ]),
            as: PhotoManifestPayload.self
        ) { decoded in
            XCTAssertEqual(decoded.photos.count, 1)
            XCTAssertEqual(decoded.photos[0].contentHash, "hash-live")
            XCTAssertTrue(decoded.photos[0].isLivePhoto)
        }

        try assertRoundTrip(
            type: .transferPlan,
            payload: TransferPlanPayload(tasks: [sampleTaskPayload(id: "t1")]),
            as: TransferPlanPayload.self
        ) { decoded in
            XCTAssertEqual(decoded.tasks.count, 1)
            XCTAssertEqual(decoded.tasks[0].transferId, "t1")
        }

        try assertRoundTrip(
            type: .transferAssign,
            payload: TransferAssignPayload(task: sampleTaskPayload(id: "t2")),
            as: TransferAssignPayload.self
        ) { decoded in
            XCTAssertEqual(decoded.task.transferId, "t2")
        }

        try assertRoundTrip(
            type: .securityConfirm,
            payload: SecurityConfirmPayload(confirmed: true),
            as: SecurityConfirmPayload.self
        ) { decoded in
            XCTAssertTrue(decoded.confirmed)
        }

        try assertRoundTrip(
            type: .membershipUpdate,
            payload: MembershipUpdatePayload(
                members: [
                    MemberPayload(
                        deviceId: "A",
                        userName: "Alice",
                        avatarId: 1,
                        networkEndpoint: "192.168.1.2",
                        controlPort: 1111,
                        transferPort: 2222,
                        isCoordinator: true,
                        confirmed: true,
                        joinedAt: 1
                    )
                ],
                securityCode: "AB12"
            ),
            as: MembershipUpdatePayload.self
        ) { decoded in
            XCTAssertEqual(decoded.securityCode, "AB12")
            XCTAssertEqual(decoded.members[0].transferPort, 2222)
            XCTAssertTrue(decoded.members[0].confirmed)
        }
    }

    func testTransferPlanUsesSnakeCaseWireKeys() throws {
        let task = sampleTaskPayload(id: "xfer-9")
        let envelope = try ProtocolEnvelope(
            messageType: .transferPlan,
            deviceId: "A",
            sessionId: "session-1",
            payload: TransferPlanPayload(tasks: [task])
        )

        var wire = try ProtocolCodec.encode(envelope)
        XCTAssertEqual(wire.last, 0x0A)
        XCTAssertEqual(envelope.messageType.rawValue, "transfer_plan")

        let json = try JSONSerialization.jsonObject(with: wire.dropLast()) as? [String: Any]
        XCTAssertEqual(json?["message_type"] as? String, "transfer_plan")
        XCTAssertEqual(json?["protocol_version"] as? Int, ProtocolConstants.protocolVersion)

        let payloadData = json?["payload"] as? String
        let payloadBytes: Data
        if let payloadData, let decoded = Data(base64Encoded: payloadData) {
            payloadBytes = decoded
        } else if let nested = json?["payload"] as? [String: Any] {
            payloadBytes = try JSONSerialization.data(withJSONObject: nested)
        } else {
            payloadBytes = envelope.payload
        }

        let payloadJSON = try XCTUnwrap(
            String(data: envelope.payload, encoding: .utf8)
        )
        XCTAssertTrue(payloadJSON.contains("\"transfer_id\""))
        XCTAssertTrue(payloadJSON.contains("\"content_hash\""))
        XCTAssertTrue(payloadJSON.contains("\"source_device_id\""))
        XCTAssertTrue(payloadJSON.contains("\"destination_device_id\""))
        XCTAssertTrue(payloadJSON.contains("\"photo_size\""))
        XCTAssertTrue(payloadJSON.contains("\"dependency_transfer_ids\""))
        XCTAssertFalse(payloadJSON.contains("\"transferId\""))

        let decoded = try ProtocolCodec.decodeMessages(from: &wire)
        XCTAssertTrue(wire.isEmpty)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].messageType, .transferPlan)
        let plan = try decoded[0].decodePayload(TransferPlanPayload.self)
        XCTAssertEqual(plan.tasks, [task])
        _ = payloadBytes
    }

    func testPhotoManifestRoundTripIncludesLiveFlag() throws {
        let photos = [
            PhotoMetadataPayload(
                photoId: "still",
                contentHash: "c-still",
                fileHash: "f-still",
                size: 10,
                width: 8,
                height: 8,
                format: "JPEG",
                ownerDeviceId: "A",
                isLivePhoto: false
            ),
            PhotoMetadataPayload(
                photoId: "live",
                contentHash: "c-live",
                fileHash: "f-live",
                size: 20,
                width: 8,
                height: 8,
                format: "HEIC",
                ownerDeviceId: "B",
                isLivePhoto: true
            )
        ]
        let envelope = try ProtocolEnvelope(
            messageType: .photoManifest,
            deviceId: "B",
            sessionId: "s",
            payload: PhotoManifestPayload(photos: photos)
        )
        var buffer = try ProtocolCodec.encode(envelope)
        let decoded = try ProtocolCodec.decodeMessages(from: &buffer)
        let payload = try decoded[0].decodePayload(PhotoManifestPayload.self)
        XCTAssertEqual(payload.photos.map(\.contentHash), ["c-still", "c-live"])
        XCTAssertEqual(payload.photos.map(\.isLivePhoto), [false, true])

        let json = try XCTUnwrap(String(data: envelope.payload, encoding: .utf8))
        XCTAssertTrue(json.contains("\"content_hash\""))
        XCTAssertTrue(json.contains("\"is_live_photo\""))
    }

    func testPhotoTransferFrameHeaderWithoutSockets() {
        let body = Data("JPEG-BYTES".utf8)
        let frame = PhotoTransferFrame.encode(
            transferId: "tid-1",
            contentHash: "content-abc",
            stillData: body
        )
        XCTAssertEqual(frame.firstIndex(of: 0x0A), "tid-1|content-abc|\(body.count)|0||".utf8.count)

        let parsed = PhotoTransferFrame.parse(frame)
        XCTAssertEqual(parsed?.header.transferId, "tid-1")
        XCTAssertEqual(parsed?.header.contentHash, "content-abc")
        XCTAssertEqual(parsed?.header.totalSize, Int64(body.count))
        XCTAssertEqual(parsed?.header.pairedVideoSize, 0)
        XCTAssertEqual(parsed?.body, body)

        XCTAssertNil(PhotoTransferFrame.parse(Data("incomplete".utf8)))
        XCTAssertNil(PhotoTransferFrame.parse(Data("a|b\n".utf8)))
    }

    func testPhotoTransferFrameLivePhotoBundle() throws {
        let still = Data("STILL-JPEG".utf8)
        let video = Data("MOV-VIDEO".utf8)
        let frame = PhotoTransferFrame.encode(
            transferId: "tid-live",
            contentHash: "hash-live",
            stillData: still,
            pairedVideoData: video,
            stillFilename: "IMG_0001.HEIC",
            pairedVideoFilename: "IMG_0001.MOV"
        )

        let parsed = try XCTUnwrap(PhotoTransferFrame.parse(frame))
        XCTAssertEqual(parsed.header.pairedVideoSize, Int64(video.count))
        XCTAssertEqual(parsed.header.totalSize, Int64(still.count + video.count))
        XCTAssertEqual(parsed.header.stillFilename, "IMG_0001.HEIC")
        XCTAssertEqual(parsed.header.pairedVideoFilename, "IMG_0001.MOV")

        let split = PhotoTransferFrame.splitPayload(parsed.body, header: parsed.header)
        XCTAssertEqual(split.still, still)
        XCTAssertEqual(split.pairedVideo, video)
    }

    private func sampleTaskPayload(id: String) -> TransferTaskPayload {
        TransferTaskPayload(
            transferId: id,
            contentHash: "hash-1",
            sourceDeviceId: "A",
            destinationDeviceId: "B",
            photoSize: 4096,
            state: .pending,
            version: 1,
            dependencyTransferIds: ["dep-a"]
        )
    }

    private func assertRoundTrip<T: Decodable>(
        type: MessageType,
        payload: Encodable,
        as payloadType: T.Type,
        file: StaticString = #filePath,
        line: UInt = #line,
        check: (T) throws -> Void
    ) throws {
        let envelope = try ProtocolEnvelope(
            messageType: type,
            deviceId: "A",
            sessionId: "session-proto",
            payload: payload
        )
        var buffer = try ProtocolCodec.encode(envelope)
        XCTAssertEqual(buffer.last, 0x0A, file: file, line: line)
        let decoded = try ProtocolCodec.decodeMessages(from: &buffer)
        XCTAssertEqual(decoded.count, 1, file: file, line: line)
        XCTAssertEqual(decoded[0].messageType, type, file: file, line: line)
        XCTAssertEqual(decoded[0].protocolVersion, ProtocolConstants.protocolVersion, file: file, line: line)
        try check(decoded[0].decodePayload(payloadType))
    }
}
