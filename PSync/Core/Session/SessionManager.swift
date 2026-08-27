import Foundation
import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class SessionManager: ObservableObject {
    @Published var sessionState = SharingSessionState()
    @Published var selectedPhotos: [LocalPhoto] = []
    @Published var joinCodeInput = ""
    @Published var nearbyDevices: [DiscoveryAdvertisementPayload] = []
    @Published var isSharing = false
    @Published var showSettings = false
    @Published var showResults = false

    var identity: DeviceIdentity

    private let discovery = DiscoveryService()
    private let controlChannel = ControlChannel()
    private let transferChannel = TransferChannel()
    private let coordinator = CoordinatorService()
    private var isCoordinator = false
    private var manifestReceived: Set<String> = []
    private var activeTransferTasks: [TransferTask] = []
    private var photoStore: [String: URL] = [:] // contentHash -> file URL
    private var discoveryStartTime: Date?

    init() {
        identity = DeviceIdentity.loadOrCreate()
    }

    // MARK: - Photo Selection

    func processSelectedImages(_ items: [PhotosPickerItem]) async {
        var photos: [LocalPhoto] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            do {
                let fingerprint = try PhotoFingerprint.compute(from: data)
                let thumbnail = generateThumbnail(from: data)
                let tempURL = saveTempFile(data: data, id: UUID().uuidString)

                let photo = LocalPhoto(
                    id: UUID().uuidString,
                    contentHash: fingerprint.contentHash,
                    fileHash: fingerprint.fileHash,
                    size: Int64(data.count),
                    width: fingerprint.width,
                    height: fingerprint.height,
                    format: fingerprint.format,
                    thumbnailData: thumbnail,
                    fileURL: tempURL
                )
                photos.append(photo)
                photoStore[fingerprint.contentHash] = tempURL
            } catch {
                print("[Session] Fingerprint error: \(error)")
            }
        }
        selectedPhotos = photos
    }

    // MARK: - Start Sharing

    func startSharing() async {
        guard !selectedPhotos.isEmpty else { return }

        let joinCode = joinCodeInput.isEmpty ? JoinCodeGenerator.generate() : joinCodeInput
        let sessionId = UUID().uuidString

        sessionState.sessionId = sessionId
        sessionState.joinCode = joinCode
        sessionState.localPhotos = selectedPhotos
        sessionState.phase = .discovering
        isSharing = true
        discoveryStartTime = Date()

        do {
            _ = try controlChannel.startServer { [weak self] envelope in
                Task { @MainActor in
                    self?.handleControlMessage(envelope)
                }
            }
            _ = try transferChannel.startServer(
                onComplete: { [weak self] transferId, data, contentHash in
                    Task { @MainActor in
                        self?.handleTransferComplete(transferId: transferId, data: data, contentHash: contentHash)
                    }
                },
                onProgress: { [weak self] transferId, received, total in
                    Task { @MainActor in
                        self?.updateTransferProgress(received: received, total: total)
                    }
                }
            )
        } catch {
            sessionState.phase = .failed("无法启动网络服务: \(error.localizedDescription)")
            return
        }

        isCoordinator = joinCodeInput.isEmpty
        if isCoordinator {
            sessionState.coordinatorDeviceId = identity.deviceId
            addSelfAsMember(isCoordinator: true)
        }

        let advertisement = DiscoveryAdvertisementPayload(
            protocolVersion: ProtocolConstants.protocolVersion,
            deviceId: identity.deviceId,
            displayName: identity.userName,
            avatarId: identity.avatarId,
            sessionId: sessionId,
            joinCode: joinCode,
            capabilities: ["photo_share", "relay"],
            controlPort: controlChannel.controlPort
        )

        discovery.startAdvertising(advertisement) { [weak self] ad in
            Task { @MainActor in
                self?.handleDiscovery(ad)
            }
        }
    }

    func confirmSharing() {
        guard sessionState.phase == .waitingConfirmation else { return }

        updateMemberConfirmation(deviceId: identity.deviceId, confirmed: true)
        broadcastSecurityConfirm(confirmed: true)

        if isCoordinator && coordinator.allConfirmed() {
            beginMetadataSync()
        }
    }

    func cancelSharing() {
        cleanupSession(clearPhotos: false)
    }

    // MARK: - Discovery

    private func handleDiscovery(_ ad: DiscoveryAdvertisementPayload) {
        guard ad.deviceId != identity.deviceId else { return }
        guard ad.joinCode == sessionState.joinCode else { return }

        if !nearbyDevices.contains(where: { $0.deviceId == ad.deviceId }) {
            nearbyDevices.append(ad)

            if let start = discoveryStartTime {
                let elapsed = Date().timeIntervalSince(start)
                print("[Discovery] Found device in \(String(format: "%.2f", elapsed))s")
            }
        }

        if !isCoordinator && sessionState.members.isEmpty {
            joinExistingSession(ad)
        }

        if sessionState.phase == .discovering && !nearbyDevices.isEmpty {
            sessionState.phase = .waitingConfirmation
            regenerateSecurityCode()
        }
    }

    private func joinExistingSession(_ ad: DiscoveryAdvertisementPayload) {
        controlChannel.connect(to: localHostAddress(), port: ad.controlPort, deviceId: ad.deviceId)

        let device = DeviceInfoPayload(
            deviceId: identity.deviceId,
            userName: identity.userName,
            avatarId: identity.avatarId,
            sessionId: sessionState.sessionId ?? "",
            joinCode: sessionState.joinCode ?? "",
            networkEndpoint: localHostAddress(),
            capabilities: ["photo_share", "relay"],
            controlPort: controlChannel.controlPort
        )

        if let envelope = try? ProtocolEnvelope(
            messageType: .joinRequest,
            deviceId: identity.deviceId,
            sessionId: sessionState.sessionId,
            payload: JoinRequestPayload(device: device)
        ) {
            try? controlChannel.send(envelope, to: ad.deviceId)
        }
    }

    private func addSelfAsMember(isCoordinator: Bool) {
        let member = SharingMember(
            deviceId: identity.deviceId,
            userName: identity.userName,
            avatarId: identity.avatarId,
            networkEndpoint: localHostAddress(),
            controlPort: controlChannel.controlPort,
            isCoordinator: isCoordinator,
            confirmed: false,
            discoveredAt: Date()
        )
        if !sessionState.members.contains(where: { $0.deviceId == identity.deviceId }) {
            sessionState.members.append(member)
        }
    }

    // MARK: - Control Messages

    private func handleControlMessage(_ envelope: ProtocolEnvelope) {
        switch envelope.messageType {
        case .joinRequest:
            handleJoinRequest(envelope)
        case .joinAccept:
            handleJoinAccept(envelope)
        case .membershipUpdate:
            handleMembershipUpdate(envelope)
        case .securityConfirm:
            handleSecurityConfirm(envelope)
        case .photoManifest:
            handlePhotoManifest(envelope)
        case .transferPlan:
            handleTransferPlan(envelope)
        case .transferAssign:
            handleTransferAssign(envelope)
        case .coordinatorElected:
            handleCoordinatorElected(envelope)
        default:
            break
        }
    }

    private func handleJoinRequest(_ envelope: ProtocolEnvelope) {
        guard isCoordinator else { return }
        guard let payload = try? envelope.decodePayload(JoinRequestPayload.self) else { return }
        guard sessionState.members.count < ProtocolConstants.maxMembers else { return }

        let member = SharingMember(
            deviceId: payload.device.deviceId,
            userName: payload.device.userName,
            avatarId: payload.device.avatarId,
            networkEndpoint: payload.device.networkEndpoint,
            controlPort: payload.device.controlPort,
            isCoordinator: false,
            confirmed: false,
            discoveredAt: Date()
        )

        if !sessionState.members.contains(where: { $0.deviceId == member.deviceId }) {
            sessionState.members.append(member)
            controlChannel.connect(
                to: payload.device.networkEndpoint,
                port: payload.device.controlPort,
                deviceId: payload.device.deviceId
            )
            regenerateSecurityCode()
        }

        let acceptPayload = JoinAcceptPayload(
            accepted: true,
            coordinatorDeviceId: identity.deviceId,
            members: sessionState.members.map { $0.toPayload() },
            reason: nil
        )

        if let response = try? ProtocolEnvelope(
            messageType: .joinAccept,
            deviceId: identity.deviceId,
            sessionId: sessionState.sessionId,
            payload: acceptPayload
        ) {
            try? controlChannel.send(response, to: payload.device.deviceId)
            broadcastMembershipUpdate()
        }
    }

    private func handleJoinAccept(_ envelope: ProtocolEnvelope) {
        guard let payload = try? envelope.decodePayload(JoinAcceptPayload.self) else { return }
        sessionState.coordinatorDeviceId = payload.coordinatorDeviceId
        isCoordinator = payload.coordinatorDeviceId == identity.deviceId
        sessionState.members = payload.members.map { SharingMember(from: $0) }
        sessionState.phase = .waitingConfirmation
        regenerateSecurityCode()
    }

    private func handleMembershipUpdate(_ envelope: ProtocolEnvelope) {
        guard let payload = try? envelope.decodePayload(MembershipUpdatePayload.self) else { return }
        sessionState.members = payload.members.map { SharingMember(from: $0) }
        sessionState.securityCode = payload.securityCode
        coordinator.resetConfirmations()
    }

    private func handleSecurityConfirm(_ envelope: ProtocolEnvelope) {
        guard let payload = try? envelope.decodePayload(SecurityConfirmPayload.self) else { return }
        updateMemberConfirmation(deviceId: envelope.deviceId, confirmed: payload.confirmed)

        if isCoordinator && coordinator.allConfirmed() {
            beginMetadataSync()
        }
    }

    private func handlePhotoManifest(_ envelope: ProtocolEnvelope) {
        guard let payload = try? envelope.decodePayload(PhotoManifestPayload.self) else { return }
        coordinator.handlePhotoManifest(from: envelope.deviceId, photos: payload.photos)
        manifestReceived.insert(envelope.deviceId)

        if isCoordinator && manifestReceived.count >= sessionState.members.count {
            executeTransferPlan()
        }
    }

    private func handleTransferPlan(_ envelope: ProtocolEnvelope) {
        guard let payload = try? envelope.decodePayload(TransferPlanPayload.self) else { return }
        activeTransferTasks = payload.tasks.map { task in
            TransferTask(
                transferId: task.transferId,
                contentHash: task.contentHash,
                sourceDeviceId: task.sourceDeviceId,
                destinationDeviceId: task.destinationDeviceId,
                photoSize: task.photoSize,
                state: task.state,
                version: task.version,
                dependencyTransferIds: task.dependencyTransferIds,
                bytesTransferred: 0
            )
        }
        sessionState.photosToReceive = coordinator.computePhotosToReceive(for: identity.deviceId)
        sessionState.phase = .transferring
        executeLocalTransfers()
    }

    private func handleTransferAssign(_ envelope: ProtocolEnvelope) {
        guard let payload = try? envelope.decodePayload(TransferAssignPayload.self) else { return }
        let task = TransferTask(
            transferId: payload.task.transferId,
            contentHash: payload.task.contentHash,
            sourceDeviceId: payload.task.sourceDeviceId,
            destinationDeviceId: payload.task.destinationDeviceId,
            photoSize: payload.task.photoSize,
            state: payload.task.state,
            version: payload.task.version,
            dependencyTransferIds: payload.task.dependencyTransferIds,
            bytesTransferred: 0
        )
        activeTransferTasks.append(task)
        executeLocalTransfers()
    }

    private func handleCoordinatorElected(_ envelope: ProtocolEnvelope) {
        if let payload = try? envelope.decodePayload(JoinAcceptPayload.self) {
            sessionState.coordinatorDeviceId = payload.coordinatorDeviceId
            isCoordinator = payload.coordinatorDeviceId == identity.deviceId
        }
    }

    // MARK: - Metadata & Transfer

    private func beginMetadataSync() {
        sessionState.phase = .syncingMetadata
        sendPhotoManifest()

        if isCoordinator {
            manifestReceived.insert(identity.deviceId)
        }
    }

    private func sendPhotoManifest() {
        let photos = selectedPhotos.map { $0.toMetadata(ownerDeviceId: identity.deviceId) }
        let payload = PhotoManifestPayload(photos: photos)

        if let envelope = try? ProtocolEnvelope(
            messageType: .photoManifest,
            deviceId: identity.deviceId,
            sessionId: sessionState.sessionId,
            payload: payload
        ) {
            if isCoordinator {
                coordinator.handlePhotoManifest(from: identity.deviceId, photos: photos)
            } else if let coordinatorId = sessionState.coordinatorDeviceId {
                try? controlChannel.send(envelope, to: coordinatorId)
            }
        }
    }

    private func executeTransferPlan() {
        let tasks = coordinator.generateTransferPlan()
        let payload = TransferPlanPayload(tasks: tasks.map { $0.toPayload() })

        if let envelope = try? ProtocolEnvelope(
            messageType: .transferPlan,
            deviceId: identity.deviceId,
            sessionId: sessionState.sessionId,
            payload: payload
        ) {
            controlChannel.broadcast(envelope)
        }

        activeTransferTasks = tasks
        sessionState.photosToReceive = coordinator.computePhotosToReceive(for: identity.deviceId)
        sessionState.phase = .transferring
        executeLocalTransfers()
    }

    private func executeLocalTransfers() {
        let uploadTasks = activeTransferTasks.filter {
            $0.sourceDeviceId == identity.deviceId && ($0.state == .pending || $0.state == .scheduled)
        }
        let downloadTasks = activeTransferTasks.filter {
            $0.destinationDeviceId == identity.deviceId && ($0.state == .pending || $0.state == .scheduled)
        }

        for task in uploadTasks.prefix(ProtocolConstants.maxUploadConnections) {
            sendPhotoForTask(task)
        }

        if downloadTasks.isEmpty && uploadTasks.isEmpty {
            checkCompletion()
        }
    }

    private func sendPhotoForTask(_ task: TransferTask) {
        guard let fileURL = photoStore[task.contentHash] ?? selectedPhotos.first(where: {
            $0.contentHash == task.contentHash
        })?.fileURL else { return }

        let destMember = sessionState.members.first { $0.deviceId == task.destinationDeviceId }
        let host = destMember?.networkEndpoint ?? localHostAddress()

        Task {
            do {
                try await transferChannel.sendPhoto(
                    to: host,
                    port: transferChannel.port,
                    transferId: task.transferId,
                    contentHash: task.contentHash,
                    fileURL: fileURL
                )
                coordinator.scheduler.markCompleted(task.transferId, contentHash: task.contentHash, deviceId: task.destinationDeviceId)
            } catch {
                coordinator.scheduler.markFailed(task.transferId)
                if let newTask = coordinator.scheduler.rescheduleFailedTask(task, members: sessionState.members.map(\.deviceId)) {
                    activeTransferTasks.append(newTask)
                }
            }
            executeLocalTransfers()
        }
    }

    private func handleTransferComplete(transferId: String, data: Data, contentHash: String) {
        do {
            let verified = try PhotoFingerprint.verifyContent(data: data, expectedContentHash: contentHash)
            guard verified else {
                coordinator.scheduler.markFailed(transferId)
                return
            }

            let tempURL = saveTempFile(data: data, id: contentHash)
            photoStore[contentHash] = tempURL
            let thumbnail = generateThumbnail(from: data)

            let sourceMember = sessionState.members.first {
                activeTransferTasks.first { $0.transferId == transferId }?.sourceDeviceId == $0.deviceId
            }

            let received = ReceivedPhoto(
                id: UUID().uuidString,
                contentHash: contentHash,
                thumbnailData: thumbnail,
                sourceUserName: sourceMember?.userName ?? "未知",
                sourceDeviceId: sourceMember?.deviceId ?? ""
            )

            sessionState.receivedPhotos.append(received)
            sessionState.photosReceived += 1
            coordinator.scheduler.markCompleted(transferId, contentHash: contentHash, deviceId: identity.deviceId)

            checkCompletion()
            executeLocalTransfers()
        } catch {
            coordinator.scheduler.markFailed(transferId)
        }
    }

    private func checkCompletion() {
        let allDone = activeTransferTasks.allSatisfy {
            $0.state == .completed || $0.state == .verified
        }
        let receivedEnough = sessionState.photosReceived >= sessionState.photosToReceive

        if allDone || receivedEnough {
            sessionState.phase = .completed
            showResults = true
            cleanupSession(clearPhotos: true)
        }
    }

    // MARK: - Helpers

    private func regenerateSecurityCode() {
        let memberIds = sessionState.members.map(\.deviceId)
        sessionState.securityCode = SecurityCodeGenerator.generate(
            memberDeviceIds: memberIds,
            sessionId: sessionState.sessionId ?? ""
        )
        for i in sessionState.members.indices {
            sessionState.members[i].confirmed = false
        }
        coordinator.resetConfirmations()
    }

    private func updateMemberConfirmation(deviceId: String, confirmed: Bool) {
        coordinator.handleConfirmation(from: deviceId, confirmed: confirmed)
        if let index = sessionState.members.firstIndex(where: { $0.deviceId == deviceId }) {
            sessionState.members[index].confirmed = confirmed
        }
    }

    private func broadcastSecurityConfirm(confirmed: Bool) {
        let payload = SecurityConfirmPayload(confirmed: confirmed)
        if let envelope = try? ProtocolEnvelope(
            messageType: .securityConfirm,
            deviceId: identity.deviceId,
            sessionId: sessionState.sessionId,
            payload: payload
        ) {
            controlChannel.broadcast(envelope, excluding: identity.deviceId)
        }
    }

    private func broadcastMembershipUpdate() {
        let payload = MembershipUpdatePayload(
            members: sessionState.members.map { $0.toPayload() },
            securityCode: sessionState.securityCode ?? ""
        )
        if let envelope = try? ProtocolEnvelope(
            messageType: .membershipUpdate,
            deviceId: identity.deviceId,
            sessionId: sessionState.sessionId,
            payload: payload
        ) {
            controlChannel.broadcast(envelope, excluding: identity.deviceId)
        }
    }

    private func updateTransferProgress(received: Int64, total: Int64) {
        // Progress updates handled via photosReceived count
    }

    private func cleanupSession(clearPhotos: Bool) {
        discovery.stop()
        controlChannel.stop()
        transferChannel.stop()
        coordinator.reset()
        manifestReceived.removeAll()
        activeTransferTasks.removeAll()
        nearbyDevices.removeAll()
        isSharing = false
        sessionState.phase = .idle
        sessionState.members.removeAll()
        sessionState.securityCode = nil
        sessionState.coordinatorDeviceId = nil

        if clearPhotos {
            selectedPhotos.removeAll()
            sessionState.localPhotos.removeAll()
            joinCodeInput = ""
        }
    }

    private func localHostAddress() -> String {
        NetworkUtility.localWiFiAddress()
    }

    private func generateThumbnail(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = CGSize(width: 120, height: 120)
        UIGraphicsBeginImageContextWithOptions(size, false, 0)
        image.draw(in: CGRect(origin: .zero, size: size))
        let thumb = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return thumb?.jpegData(compressionQuality: 0.7)
    }

    private func saveTempFile(data: Data, id: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).photo")
        try? data.write(to: url)
        return url
    }

    func updateIdentity(name: String, avatarId: Int) {
        identity.userName = name
        identity.avatarId = avatarId
        identity.save()
    }
}
