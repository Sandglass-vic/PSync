import Foundation
import Network
import Photos
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
    /// 传输网络是否仍在运行（全员结算后为 false，但分享 UI 仍可停留）
    @Published private(set) var isTransferNetworkActive = false
    /// 仅用户主动退出时置位，供 HomeView 收起导航
    @Published private(set) var shouldPopSharingUI = false

    var identity: DeviceIdentity

    private let discovery = ProximityDiscoveryService()
    private let controlChannel = ControlChannel()
    private let transferChannel = TransferChannel()
    private let coordinator = CoordinatorService()
    private var isCoordinator = false
    private var manifestReceived: Set<String> = []
    private var activeTransferTasks: [TransferTask] = []
    private var photoStore: [String: URL] = [:] // contentHash -> still file URL
    private var pairedVideoStore: [String: URL] = [:] // contentHash -> paired video URL
    private var stillFilenameByHash: [String: String] = [:]
    private var pairedVideoFilenameByHash: [String: String] = [:]
    private var discoveryStartTime: Date?
    private var hasJoinedRemoteSession = false
    private var peerEndpoints: [String: NWEndpoint] = [:]
    private var isLeaving = false
    private var photoIsLiveByHash: [String: Bool] = [:]
    private var photoFileHashByContentHash: [String: String] = [:]
    private var hasExecutedTransferPlan = false
    private var groupBarrier = GroupCompletionBarrier()
    private var groupSettleTask: Task<Void, Never>?
    /// 上次成功投递清单的协调者；仅在协调者变更时强制重发，避免三人确认时清单风暴
    private var lastManifestTargetCoordinatorId: String?
    private var lastManifestSendAt: Date?

    /// 已完成本机收发、等待全员同步的成员数（用于 UI）
    var completedMemberCount: Int { groupBarrier.completedMemberCount }

    init() {
        identity = DeviceIdentity.loadOrCreate()
    }

    // MARK: - Photo Selection

    func processSelectedImages(_ items: [PhotosPickerItem]) async {
        _ = await PhotoLibraryImporter.requestAuthorizationIfNeeded()

        var photos: [LocalPhoto] = []
        for item in items {
            let identifier = item.itemIdentifier
            // #region agent log
            DebugSessionLogger.log(
                hypothesisId: "L",
                location: "SessionManager.processSelectedImages",
                message: "picker_item",
                data: [
                    "hasIdentifier": identifier != nil,
                    "isLiveType": item.supportedContentTypes.contains { $0.conforms(to: .livePhoto) }
                ],
                runId: "post-fix"
            )
            // #endregion

            if let identifier,
               let exported = await LivePhotoExporter.export(fromLocalIdentifier: identifier) {
                appendExportedPhoto(exported, assetLocalIdentifier: identifier, to: &photos)
                continue
            }

            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            appendStillData(
                data,
                isLivePhoto: false,
                assetLocalIdentifier: identifier,
                to: &photos
            )
        }
        selectedPhotos = photos
    }

    func replaceSelectedPhotos(withStillImages dataList: [Data]) {
        var photos: [LocalPhoto] = []
        for data in dataList {
            appendStillData(data, isLivePhoto: false, assetLocalIdentifier: nil, to: &photos)
        }
        selectedPhotos = photos
    }

    private func appendExportedPhoto(
        _ exported: LivePhotoExporter.ExportResult,
        assetLocalIdentifier: String?,
        to photos: inout [LocalPhoto]
    ) {
        do {
            let fingerprint = try PhotoFingerprint.compute(from: exported.stillData)
            let thumbnail = generateThumbnail(from: exported.stillData)
            let photo = LocalPhoto(
                id: UUID().uuidString,
                contentHash: fingerprint.contentHash,
                fileHash: fingerprint.fileHash,
                size: Int64(exported.stillData.count),
                width: fingerprint.width,
                height: fingerprint.height,
                format: fingerprint.format,
                isLivePhoto: exported.isLivePhoto,
                thumbnailData: thumbnail,
                fileURL: exported.stillURL,
                assetLocalIdentifier: assetLocalIdentifier,
                pairedVideoURL: exported.pairedVideoURL
            )
            photos.append(photo)
            photoStore[fingerprint.contentHash] = exported.stillURL
            stillFilenameByHash[fingerprint.contentHash] = exported.stillFilename
            if let pairedVideoURL = exported.pairedVideoURL {
                pairedVideoStore[fingerprint.contentHash] = pairedVideoURL
                if let pairedVideoFilename = exported.pairedVideoFilename {
                    pairedVideoFilenameByHash[fingerprint.contentHash] = pairedVideoFilename
                }
            }
            recordPhotoMetadata(
                contentHash: fingerprint.contentHash,
                fileHash: fingerprint.fileHash,
                isLivePhoto: exported.isLivePhoto
            )
            // #region agent log
            DebugSessionLogger.log(
                hypothesisId: "D",
                location: "SessionManager.appendExportedPhoto",
                message: "local_photo_fingerprinted",
                data: [
                    "source": "live_export",
                    "contentHash12": String(fingerprint.contentHash.prefix(12)),
                    "fileHash12": String(fingerprint.fileHash.prefix(12)),
                    "bytes": exported.stillData.count,
                    "format": fingerprint.format,
                    "w": fingerprint.width,
                    "h": fingerprint.height,
                    "isLive": exported.isLivePhoto,
                    "assetIdSuffix": String((assetLocalIdentifier ?? "").suffix(8)),
                    "stillName": exported.stillFilename
                ],
                runId: "dedup-debug"
            )
            print(
                "[DEDUP] local fingerprint live_export ch=\(fingerprint.contentHash.prefix(12)) fh=\(fingerprint.fileHash.prefix(12)) same=\(fingerprint.contentHash == fingerprint.fileHash) bytes=\(exported.stillData.count) live=\(exported.isLivePhoto)"
            )
            // #endregion
        } catch {
            print("[Session] Fingerprint error: \(error)")
        }
    }

    private func appendStillData(
        _ data: Data,
        isLivePhoto: Bool,
        assetLocalIdentifier: String?,
        to photos: inout [LocalPhoto]
    ) {
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
                isLivePhoto: isLivePhoto,
                thumbnailData: thumbnail,
                fileURL: tempURL,
                assetLocalIdentifier: assetLocalIdentifier,
                pairedVideoURL: nil
            )
            photos.append(photo)
            photoStore[fingerprint.contentHash] = tempURL
            recordPhotoMetadata(contentHash: fingerprint.contentHash, fileHash: fingerprint.fileHash, isLivePhoto: isLivePhoto)
            // #region agent log
            DebugSessionLogger.log(
                hypothesisId: "D",
                location: "SessionManager.appendStillData",
                message: "local_photo_fingerprinted",
                data: [
                    "source": "still_data",
                    "contentHash12": String(fingerprint.contentHash.prefix(12)),
                    "fileHash12": String(fingerprint.fileHash.prefix(12)),
                    "bytes": data.count,
                    "format": fingerprint.format,
                    "w": fingerprint.width,
                    "h": fingerprint.height,
                    "isLive": isLivePhoto,
                    "assetIdSuffix": String((assetLocalIdentifier ?? "").suffix(8))
                ],
                runId: "dedup-debug"
            )
            print(
                "[DEDUP] local fingerprint still_data ch=\(fingerprint.contentHash.prefix(12)) fh=\(fingerprint.fileHash.prefix(12)) same=\(fingerprint.contentHash == fingerprint.fileHash) bytes=\(data.count) live=\(isLivePhoto)"
            )
            // #endregion
        } catch {
            print("[Session] Fingerprint error: \(error)")
        }
    }

    // MARK: - Start Sharing

    func startSharing() async {
        guard JoinCodeGenerator.isValid(joinCodeInput) else { return }

        let joinCode = joinCodeInput
        let sessionId = UUID().uuidString

        sessionState.sessionId = sessionId
        sessionState.joinCode = joinCode
        sessionState.localPhotos = selectedPhotos
        sessionState.receivedPhotos.removeAll()
        sessionState.members.removeAll()
        sessionState.securityCode = nil
        sessionState.photosReceived = 0
        sessionState.photosToReceive = 0
        sessionState.phase = .discovering
        isSharing = true
        isTransferNetworkActive = false
        shouldPopSharingUI = false
        discoveryStartTime = Date()

        do {
            _ = try controlChannel.startServer { [weak self] envelope in
                Task { @MainActor in
                    self?.handleControlMessage(envelope)
                }
            }
            _ = try transferChannel.startServer(
                onComplete: { [weak self] transferId, stillData, pairedVideoData, contentHash, stillFilename, pairedVideoFilename in
                    Task { @MainActor in
                        self?.handleTransferComplete(
                            transferId: transferId,
                            stillData: stillData,
                            pairedVideoData: pairedVideoData,
                            contentHash: contentHash,
                            stillFilename: stillFilename,
                            pairedVideoFilename: pairedVideoFilename
                        )
                    }
                },
                onProgress: { [weak self] transferId, received, total in
                    Task { @MainActor in
                        self?.updateTransferProgress(received: received, total: total)
                    }
                },
                onFailed: { [weak self] transferId, reason in
                    Task { @MainActor in
                        self?.handleTransferReceiveFailed(transferId: transferId, reason: reason)
                    }
                }
            )
            let transferReady = await transferChannel.waitUntilReady()
            if !transferReady {
                sessionState.phase = .failed("传输服务未就绪")
                return
            }
            isTransferNetworkActive = true
        } catch {
            sessionState.phase = .failed("无法启动网络服务: \(error.localizedDescription)")
            return
        }

        hasJoinedRemoteSession = false
        isLeaving = false
        hasExecutedTransferPlan = false
        groupBarrier.reset()
        groupSettleTask?.cancel()
        groupSettleTask = nil
        isCoordinator = true
        sessionState.coordinatorDeviceId = identity.deviceId
        addSelfAsMember(isCoordinator: true)

        controlChannel.registerBonjourAdvertisement(
            deviceId: identity.deviceId,
            joinCode: joinCode,
            sessionId: sessionId,
            displayName: identity.userName,
            avatarId: identity.avatarId
        )

        discovery.start(
            joinCode: joinCode,
            deviceId: identity.deviceId,
            sessionId: sessionId,
            avatarId: identity.avatarId
        ) { [weak self] ad, endpoint in
            Task { @MainActor in
                self?.handleDiscovery(ad, endpoint: endpoint)
            }
        }
    }

    func confirmSharing() {
        Task {
            _ = await transferChannel.waitUntilReady()
            await MainActor.run {
                performConfirmSharing()
            }
        }
    }

    private func performConfirmSharing() {
        guard sessionState.phase == .waitingConfirmation else { return }

        refreshLocalMemberEndpoints()
        syncCoordinatorMembers()
        updateMemberConfirmation(deviceId: identity.deviceId, confirmed: true)
        broadcastSecurityConfirm(confirmed: true)
        announceEndpointsToCoordinator()
        reconcileCoordinatorElection()
        if isCoordinator {
            broadcastMembershipUpdate()
            manifestReceived.insert(identity.deviceId)
        }
        sendPhotoManifest()
        advancePhaseIfAllConfirmed()
    }

    func unconfirmSharing() {
        guard sessionState.phase == .waitingConfirmation || sessionState.phase == .syncingMetadata else {
            return
        }
        guard localMemberConfirmed else { return }

        syncCoordinatorMembers()
        updateMemberConfirmation(deviceId: identity.deviceId, confirmed: false)
        broadcastSecurityConfirm(confirmed: false)
        if isCoordinator {
            broadcastMembershipUpdate()
        }
        manifestReceived.remove(identity.deviceId)
        sessionState.phase = .waitingConfirmation
    }

    func cancelSharing() {
        guard !isLeaving else { return }
        isLeaving = true

        // 仅共享成功后的退出才清空主页选图与加入码；发现/确认阶段返回应保留
        let clearHomeSelection: Bool = {
            switch sessionState.phase {
            case .completed, .awaitingGroupSync:
                return true
            default:
                return false
            }
        }()

        let shouldNotifyGroup = isTransferNetworkActive
            && sessionState.members.contains { $0.deviceId != identity.deviceId }
        if shouldNotifyGroup {
            notifyGroupLeave()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                self.cleanupSession(clearPhotos: clearHomeSelection)
            }
        } else {
            cleanupSession(clearPhotos: clearHomeSelection)
        }
    }

    func acknowledgeSharingUIPopped() {
        shouldPopSharingUI = false
    }

    // MARK: - Discovery

    private func handleDiscovery(_ ad: DiscoveryAdvertisementPayload, endpoint: NWEndpoint) {
        guard ad.deviceId != identity.deviceId else { return }
        guard ad.joinCode == sessionState.joinCode else { return }

        peerEndpoints[ad.deviceId] = endpoint
        ensureLocalMemberPresent()

        if !nearbyDevices.contains(where: { $0.deviceId == ad.deviceId }) {
            nearbyDevices.append(ad)

            if let start = discoveryStartTime {
                let elapsed = Date().timeIntervalSince(start)
                print("[Discovery] Found device in \(String(format: "%.2f", elapsed))s")
            }
        }

        upsertDiscoveredPeer(ad, isPeerCoordinator: ad.deviceId < identity.deviceId)
        reconcileCoordinatorElection(
            peerSessionId: ad.sessionId,
            peerDeviceId: ad.deviceId
        )
        promoteToWaitingConfirmationIfNeeded()
    }

    private func promoteToWaitingConfirmationIfNeeded() {
        if sessionState.phase == .discovering && sessionState.members.count > 1 {
            sessionState.phase = .waitingConfirmation
            regenerateSecurityCode()
        }
    }

    /// 全员中 deviceId 最小者任协调者；切换后必须重发清单，否则三人局会卡在 syncingMetadata
    private func reconcileCoordinatorElection(peerSessionId: String? = nil, peerDeviceId: String? = nil) {
        ensureLocalMemberPresent()
        let memberIds = sessionState.members.map(\.deviceId)
        guard let elected = memberIds.min() else { return }

        let previousCoordinator = sessionState.coordinatorDeviceId
        let wasCoordinator = isCoordinator

        if elected == identity.deviceId {
            if !wasCoordinator || previousCoordinator != identity.deviceId {
                print("[Session] become elected coordinator members=\(memberIds.count)")
                becomeCoordinator()
                if let joinCode = sessionState.joinCode, let sessionId = sessionState.sessionId {
                    controlChannel.registerBonjourAdvertisement(
                        deviceId: identity.deviceId,
                        joinCode: joinCode,
                        sessionId: sessionId,
                        displayName: identity.userName,
                        avatarId: identity.avatarId
                    )
                }
                if localMemberConfirmed {
                    manifestReceived.insert(identity.deviceId)
                    sendPhotoManifest(force: true)
                }
                broadcastMembershipUpdate()
                tryStartTransferIfReady()
            }
            return
        }

        // 跟随更小 deviceId 的协调者
        isCoordinator = false
        hasJoinedRemoteSession = true
        sessionState.coordinatorDeviceId = elected

        if let peerDeviceId, peerDeviceId == elected, let peerSessionId {
            sessionState.sessionId = peerSessionId
        } else if let nearby = nearbyDevices.first(where: { $0.deviceId == elected }) {
            sessionState.sessionId = nearby.sessionId
        }

        let coordinatorChanged = previousCoordinator != elected
        let needJoin = coordinatorChanged
            || !controlChannel.hasConnection(to: elected)

        if needJoin, let nearby = nearbyDevices.first(where: { $0.deviceId == elected }) {
            print("[Session] follow coordinator \(elected.prefix(8)) reconnect=\(needJoin)")
            Task {
                _ = await transferChannel.waitUntilReady()
                await MainActor.run {
                    self.joinExistingSession(nearby)
                    if self.localMemberConfirmed {
                        self.sendPhotoManifest(force: true)
                    }
                }
            }
        } else if localMemberConfirmed, coordinatorChanged || wasCoordinator {
            print("[Session] coordinator changed \(previousCoordinator?.prefix(8) ?? "nil") → \(elected.prefix(8)), resend manifest")
            sendPhotoManifest(force: true)
        }
    }

    private func becomeCoordinator() {
        isCoordinator = true
        sessionState.coordinatorDeviceId = identity.deviceId
        if sessionState.members.contains(where: { $0.deviceId == identity.deviceId }) {
            mutateSessionState { state in
                if let index = state.members.firstIndex(where: { $0.deviceId == identity.deviceId }) {
                    state.members[index].isCoordinator = true
                }
            }
        } else {
            addSelfAsMember(isCoordinator: true)
        }
        syncCoordinatorMembers()
    }

    private func joinExistingSession(_ ad: DiscoveryAdvertisementPayload) {
        sessionState.sessionId = ad.sessionId
        sessionState.coordinatorDeviceId = ad.deviceId
        isCoordinator = false
        hasJoinedRemoteSession = true

        guard let endpoint = peerEndpoints[ad.deviceId] else {
            print("[Session] join missing endpoint for \(ad.deviceId.prefix(8))")
            return
        }
        controlChannel.connect(to: endpoint, deviceId: ad.deviceId)

        let device = DeviceInfoPayload(
            deviceId: identity.deviceId,
            userName: identity.userName,
            avatarId: identity.avatarId,
            sessionId: sessionState.sessionId ?? "",
            joinCode: sessionState.joinCode ?? "",
            networkEndpoint: localHostAddress(),
            capabilities: ["photo_share", "relay"],
            controlPort: controlChannel.controlPort,
            transferPort: transferChannel.port
        )

        guard let envelope = try? ProtocolEnvelope(
            messageType: .joinRequest,
            deviceId: identity.deviceId,
            sessionId: sessionState.sessionId,
            payload: JoinRequestPayload(device: device)
        ) else { return }

        // Bonjour 连接建立需要一点时间，失败则重试
        Task { @MainActor in
            for attempt in 0..<5 {
                if attempt > 0 {
                    try? await Task.sleep(for: .milliseconds(250))
                    if let endpoint = self.peerEndpoints[ad.deviceId] {
                        self.controlChannel.connect(to: endpoint, deviceId: ad.deviceId)
                    }
                }
                if self.ensureControlSend(envelope, to: ad.deviceId) {
                    print("[Session] joinRequest sent to \(ad.deviceId.prefix(8)) attempt=\(attempt)")
                    return
                }
            }
            print("[Session] joinRequest FAILED to \(ad.deviceId.prefix(8))")
        }
    }

    @discardableResult
    private func ensureControlSend(_ envelope: ProtocolEnvelope, to deviceId: String) -> Bool {
        if let sent = try? controlChannel.send(envelope, to: deviceId), sent {
            return true
        }
        if let endpoint = peerEndpoints[deviceId] {
            controlChannel.connect(to: endpoint, deviceId: deviceId)
        } else if let member = sessionState.members.first(where: { $0.deviceId == deviceId }),
                  NetworkUtility.isUsableTransferHost(member.networkEndpoint),
                  member.controlPort > 0 {
            controlChannel.connect(
                to: member.networkEndpoint,
                port: member.controlPort,
                deviceId: deviceId
            )
        }
        return (try? controlChannel.send(envelope, to: deviceId)) ?? false
    }

    private func addSelfAsMember(isCoordinator: Bool) {
        let member = SharingMember(
            deviceId: identity.deviceId,
            userName: identity.userName,
            avatarId: identity.avatarId,
            networkEndpoint: localHostAddress(),
            controlPort: controlChannel.controlPort,
            transferPort: transferChannel.port,
            isCoordinator: isCoordinator,
            confirmed: false,
            discoveredAt: Date()
        )
        mutateSessionState { state in
            if !state.members.contains(where: { $0.deviceId == identity.deviceId }) {
                state.members.insert(member, at: 0)
            } else if let index = state.members.firstIndex(where: { $0.deviceId == identity.deviceId }) {
                state.members[index].transferPort = transferChannel.port
                state.members[index].controlPort = controlChannel.controlPort
                state.members[index].networkEndpoint = localHostAddress()
                state.members[index].isCoordinator = isCoordinator
                state.members[index].userName = identity.userName
                state.members[index].avatarId = identity.avatarId
            }
        }
        syncCoordinatorMembers()
    }

    /// 成员列表同步后必须始终包含本机，否则会出现「只看到别人」
    private func ensureLocalMemberPresent() {
        guard isSharing else { return }
        if !sessionState.members.contains(where: { $0.deviceId == identity.deviceId }) {
            addSelfAsMember(isCoordinator: isCoordinator)
        }
    }

    private func upsertDiscoveredPeer(_ ad: DiscoveryAdvertisementPayload, isPeerCoordinator: Bool) {
        mutateSessionState { state in
            if let index = state.members.firstIndex(where: { $0.deviceId == ad.deviceId }) {
                state.members[index].userName = ad.displayName
                state.members[index].avatarId = ad.avatarId
                state.members[index].networkEndpoint = ad.networkEndpoint
                state.members[index].controlPort = ad.controlPort
            } else {
                state.members.append(
                    SharingMember(
                        deviceId: ad.deviceId,
                        userName: ad.displayName,
                        avatarId: ad.avatarId,
                        networkEndpoint: ad.networkEndpoint,
                        controlPort: ad.controlPort,
                        transferPort: 0,
                        isCoordinator: isPeerCoordinator,
                        confirmed: false
                    )
                )
            }
        }
        ensureLocalMemberPresent()
        syncCoordinatorMembers()
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
        case .sessionPhase:
            handleSessionPhase(envelope)
        case .joinLeave:
            handleJoinLeave(envelope)
        case .securityConfirm:
            handleSecurityConfirm(envelope)
        case .photoManifest:
            handlePhotoManifest(envelope)
        case .transferPlan:
            handleTransferPlan(envelope)
        case .transferAssign:
            handleTransferAssign(envelope)
        case .transferFailed:
            handleTransferFailedMessage(envelope)
        case .coordinatorElected:
            handleCoordinatorElected(envelope)
        case .sessionComplete:
            handleSessionComplete(envelope)
        default:
            break
        }
    }

    private func handleJoinRequest(_ envelope: ProtocolEnvelope) {
        guard isCoordinator else { return }
        guard let payload = try? envelope.decodePayload(JoinRequestPayload.self) else { return }
        ensureLocalMemberPresent()
        guard sessionState.members.count < ProtocolConstants.maxMembers
            || sessionState.members.contains(where: { $0.deviceId == payload.device.deviceId }) else { return }

        let joinedAt = Date().timeIntervalSince1970
        let member = SharingMember(
            deviceId: payload.device.deviceId,
            userName: payload.device.userName,
            avatarId: payload.device.avatarId,
            networkEndpoint: payload.device.networkEndpoint,
            controlPort: payload.device.controlPort,
            transferPort: payload.device.transferPort,
            isCoordinator: false,
            confirmed: false,
            joinedAt: joinedAt,
            discoveredAt: Date(timeIntervalSince1970: joinedAt)
        )

        let isNewMember = !sessionState.members.contains(where: { $0.deviceId == member.deviceId })
        if isNewMember {
            mutateSessionState { state in
                state.members.append(member)
            }
            if let endpoint = peerEndpoints[payload.device.deviceId] {
                controlChannel.connect(to: endpoint, deviceId: payload.device.deviceId)
            } else if NetworkUtility.isUsableTransferHost(payload.device.networkEndpoint) {
                controlChannel.connect(
                    to: payload.device.networkEndpoint,
                    port: payload.device.controlPort,
                    deviceId: payload.device.deviceId
                )
            } else {
                print("[Session] joinRequest from \(payload.device.deviceId.prefix(8)) has unusable host \(payload.device.networkEndpoint)")
            }
            if sessionState.phase == .discovering {
                sessionState.phase = .waitingConfirmation
            }
            regenerateSecurityCode()
            syncCoordinatorMembers()
        } else {
            mutateSessionState { state in
                guard let index = state.members.firstIndex(where: { $0.deviceId == member.deviceId }) else {
                    return
                }
                state.members[index].userName = member.userName
                state.members[index].avatarId = member.avatarId
                state.members[index].networkEndpoint = member.networkEndpoint
                state.members[index].controlPort = member.controlPort
                state.members[index].transferPort = member.transferPort
            }
            syncCoordinatorMembers()
        }

        ensureLocalMemberPresent()
        let roster = sessionState.members
        let acceptPayload = JoinAcceptPayload(
            accepted: true,
            coordinatorDeviceId: identity.deviceId,
            members: roster.map { $0.toPayload() },
            reason: nil
        )

        if let response = try? ProtocolEnvelope(
            messageType: .joinAccept,
            deviceId: identity.deviceId,
            sessionId: sessionState.sessionId,
            payload: acceptPayload
        ) {
            _ = ensureControlSend(response, to: payload.device.deviceId)
            broadcastMembershipUpdate()
            reconcileCoordinatorElection()
            tryStartTransferIfReady()
        }
    }

    private func handleJoinAccept(_ envelope: ProtocolEnvelope) {
        guard let payload = try? envelope.decodePayload(JoinAcceptPayload.self) else { return }
        sessionState.sessionId = envelope.sessionId ?? sessionState.sessionId
        sessionState.coordinatorDeviceId = payload.coordinatorDeviceId
        isCoordinator = payload.coordinatorDeviceId == identity.deviceId
        hasJoinedRemoteSession = !isCoordinator
        applyMemberList(payload.members.map { SharingMember(from: $0) })
        ensureLocalMemberPresent()
        sessionState.phase = .waitingConfirmation
        syncCoordinatorMembers()
        regenerateSecurityCode()
        reconcileCoordinatorElection()
        if localMemberConfirmed {
            sendPhotoManifest(force: true)
        }
    }

    private func handleMembershipUpdate(_ envelope: ProtocolEnvelope) {
        guard let payload = try? envelope.decodePayload(MembershipUpdatePayload.self) else { return }
        applyMemberList(payload.members.map { SharingMember(from: $0) })
        ensureLocalMemberPresent()
        let code = payload.securityCode
        mutateSessionState { state in
            state.securityCode = code.isEmpty ? nil : code
        }
        syncCoordinatorMembers()
        syncConfirmationsFromMembers()
        let previousCoordinator = lastManifestTargetCoordinatorId
        reconcileCoordinatorElection()

        // 仅协调者变更时重发清单，避免全员同时确认引发清单风暴/崩溃
        if localMemberConfirmed,
           sessionState.coordinatorDeviceId != previousCoordinator,
           sessionState.phase == .waitingConfirmation
            || sessionState.phase == .syncingMetadata {
            sendPhotoManifest(force: true)
        }

        // 已进入同步/传输后，不再因过期 membership 把阶段打回确认页
        if sessionState.phase == .waitingConfirmation {
            advancePhaseIfAllConfirmed()
        } else if sessionState.phase == .syncingMetadata {
            if isCoordinator {
                tryStartTransferIfReady()
            }
        } else if sessionState.phase == .transferring {
            executeLocalTransfers()
        }
    }

    private func handleSessionPhase(_ envelope: ProtocolEnvelope) {
        guard let payload = try? envelope.decodePayload(SessionPhasePayload.self) else { return }
        switch payload.phase {
        case "syncing_metadata":
            if sessionState.phase == .waitingConfirmation {
                sessionState.phase = .syncingMetadata
            }
        case "group_complete":
            sessionState.phase = .completed
            groupBarrier.applyRemoteGroupComplete()
            settleGroupTransfer()
        default:
            break
        }
    }

    private func handleJoinLeave(_ envelope: ProtocolEnvelope) {
        guard let payload = try? envelope.decodePayload(JoinLeavePayload.self) else { return }
        let removed = sessionState.members.contains { $0.deviceId == payload.deviceId }
        removeMember(deviceId: payload.deviceId)
        let leaveAction = groupBarrier.removeMember(
            deviceId: payload.deviceId,
            isCoordinator: isCoordinator,
            memberIds: Set(sessionState.members.map(\.deviceId))
        )

        if isCoordinator, removed {
            broadcastMembershipUpdate()
            if leaveAction == .settleGroup {
                beginGroupSettle()
            }
        }
    }

    private func handleSecurityConfirm(_ envelope: ProtocolEnvelope) {
        guard let payload = try? envelope.decodePayload(SecurityConfirmPayload.self) else { return }
        syncCoordinatorMembers()
        updateMemberConfirmation(deviceId: envelope.deviceId, confirmed: payload.confirmed)

        if isCoordinator {
            broadcastMembershipUpdate()
            // 把确认状态再推一遍，降低同时点击时丢包导致「有人永远看不到全员确认」
            if payload.confirmed {
                for member in sessionState.members
                where member.deviceId != identity.deviceId && member.deviceId != envelope.deviceId {
                    if let relay = try? ProtocolEnvelope(
                        messageType: .securityConfirm,
                        deviceId: envelope.deviceId,
                        sessionId: sessionState.sessionId,
                        payload: payload
                    ) {
                        _ = ensureControlSend(relay, to: member.deviceId)
                    }
                }
            }
        }

        if !payload.confirmed {
            manifestReceived.remove(envelope.deviceId)
            if sessionState.phase == .syncingMetadata, !hasExecutedTransferPlan {
                sessionState.phase = .waitingConfirmation
            }
            return
        }

        advancePhaseIfAllConfirmed()
    }

    private func handlePhotoManifest(_ envelope: ProtocolEnvelope) {
        // 忽略本机清单回环（provisional 连接广播曾导致自收自激风暴/崩溃）
        guard envelope.deviceId != identity.deviceId else { return }
        guard let payload = try? envelope.decodePayload(PhotoManifestPayload.self) else { return }

        let isNew = !manifestReceived.contains(envelope.deviceId)
        coordinator.handlePhotoManifest(from: envelope.deviceId, photos: payload.photos)
        manifestReceived.insert(envelope.deviceId)
        for photo in payload.photos {
            recordPhotoMetadata(contentHash: photo.contentHash, fileHash: photo.fileHash, isLivePhoto: photo.isLivePhoto)
        }

        // #region agent log
        logDedupManifest(
            stage: "recv_manifest",
            fromDeviceId: envelope.deviceId,
            photos: payload.photos
        )
        // #endregion

        if isCoordinator, isNew {
            controlChannel.broadcast(envelope, excluding: envelope.deviceId)
            tryStartTransferIfReady()
        } else if isCoordinator {
            tryStartTransferIfReady()
        }
    }

    private func handleTransferPlan(_ envelope: ProtocolEnvelope) {
        guard let payload = try? envelope.decodePayload(TransferPlanPayload.self) else { return }
        guard !hasExecutedTransferPlan else { return }
        hasExecutedTransferPlan = true
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
        coordinator.scheduler.loadPlan(activeTransferTasks)
        // #region agent log
        DebugSessionLogger.log(
            hypothesisId: "D",
            location: "SessionManager.handleTransferPlan",
            message: "plan_loaded_for_member",
            data: [
                "deviceId": String(identity.deviceId.prefix(8)),
                "taskCount": activeTransferTasks.count,
                "incoming": activeTransferTasks.filter {
                    $0.destinationDeviceId == identity.deviceId
                }.map { String($0.contentHash.prefix(12)) }.joined(separator: ","),
                "outgoing": activeTransferTasks.filter {
                    $0.sourceDeviceId == identity.deviceId
                }.map { String($0.contentHash.prefix(12)) }.joined(separator: ","),
                "allTasks": activeTransferTasks.map {
                    "\($0.sourceDeviceId.prefix(8))->\($0.destinationDeviceId.prefix(8)):\($0.contentHash.prefix(12))"
                }.joined(separator: ",")
            ],
            runId: "dedup-debug"
        )
        print("[DEDUP] member received plan tasks=\(activeTransferTasks.count) incoming=\(activeTransferTasks.filter { $0.destinationDeviceId == identity.deviceId }.map { String($0.contentHash.prefix(12)) }.joined(separator: ","))")
        // #endregion
        applyIncomingPhotoCount()
        sessionState.phase = .transferring
        executeLocalTransfers()
        checkCompletion()
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
        coordinator.scheduler.adoptTask(task)
        executeLocalTransfers()
    }

    private func handleCoordinatorElected(_ envelope: ProtocolEnvelope) {
        if let payload = try? envelope.decodePayload(JoinAcceptPayload.self) {
            sessionState.coordinatorDeviceId = payload.coordinatorDeviceId
            isCoordinator = payload.coordinatorDeviceId == identity.deviceId
        }
    }

    // MARK: - Metadata & Transfer

    private func advancePhaseIfAllConfirmed() {
        syncCoordinatorMembers()
        guard sessionState.phase == .waitingConfirmation else { return }
        guard sessionState.members.count > 1 else { return }
        guard coordinator.allConfirmed(members: sessionState.members) else { return }

        // 全员本机已确认：立刻进传输页，不再依赖 sessionPhase 广播（丢包时两人卡住）
        sessionState.phase = .syncingMetadata
        print("[Session] all confirmed → syncingMetadata coord=\(isCoordinator) members=\(sessionState.members.count)")

        if isCoordinator {
            broadcastSessionPhase(.syncingMetadata)
            // 再逐个补发 phase，避免有人收不到 broadcast
            if let envelope = try? ProtocolEnvelope(
                messageType: .sessionPhase,
                deviceId: identity.deviceId,
                sessionId: sessionState.sessionId,
                payload: SessionPhasePayload(phase: "syncing_metadata")
            ) {
                for member in sessionState.members where member.deviceId != identity.deviceId {
                    _ = ensureControlSend(envelope, to: member.deviceId)
                }
            }
            tryStartTransferIfReady()
        }
    }

    private func tryStartTransferIfReady() {
        guard isCoordinator else { return }
        guard !hasExecutedTransferPlan else { return }
        syncCoordinatorMembers()
        let confirmed = coordinator.allConfirmed(members: sessionState.members)
        let manifestsReady = manifestReceived.count >= sessionState.members.count
        if !confirmed || !manifestsReady {
            let missing = Set(sessionState.members.map(\.deviceId)).subtracting(manifestReceived)
            let missingLabel = missing.map { String($0.prefix(8)) }.sorted().joined(separator: ",")
            print(
                "[Session] transfer not ready confirmed=\(confirmed) manifests=\(manifestReceived.count)/\(sessionState.members.count) missing=[\(missingLabel)]"
            )
            // #region agent log
            DebugSessionLogger.log(
                hypothesisId: "D",
                location: "SessionManager.tryStartTransferIfReady",
                message: "waiting",
                data: [
                    "confirmed": confirmed,
                    "manifestCount": manifestReceived.count,
                    "memberCount": sessionState.members.count,
                    "manifests": manifestReceived.map { String($0.prefix(8)) }.sorted().joined(separator: ","),
                    "members": sessionState.members.map { String($0.deviceId.prefix(8)) }.sorted().joined(separator: ","),
                    "missing": missingLabel
                ],
                runId: "dedup-debug"
            )
            // #endregion
            return
        }
        executeTransferPlan()
    }

    private func sendPhotoManifest(force: Bool = false) {
        let targetCoordinator = sessionState.coordinatorDeviceId
        let now = Date()
        if !force,
           lastManifestTargetCoordinatorId == targetCoordinator,
           let last = lastManifestSendAt,
           now.timeIntervalSince(last) < 1.0 {
            return
        }

        let photos = selectedPhotos.map { $0.toMetadata(ownerDeviceId: identity.deviceId) }
        let payload = PhotoManifestPayload(photos: photos)

        coordinator.handlePhotoManifest(from: identity.deviceId, photos: photos)
        for photo in photos {
            recordPhotoMetadata(contentHash: photo.contentHash, fileHash: photo.fileHash, isLivePhoto: photo.isLivePhoto)
        }
        if isCoordinator {
            manifestReceived.insert(identity.deviceId)
        }

        // #region agent log
        logDedupManifest(
            stage: "send_local_manifest",
            fromDeviceId: identity.deviceId,
            photos: photos
        )
        // #endregion

        guard let envelope = try? ProtocolEnvelope(
            messageType: .photoManifest,
            deviceId: identity.deviceId,
            sessionId: sessionState.sessionId,
            payload: payload
        ) else { return }

        lastManifestSendAt = now
        lastManifestTargetCoordinatorId = targetCoordinator

        if let coordinatorId = targetCoordinator,
           coordinatorId != identity.deviceId {
            Task { @MainActor in
                for attempt in 0..<5 {
                    if self.ensureControlSend(envelope, to: coordinatorId) {
                        print("[Session] manifest sent to coordinator \(coordinatorId.prefix(8)) attempt=\(attempt)")
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                    if let endpoint = self.peerEndpoints[coordinatorId] {
                        self.controlChannel.connect(to: endpoint, deviceId: coordinatorId)
                    }
                }
                print("[Session] manifest FAILED to reach coordinator \(coordinatorId.prefix(8))")
            }
        } else if isCoordinator {
            controlChannel.broadcast(envelope, excluding: identity.deviceId)
            tryStartTransferIfReady()
        }
    }

    private func incomingPhotoCount(for deviceId: String) -> Int {
        Set(
            activeTransferTasks
                .filter { $0.destinationDeviceId == deviceId }
                .map(\.contentHash)
        ).count
    }

    private func applyIncomingPhotoCount() {
        sessionState.photosToReceive = incomingPhotoCount(for: identity.deviceId)
    }

    private func executeTransferPlan() {
        guard !hasExecutedTransferPlan else { return }
        hasExecutedTransferPlan = true
        let tasks = coordinator.generateTransferPlan()
        // #region agent log
        logDedupTransferPlan(tasks: tasks)
        DebugSessionLogger.log(
            hypothesisId: "E",
            location: "SessionManager.executeTransferPlan",
            message: "transfer_plan_generated",
            data: [
                "deviceId": identity.deviceId,
                "taskCount": tasks.count,
                "tasks": tasks.map {
                    "\($0.sourceDeviceId)->\($0.destinationDeviceId):\(String($0.contentHash.prefix(8)))"
                }.joined(separator: ",")
            ],
            runId: "dedup-debug"
        )
        // #endregion
        let payload = TransferPlanPayload(tasks: tasks.map { $0.toPayload() })

        if let envelope = try? ProtocolEnvelope(
            messageType: .transferPlan,
            deviceId: identity.deviceId,
            sessionId: sessionState.sessionId,
            payload: payload
        ) {
            controlChannel.broadcast(envelope)
            // 逐个补发 + 短重试，避免同时确认时部分连接未就绪
            Task { @MainActor in
                for attempt in 0..<5 {
                    var allSent = true
                    for member in self.sessionState.members where member.deviceId != self.identity.deviceId {
                        if !self.ensureControlSend(envelope, to: member.deviceId) {
                            allSent = false
                        }
                    }
                    if allSent {
                        print("[Session] transfer plan delivered to all members attempt=\(attempt)")
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(350))
                }
                print("[Session] transfer plan delivery incomplete after retries")
            }
        }

        activeTransferTasks = tasks
        applyIncomingPhotoCount()
        sessionState.phase = .transferring
        executeLocalTransfers()
        checkCompletion()
    }

    private func executeLocalTransfers() {
        var readyUploads = coordinator.scheduler.nextTasks(
            for: identity.deviceId,
            role: .source,
            limit: ProtocolConstants.maxUploadConnections
        )

        // 兜底：调度图未装载时，直接从本机任务列表取可发任务
        if readyUploads.isEmpty {
            readyUploads = Array(
                activeTransferTasks.filter { task in
                    task.sourceDeviceId == identity.deviceId
                        && (task.state == .pending || task.state == .scheduled || task.state == .rescheduled)
                        && task.dependencyTransferIds.allSatisfy { depId in
                            activeTransferTasks.contains {
                                $0.transferId == depId && ($0.state == .completed || $0.state == .verified)
                            } || depId.isEmpty
                        }
                }.prefix(ProtocolConstants.maxUploadConnections)
            )
        }

        // #region agent log
        DebugSessionLogger.log(
            hypothesisId: "H",
            location: "SessionManager.executeLocalTransfers",
            message: "ready_uploads",
            data: [
                "deviceId": identity.deviceId,
                "count": readyUploads.count,
                "hashes": readyUploads.map { String($0.contentHash.prefix(8)) }.joined(separator: ",")
            ],
            runId: "post-fix"
        )
        // #endregion

        for schedulerTask in readyUploads {
            guard let task = activeTransferTasks.first(where: { $0.transferId == schedulerTask.transferId })
                ?? Optional(schedulerTask) else {
                continue
            }
            guard task.state == .pending || task.state == .scheduled || task.state == .rescheduled else {
                continue
            }
            sendPhotoForTask(task)
        }

        checkCompletion()
    }

    private func sendPhotoForTask(_ task: TransferTask) {
        guard let fileURL = photoStore[task.contentHash] ?? selectedPhotos.first(where: {
            $0.contentHash == task.contentHash
        })?.fileURL else {
            print("[Transfer] missing file for \(task.contentHash)")
            return
        }

        let destMember = sessionState.members.first { $0.deviceId == task.destinationDeviceId }
        let advertisedHost = destMember?.networkEndpoint ?? localHostAddress()
        let resolvedHost = controlChannel.peerNetworkHost(for: task.destinationDeviceId)
        let hostSelection = selectTransferHost(advertisedHost: advertisedHost, resolvedHost: resolvedHost)
        let host = hostSelection.host
        let port = destMember?.transferPort ?? 0
        // #region agent log
        DebugSessionLogger.log(
            hypothesisId: "G",
            location: "SessionManager.sendPhotoForTask",
            message: "send_task",
            data: [
                "transferId": task.transferId,
                "hash": String(task.contentHash.prefix(12)),
                "src": task.sourceDeviceId,
                "dst": task.destinationDeviceId,
                "advertisedHost": advertisedHost,
                "resolvedHost": resolvedHost ?? "nil",
                "usedHost": host,
                "hostSource": hostSelection.source,
                "transferPort": Int(port),
                "localTransferPort": Int(transferChannel.port)
            ],
            runId: "post-fix"
        )
        // #endregion
        guard port > 0 else {
            print("[Transfer] missing transfer port for \(task.destinationDeviceId)")
            // #region agent log
            DebugSessionLogger.log(
                hypothesisId: "C",
                location: "SessionManager.sendPhotoForTask",
                message: "missing_transfer_port",
                data: ["destination": task.destinationDeviceId]
            )
            // #endregion
            announceEndpointsToCoordinator()
            Task {
                try? await Task.sleep(for: .milliseconds(300))
                await MainActor.run {
                    self.executeLocalTransfers()
                }
            }
            return
        }

        updateTaskState(task.transferId, state: .transferring)

        Task {
            do {
                let payload = try Data(contentsOf: fileURL)
                let senderContentOK = (try? PhotoFingerprint.verifyContent(
                    data: payload,
                    expectedContentHash: task.contentHash
                )) ?? false
                let expectedFileHash = photoFileHashByContentHash[task.contentHash]
                let senderFileOK = expectedFileHash.map {
                    PhotoFingerprint.verifyFile(data: payload, expectedFileHash: $0)
                } ?? false
                // #region agent log
                DebugSessionLogger.log(
                    hypothesisId: "F",
                    location: "SessionManager.sendPhotoForTask",
                    message: "sender_pre_verify",
                    data: [
                        "transferId": task.transferId,
                        "contentOK": senderContentOK,
                        "fileOK": senderFileOK,
                        "bytes": payload.count
                    ],
                    runId: "post-fix"
                )
                // #endregion
                guard senderContentOK || senderFileOK else {
                    updateTaskState(task.transferId, state: .failed)
                    coordinator.scheduler.markFailed(task.transferId)
                    executeLocalTransfers()
                    return
                }

                var pairedVideoData: Data
                if let videoURL = pairedVideoStore[task.contentHash] {
                    pairedVideoData = (try? Data(contentsOf: videoURL)) ?? Data()
                } else {
                    pairedVideoData = Data()
                }

                // 标记为实况但缺视频时，从原相册资源重新导出成对视频
                let markedLive = photoIsLiveByHash[task.contentHash] ?? false
                if markedLive && pairedVideoData.isEmpty {
                    let assetId = selectedPhotos.first(where: { $0.contentHash == task.contentHash })?.assetLocalIdentifier
                        ?? sessionState.localPhotos.first(where: { $0.contentHash == task.contentHash })?.assetLocalIdentifier
                    if let assetId,
                       let exported = await LivePhotoExporter.export(fromLocalIdentifier: assetId),
                       let videoURL = exported.pairedVideoURL,
                       let videoData = try? Data(contentsOf: videoURL),
                       !videoData.isEmpty {
                        pairedVideoStore[task.contentHash] = videoURL
                        pairedVideoFilenameByHash[task.contentHash] = exported.pairedVideoFilename ?? videoURL.lastPathComponent
                        pairedVideoData = videoData
                        if stillFilenameByHash[task.contentHash] == nil {
                            stillFilenameByHash[task.contentHash] = exported.stillFilename
                        }
                    }
                }

                // #region agent log
                DebugSessionLogger.log(
                    hypothesisId: "L",
                    location: "SessionManager.sendPhotoForTask",
                    message: "send_live_payload",
                    data: [
                        "transferId": task.transferId,
                        "hash": String(task.contentHash.prefix(12)),
                        "isLive": markedLive,
                        "pairedVideoBytes": pairedVideoData.count,
                        "stillName": stillFilenameByHash[task.contentHash] ?? "",
                        "videoName": pairedVideoFilenameByHash[task.contentHash] ?? ""
                    ],
                    runId: "post-fix"
                )
                // #endregion

                try await transferChannel.sendPhoto(
                    to: host,
                    port: port,
                    transferId: task.transferId,
                    contentHash: task.contentHash,
                    stillData: payload,
                    pairedVideoData: pairedVideoData,
                    stillFilename: stillFilenameByHash[task.contentHash],
                    pairedVideoFilename: pairedVideoFilenameByHash[task.contentHash]
                )
                updateTaskState(task.transferId, state: .completed)
                coordinator.scheduler.markCompleted(task.transferId, contentHash: task.contentHash, deviceId: task.destinationDeviceId)
            } catch {
                print("[Transfer] send failed \(task.transferId): \(error)")
                updateTaskState(task.transferId, state: .failed)
                coordinator.scheduler.markFailed(task.transferId)
                if let newTask = coordinator.scheduler.rescheduleFailedTask(task, members: sessionState.members.map(\.deviceId)) {
                    activeTransferTasks.append(newTask)
                }
            }
            executeLocalTransfers()
        }
    }

    private func handleTransferReceiveFailed(transferId: String, reason: String) {
        guard let task = activeTransferTasks.first(where: { $0.transferId == transferId }) else { return }
        guard task.destinationDeviceId == identity.deviceId else { return }
        guard task.state != .completed && task.state != .verified else { return }

        updateTaskState(transferId, state: .failed)
        // #region agent log
        DebugSessionLogger.log(
            hypothesisId: "B",
            location: "SessionManager.handleTransferReceiveFailed",
            message: "request_resend",
            data: [
                "transferId": transferId,
                "hash": String(task.contentHash.prefix(12)),
                "reason": reason,
                "source": task.sourceDeviceId
            ],
            runId: "post-fix"
        )
        // #endregion

        let payload = TransferFailedPayload(
            transferId: transferId,
            reason: .connectionTimeout
        )
        guard let envelope = try? ProtocolEnvelope(
            messageType: .transferFailed,
            deviceId: identity.deviceId,
            sessionId: sessionState.sessionId,
            payload: payload
        ) else { return }

        if task.sourceDeviceId == identity.deviceId {
            retryLocalUpload(transferId: transferId)
        } else if let coordinatorId = sessionState.coordinatorDeviceId,
                  coordinatorId != identity.deviceId {
            try? controlChannel.send(envelope, to: coordinatorId)
            try? controlChannel.send(envelope, to: task.sourceDeviceId)
        } else {
            controlChannel.broadcast(envelope, excluding: identity.deviceId)
        }
        checkCompletion()
    }

    private func handleTransferFailedMessage(_ envelope: ProtocolEnvelope) {
        guard let payload = try? envelope.decodePayload(TransferFailedPayload.self) else { return }

        if isCoordinator, envelope.deviceId != identity.deviceId {
            controlChannel.broadcast(envelope, excluding: envelope.deviceId)
        }

        guard let task = activeTransferTasks.first(where: { $0.transferId == payload.transferId }) else {
            return
        }
        guard task.sourceDeviceId == identity.deviceId else { return }

        // #region agent log
        DebugSessionLogger.log(
            hypothesisId: "B",
            location: "SessionManager.handleTransferFailedMessage",
            message: "resend_requested",
            data: [
                "transferId": payload.transferId,
                "hash": String(task.contentHash.prefix(12)),
                "from": envelope.deviceId
            ],
            runId: "post-fix"
        )
        // #endregion

        retryLocalUpload(transferId: payload.transferId)
    }

    private func retryLocalUpload(transferId: String) {
        guard let index = activeTransferTasks.firstIndex(where: { $0.transferId == transferId }) else {
            return
        }
        guard activeTransferTasks[index].sourceDeviceId == identity.deviceId else { return }
        activeTransferTasks[index].state = .pending
        coordinator.scheduler.updateTaskState(transferId, state: .pending)
        // 本机收发已完成时仍保持 awaiting，继续提供上传；否则回到传输中
        if sessionState.phase != .awaitingGroupSync && sessionState.phase != .completed {
            sessionState.phase = .transferring
        }
        executeLocalTransfers()
    }

    private func handleTransferComplete(
        transferId: String,
        stillData: Data,
        pairedVideoData: Data?,
        contentHash: String,
        stillFilename: String?,
        pairedVideoFilename: String?
    ) {
        // #region agent log
        DebugSessionLogger.log(
            hypothesisId: "F",
            location: "SessionManager.handleTransferComplete",
            message: "receive_complete",
            data: [
                "transferId": transferId,
                "hash": String(contentHash.prefix(12)),
                "bytes": stillData.count,
                "pairedVideoBytes": pairedVideoData?.count ?? 0,
                "stillName": stillFilename ?? "",
                "videoName": pairedVideoFilename ?? ""
            ]
        )
        // #endregion
        do {
            let verification = try verifyReceivedPhoto(data: stillData, contentHash: contentHash)
            guard verification.accepted else {
                // #region agent log
                DebugSessionLogger.log(
                    hypothesisId: "F",
                    location: "SessionManager.handleTransferComplete",
                    message: "hash_verify_failed",
                    data: [
                        "transferId": transferId,
                        "hash": String(contentHash.prefix(12)),
                        "computedContent": String(verification.computedContentHash.prefix(12)),
                        "computedFile": String(verification.computedFileHash.prefix(12)),
                        "expectedFile": String((photoFileHashByContentHash[contentHash] ?? "").prefix(12)),
                        "usedFileHashFallback": verification.usedFileHashFallback
                    ],
                    runId: "post-fix"
                )
                // #endregion
                coordinator.scheduler.markFailed(transferId)
                updateTaskState(transferId, state: .failed)
                return
            }

            if verification.usedFileHashFallback {
                // #region agent log
                DebugSessionLogger.log(
                    hypothesisId: "F",
                    location: "SessionManager.handleTransferComplete",
                    message: "accepted_via_file_hash",
                    data: ["transferId": transferId, "hash": String(contentHash.prefix(12))],
                    runId: "post-fix"
                )
                // #endregion
            }

            let tempURL = saveTempFile(data: stillData, id: contentHash)
            photoStore[contentHash] = tempURL
            var pairedVideoURL: URL?
            if let pairedVideoData, !pairedVideoData.isEmpty {
                let videoURL = savePairedVideoTempFile(data: pairedVideoData, id: contentHash)
                pairedVideoStore[contentHash] = videoURL
                pairedVideoURL = videoURL
                photoIsLiveByHash[contentHash] = true
                if let pairedVideoFilename {
                    pairedVideoFilenameByHash[contentHash] = pairedVideoFilename
                }
            }
            if let stillFilename {
                stillFilenameByHash[contentHash] = stillFilename
            }
            let thumbnail = generateThumbnail(from: stillData)

            let sourceMember = sessionState.members.first {
                activeTransferTasks.first { $0.transferId == transferId }?.sourceDeviceId == $0.deviceId
            }

            let received = ReceivedPhoto(
                id: UUID().uuidString,
                contentHash: contentHash,
                thumbnailData: thumbnail,
                sourceUserName: sourceMember?.userName ?? "未知",
                sourceDeviceId: sourceMember?.deviceId ?? "",
                isLivePhoto: pairedVideoURL != nil || (photoIsLiveByHash[contentHash] ?? false),
                libraryAssetIdentifier: nil
            )

            guard !sessionState.receivedPhotos.contains(where: { $0.contentHash == contentHash }) else {
                updateTaskState(transferId, state: .completed)
                coordinator.scheduler.markCompleted(transferId, contentHash: contentHash, deviceId: identity.deviceId)
                checkCompletion()
                executeLocalTransfers()
                return
            }

            sessionState.receivedPhotos.append(received)
            sessionState.photosReceived += 1
            updateTaskState(transferId, state: .completed)
            coordinator.scheduler.markCompleted(transferId, contentHash: contentHash, deviceId: identity.deviceId)
            let isLivePhoto = (pairedVideoURL != nil) || (photoIsLiveByHash[contentHash] ?? false)
            importReceivedPhotoToLibrary(
                stillURL: tempURL,
                stillFilename: stillFilenameByHash[contentHash],
                pairedVideoURL: pairedVideoURL,
                pairedVideoFilename: pairedVideoFilenameByHash[contentHash],
                isLivePhoto: isLivePhoto,
                contentHash: contentHash
            )

            checkCompletion()
            executeLocalTransfers()
        } catch {
            coordinator.scheduler.markFailed(transferId)
            updateTaskState(transferId, state: .failed)
        }
    }

    private func checkCompletion() {
        let myReceiveTasks = activeTransferTasks.filter { $0.destinationDeviceId == identity.deviceId }
        let receiveDone = myReceiveTasks.isEmpty || myReceiveTasks.allSatisfy {
            isTaskFinished($0, role: .destination)
        }
        let receivedEnough = sessionState.photosReceived >= sessionState.photosToReceive

        let myUploadTasks = activeTransferTasks.filter { $0.sourceDeviceId == identity.deviceId }
        let uploadDone = myUploadTasks.isEmpty || myUploadTasks.allSatisfy {
            isTaskFinished($0, role: .source)
        }

        guard receiveDone, receivedEnough, uploadDone else {
            // #region agent log
            DebugSessionLogger.log(
                hypothesisId: "D",
                location: "SessionManager.checkCompletion",
                message: "not_complete",
                data: [
                    "deviceId": identity.deviceId,
                    "receiveDone": receiveDone,
                    "receivedEnough": receivedEnough,
                    "uploadDone": uploadDone,
                    "photosReceived": sessionState.photosReceived,
                    "photosToReceive": sessionState.photosToReceive,
                    "pendingReceive": myReceiveTasks.filter {
                        $0.state != .completed && $0.state != .verified
                    }.map { "\($0.contentHash.prefix(8)):\($0.state.rawValue)" }.joined(separator: ","),
                    "pendingUpload": myUploadTasks.filter {
                        $0.state != .completed && $0.state != .verified
                    }.map { "\($0.contentHash.prefix(8)):\($0.state.rawValue)" }.joined(separator: ",")
                ]
            )
            // #endregion
            return
        }

        // #region agent log
        DebugSessionLogger.log(
            hypothesisId: "D",
            location: "SessionManager.checkCompletion",
            message: "session_complete",
            data: ["deviceId": identity.deviceId]
        )
        // #endregion
        // 本机收发完成，但保持网络，等待全员完成后再统一退出
        sessionState.phase = .awaitingGroupSync
        announceLocalComplete()
    }

    private func announceLocalComplete() {
        guard !groupBarrier.hasAnnouncedLocalComplete else { return }
        let action = groupBarrier.markLocalComplete(
            deviceId: identity.deviceId,
            isCoordinator: isCoordinator,
            memberIds: currentMemberIds()
        )

        // #region agent log
        DebugSessionLogger.log(
            hypothesisId: "D",
            location: "SessionManager.announceLocalComplete",
            message: "local_complete_announced",
            data: [
                "deviceId": identity.deviceId,
                "completedCount": groupBarrier.completedMemberCount,
                "memberCount": sessionState.members.count,
                "isCoordinator": isCoordinator
            ],
            runId: "post-fix"
        )
        // #endregion

        let payload = SessionCompletePayload(deviceId: identity.deviceId)
        guard let envelope = try? ProtocolEnvelope(
            messageType: .sessionComplete,
            deviceId: identity.deviceId,
            sessionId: sessionState.sessionId,
            payload: payload
        ) else {
            if action == .settleGroup {
                beginGroupSettle()
            }
            return
        }

        if isCoordinator {
            controlChannel.broadcast(envelope, excluding: identity.deviceId)
            if action == .settleGroup {
                beginGroupSettle()
            }
        } else if let coordinatorId = sessionState.coordinatorDeviceId {
            try? controlChannel.send(envelope, to: coordinatorId)
        }
    }

    private func handleSessionComplete(_ envelope: ProtocolEnvelope) {
        let deviceId: String
        if let payload = try? envelope.decodePayload(SessionCompletePayload.self) {
            deviceId = payload.deviceId
        } else {
            deviceId = envelope.deviceId
        }
        let action = groupBarrier.markPeerComplete(
            deviceId: deviceId,
            isCoordinator: isCoordinator,
            memberIds: currentMemberIds()
        )

        // #region agent log
        DebugSessionLogger.log(
            hypothesisId: "D",
            location: "SessionManager.handleSessionComplete",
            message: "peer_local_complete",
            data: [
                "deviceId": deviceId,
                "completedCount": groupBarrier.completedMemberCount,
                "memberCount": sessionState.members.count,
                "isCoordinator": isCoordinator
            ],
            runId: "post-fix"
        )
        // #endregion

        if isCoordinator {
            if let relay = try? ProtocolEnvelope(
                messageType: .sessionComplete,
                deviceId: identity.deviceId,
                sessionId: sessionState.sessionId,
                payload: SessionCompletePayload(deviceId: deviceId)
            ) {
                controlChannel.broadcast(relay, excluding: envelope.deviceId)
            }
            if action == .settleGroup {
                beginGroupSettle()
            }
        }
    }

    private func beginGroupSettle() {
        guard groupBarrier.hasSettledGroup else { return }
        sessionState.phase = .completed

        // #region agent log
        DebugSessionLogger.log(
            hypothesisId: "D",
            location: "SessionManager.tryFinishGroupIfReady",
            message: "group_complete",
            data: [
                "memberCount": sessionState.members.count,
                "completed": groupBarrier.completedMemberIds.sorted().map { String($0.prefix(8)) }.joined(separator: ",")
            ],
            runId: "post-fix"
        )
        // #endregion

        // 先广播全员同步信号，稍后再停网，避免对端还没收到就断控制面
        broadcastSessionPhase(.completed)
        groupSettleTask?.cancel()
        groupSettleTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            settleGroupTransfer()
        }
    }

    private func currentMemberIds() -> Set<String> {
        Set(sessionState.members.map(\.deviceId))
    }

    private func settleGroupTransfer() {
        guard isSharing else { return }
        sessionState.phase = .completed
        groupBarrier.applyRemoteGroupComplete()
        // #region agent log
        DebugSessionLogger.log(
            hypothesisId: "D",
            location: "SessionManager.settleGroupTransfer",
            message: "group_settled_stop_network",
            data: ["deviceId": identity.deviceId, "isCoordinator": isCoordinator],
            runId: "post-fix"
        )
        // #endregion
        stopNetworkKeepResults()
    }

    // MARK: - Helpers

    private func regenerateSecurityCode() {
        mutateSessionState { state in
            for index in state.members.indices {
                state.members[index].confirmed = false
            }
        }
        coordinator.resetConfirmations()

        guard sessionState.members.count > 1 else {
            mutateSessionState { state in
                state.securityCode = nil
            }
            syncCoordinatorMembers()
            return
        }

        let latestJoinedAt = sessionState.members.map(\.joinedAt).max() ?? Date().timeIntervalSince1970
        let securityCode = SecurityCodeGenerator.generate(
            memberDeviceIds: sessionState.members.map(\.deviceId),
            sessionId: sessionState.sessionId ?? "",
            latestMemberJoinedAt: latestJoinedAt
        )
        mutateSessionState { state in
            state.securityCode = securityCode
        }
        syncCoordinatorMembers()
    }

    private func mutateSessionState(_ mutation: (inout SharingSessionState) -> Void) {
        var state = sessionState
        mutation(&state)
        sessionState = state
    }

    private func syncConfirmationsFromMembers() {
        for member in sessionState.members {
            coordinator.handleConfirmation(from: member.deviceId, confirmed: member.confirmed)
        }
    }

    private func updateTaskState(_ transferId: String, state: TransferState) {
        guard let index = activeTransferTasks.firstIndex(where: { $0.transferId == transferId }) else { return }
        activeTransferTasks[index].state = state
        coordinator.scheduler.updateTaskState(transferId, state: state)
    }

    private enum TransferTaskRole {
        case source
        case destination
    }

    private func isTaskFinished(_ task: TransferTask, role: TransferTaskRole) -> Bool {
        if task.state == .completed || task.state == .verified {
            return true
        }
        guard task.state == .failed else { return false }
        return activeTransferTasks.contains { other in
            other.transferId != task.transferId &&
            other.contentHash == task.contentHash &&
            other.destinationDeviceId == task.destinationDeviceId &&
            other.state != .failed
        }
    }

    private func refreshLocalMemberEndpoints() {
        mutateSessionState { state in
            guard let index = state.members.firstIndex(where: { $0.deviceId == identity.deviceId }) else {
                return
            }
            state.members[index].transferPort = transferChannel.port
            state.members[index].controlPort = controlChannel.controlPort
            state.members[index].networkEndpoint = localHostAddress()
        }
    }

    private func announceEndpointsToCoordinator() {
        refreshLocalMemberEndpoints()
        guard let coordinatorId = sessionState.coordinatorDeviceId,
              coordinatorId != identity.deviceId else { return }

        let device = DeviceInfoPayload(
            deviceId: identity.deviceId,
            userName: identity.userName,
            avatarId: identity.avatarId,
            sessionId: sessionState.sessionId ?? "",
            joinCode: sessionState.joinCode ?? "",
            networkEndpoint: localHostAddress(),
            capabilities: ["photo_share", "relay"],
            controlPort: controlChannel.controlPort,
            transferPort: transferChannel.port
        )

        guard let envelope = try? ProtocolEnvelope(
            messageType: .joinRequest,
            deviceId: identity.deviceId,
            sessionId: sessionState.sessionId,
            payload: JoinRequestPayload(device: device)
        ) else { return }

        try? controlChannel.send(envelope, to: coordinatorId)
    }

    private func syncCoordinatorMembers() {
        coordinator.setMembers(sessionState.members)
    }

    private func applyMemberList(_ incoming: [SharingMember]) {
        let incomingIds = incoming.map(\.deviceId)
        let currentIds = sessionState.members.map(\.deviceId)
        mutateSessionState { state in
            guard incomingIds != currentIds else {
                for member in incoming {
                    if let index = state.members.firstIndex(where: { $0.deviceId == member.deviceId }) {
                        var updated = member
                        if updated.joinedAt <= 0 {
                            updated.joinedAt = state.members[index].joinedAt
                        }
                        // 确认只升不降
                        if state.members[index].confirmed {
                            updated.confirmed = true
                        }
                        state.members[index] = updated
                    }
                }
                return
            }

            let existingConfirmed = Dictionary(
                uniqueKeysWithValues: state.members.map { ($0.deviceId, $0.confirmed) }
            )
            let existingJoinedAt = Dictionary(
                uniqueKeysWithValues: state.members.map { ($0.deviceId, $0.joinedAt) }
            )
            state.members = incoming.map { member in
                var updated = member
                if updated.joinedAt <= 0, let existing = existingJoinedAt[member.deviceId] {
                    updated.joinedAt = existing
                }
                // 确认状态只升不降，避免过期 membership 快照把别人的确认打回未确认
                if existingConfirmed[member.deviceId] == true {
                    updated.confirmed = true
                }
                return updated
            }
            // 去掉 Bonjour 占位 id，避免同一人出现两条导致 SwiftUI ForEach 异常
            let snapshot = state.members
            state.members.removeAll { member in
                member.deviceId.hasPrefix("bonjour-")
                    && snapshot.contains {
                        !$0.deviceId.hasPrefix("bonjour-")
                            && ($0.deviceId.hasPrefix(String(member.deviceId.dropFirst("bonjour-".count)))
                                || member.deviceId.hasSuffix(String($0.deviceId.prefix(8))))
                    }
            }
        }
        ensureLocalMemberPresent()
    }

    private func removeMember(deviceId: String) {
        guard deviceId != identity.deviceId else { return }
        guard sessionState.members.contains(where: { $0.deviceId == deviceId }) else { return }

        sessionState.members.removeAll { $0.deviceId == deviceId }
        nearbyDevices.removeAll { $0.deviceId == deviceId }
        peerEndpoints.removeValue(forKey: deviceId)
        controlChannel.disconnect(deviceId: deviceId)
        manifestReceived.remove(deviceId)
        syncCoordinatorMembers()

        if deviceId == sessionState.coordinatorDeviceId {
            hasJoinedRemoteSession = false
        }

        guard sessionState.phase != .transferring,
              sessionState.phase != .awaitingGroupSync,
              sessionState.phase != .completed else { return }

        if sessionState.members.count <= 1 {
            hasJoinedRemoteSession = false
            becomeCoordinator()
            sessionState.phase = .discovering
        } else if sessionState.phase == .syncingMetadata {
            sessionState.phase = .waitingConfirmation
            manifestReceived.removeAll()
        } else {
            sessionState.phase = .waitingConfirmation
        }
        regenerateSecurityCode()
        print("[Session] member left: \(deviceId.prefix(8))")
    }

    private func notifyGroupLeave() {
        guard let envelope = try? ProtocolEnvelope(
            messageType: .joinLeave,
            deviceId: identity.deviceId,
            sessionId: sessionState.sessionId,
            payload: JoinLeavePayload(deviceId: identity.deviceId, reason: "user_cancelled")
        ) else { return }

        controlChannel.broadcast(envelope)
        print("[Session] notified group leave")
    }

    private var localMemberConfirmed: Bool {
        sessionState.members.first { $0.deviceId == identity.deviceId }?.confirmed == true
    }

    private func updateMemberConfirmation(deviceId: String, confirmed: Bool) {
        coordinator.handleConfirmation(from: deviceId, confirmed: confirmed)
        mutateSessionState { state in
            if let index = state.members.firstIndex(where: { $0.deviceId == deviceId }) {
                state.members[index].confirmed = confirmed
            }
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

    private func broadcastSessionPhase(_ phase: SharingPhase) {
        let phaseName: String
        switch phase {
        case .syncingMetadata:
            phaseName = "syncing_metadata"
        case .completed:
            phaseName = "group_complete"
        default:
            return
        }

        let payload = SessionPhasePayload(phase: phaseName)
        if let envelope = try? ProtocolEnvelope(
            messageType: .sessionPhase,
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

    private func stopNetworkKeepResults() {
        groupSettleTask?.cancel()
        groupSettleTask = nil
        discovery.stop()
        controlChannel.stop()
        transferChannel.stop()
        coordinator.reset()
        manifestReceived.removeAll()
        activeTransferTasks.removeAll()
        hasExecutedTransferPlan = false
        // 保留 isSharing / 加入码 / 选图 / 结果，等用户点左上角返回后再由 cancelSharing 清空
        isTransferNetworkActive = false
        nearbyDevices.removeAll()
        peerEndpoints.removeAll()
        hasJoinedRemoteSession = false
        isLeaving = false
    }

    private func cleanupSession(clearPhotos: Bool) {
        groupSettleTask?.cancel()
        groupSettleTask = nil
        discovery.stop()
        controlChannel.stop()
        transferChannel.stop()
        coordinator.reset()
        manifestReceived.removeAll()
        activeTransferTasks.removeAll()
        hasExecutedTransferPlan = false
        groupBarrier.reset()
        nearbyDevices.removeAll()
        peerEndpoints.removeAll()
        photoIsLiveByHash.removeAll()
        photoFileHashByContentHash.removeAll()
        pairedVideoStore.removeAll()
        stillFilenameByHash.removeAll()
        pairedVideoFilenameByHash.removeAll()
        hasJoinedRemoteSession = false
        isLeaving = false
        isCoordinator = false
        isSharing = false
        isTransferNetworkActive = false
        sessionState.phase = .idle
        sessionState.members.removeAll()
        sessionState.securityCode = nil
        sessionState.coordinatorDeviceId = nil
        // 先置 phase idle，再通知 Home 收起，避免结算停网误触发回主页
        shouldPopSharingUI = true

        if clearPhotos {
            selectedPhotos.removeAll()
            sessionState.localPhotos.removeAll()
            sessionState.receivedPhotos.removeAll()
            sessionState.photosReceived = 0
            sessionState.photosToReceive = 0
            sessionState.joinCode = nil
            sessionState.sessionId = nil
            joinCodeInput = ""
            photoStore.removeAll()
        }
    }

    private func localHostAddress() -> String {
        NetworkUtility.localWiFiAddress()
    }

    private func importReceivedPhotoToLibrary(
        stillURL: URL,
        stillFilename: String?,
        pairedVideoURL: URL?,
        pairedVideoFilename: String?,
        isLivePhoto: Bool,
        contentHash: String
    ) {
        Task {
            do {
                let assetId = try await PhotoLibraryImporter.importReceivedPhoto(
                    from: stillURL,
                    stillFilename: stillFilename,
                    pairedVideoURL: pairedVideoURL,
                    pairedVideoFilename: pairedVideoFilename,
                    isLivePhoto: isLivePhoto
                )
                if let index = sessionState.receivedPhotos.firstIndex(where: { $0.contentHash == contentHash }) {
                    sessionState.receivedPhotos[index].libraryAssetIdentifier = assetId
                }
            } catch {
                print("[Session] Photo import failed for \(stillURL.lastPathComponent): \(error)")
            }
        }
    }

    func stillFileURL(forContentHash contentHash: String) -> URL? {
        photoStore[contentHash]
    }

    func pairedVideoFileURL(forContentHash contentHash: String) -> URL? {
        pairedVideoStore[contentHash]
    }

    private func selectTransferHost(advertisedHost: String, resolvedHost: String?) -> (host: String, source: String) {
        if let resolvedHost, NetworkUtility.isUsableTransferHost(resolvedHost) {
            return (resolvedHost, "resolved")
        }
        if NetworkUtility.isUsableTransferHost(advertisedHost) {
            return (advertisedHost, "advertised")
        }
        return (advertisedHost, "advertised_fallback")
    }

    private func generateThumbnail(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let side: CGFloat = 600
        let target = CGSize(width: side, height: side)
        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }

        // 等比裁剪填满方格，避免非方形照片被拉伸
        let scale = max(side / imageSize.width, side / imageSize.height)
        let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(
            x: (side - scaledSize.width) / 2,
            y: (side - scaledSize.height) / 2
        )

        UIGraphicsBeginImageContextWithOptions(target, true, 0)
        image.draw(in: CGRect(origin: origin, size: scaledSize))
        let thumb = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return thumb?.jpegData(compressionQuality: 0.75)
    }

    private func saveTempFile(data: Data, id: String) -> URL {
        let ext = PhotoFingerprint.fileDescriptor(for: data)?.fileExtension ?? "jpg"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).\(ext)")
        try? data.write(to: url)
        return url
    }

    private func savePairedVideoTempFile(data: Data, id: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(id).mov")
        try? data.write(to: url)
        return url
    }

    private func recordPhotoMetadata(contentHash: String, fileHash: String, isLivePhoto: Bool) {
        photoFileHashByContentHash[contentHash] = fileHash
        photoIsLiveByHash[contentHash] = isLivePhoto
    }

    /// 真机去重调试：清单入库后打印 contentHash / fileHash / 注册表拥有者
    private func logDedupManifest(
        stage: String,
        fromDeviceId: String,
        photos: [PhotoMetadataPayload]
    ) {
        let photoLines = photos.map { photo in
            "ch=\(photo.contentHash.prefix(12)) fh=\(photo.fileHash.prefix(12)) bytes=\(photo.size) live=\(photo.isLivePhoto) fmt=\(photo.format)"
        }
        let ownerMap = coordinator.registry.debugOwnerMap()
        let ownerSummary = ownerMap
            .sorted { $0.key < $1.key }
            .map { "\($0.key.prefix(12)):[\($0.value.map { String($0.prefix(8)) }.joined(separator: ","))]" }
            .joined(separator: " | ")

        var diffs: [String: String] = [:]
        for member in sessionState.members {
            let required = coordinator.registry.computeDiff(for: member.deviceId).required
                .map { String($0.prefix(12)) }
                .sorted()
                .joined(separator: ",")
            diffs[String(member.deviceId.prefix(8))] = required
        }

        // 找出被 ≥2 台设备拥有的 hash（应跳过互传）
        let sharedHashes = ownerMap.compactMap { key, owners -> String? in
            owners.count >= 2 ? String(key.prefix(12)) : nil
        }.sorted()

        DebugSessionLogger.log(
            hypothesisId: "D",
            location: "SessionManager.logDedupManifest",
            message: stage,
            data: [
                "localDevice": String(identity.deviceId.prefix(8)),
                "fromDevice": String(fromDeviceId.prefix(8)),
                "isCoordinator": isCoordinator,
                "photoCount": photos.count,
                "photos": photoLines.joined(separator: "; "),
                "registryOwners": ownerSummary,
                "sharedHashes": sharedHashes.joined(separator: ","),
                "diffs": diffs.map { "\($0.key)←\($0.value)" }.sorted().joined(separator: "; "),
                "manifestReceived": manifestReceived.map { String($0.prefix(8)) }.sorted().joined(separator: ",")
            ],
            runId: "dedup-debug"
        )

        print("[DEDUP] === \(stage) from=\(fromDeviceId.prefix(8)) photos=\(photos.count) ===")
        for line in photoLines {
            print("[DEDUP]   \(line)")
        }
        print("[DEDUP] shared(≥2 owners)=\(sharedHashes.isEmpty ? "(none)" : sharedHashes.joined(separator: ","))")
        print("[DEDUP] registry=\(ownerSummary)")
        print("[DEDUP] diffs=\(diffs.map { "\($0.key)←[\($0.value)]" }.sorted().joined(separator: " "))")
    }

    /// 真机去重调试：传输计划生成后核对「共享照片是否仍被调度」
    private func logDedupTransferPlan(tasks: [TransferTask]) {
        let ownerMap = coordinator.registry.debugOwnerMap()
        let sharedHashes = Set(ownerMap.filter { $0.value.count >= 2 }.map(\.key))
        let illegalSharedTransfers = tasks.filter { sharedHashes.contains($0.contentHash) }

        var diffLines: [String] = []
        for member in sessionState.members {
            let diff = coordinator.registry.computeDiff(for: member.deviceId)
            let required = diff.required.map { String($0.prefix(12)) }.sorted().joined(separator: ",")
            let owned = diff.owned.map { String($0.prefix(12)) }.sorted().joined(separator: ",")
            diffLines.append("\(member.deviceId.prefix(8)) owned=[\(owned)] need=[\(required)]")
        }

        let taskLines = tasks.map {
            "\($0.sourceDeviceId.prefix(8))->\($0.destinationDeviceId.prefix(8)):\($0.contentHash.prefix(12))"
        }

        DebugSessionLogger.log(
            hypothesisId: "D",
            location: "SessionManager.logDedupTransferPlan",
            message: "plan_dedup_check",
            data: [
                "taskCount": tasks.count,
                "sharedHashCount": sharedHashes.count,
                "illegalSharedTransferCount": illegalSharedTransfers.count,
                "illegalSharedTransfers": illegalSharedTransfers.map {
                    "\($0.sourceDeviceId.prefix(8))->\($0.destinationDeviceId.prefix(8)):\($0.contentHash.prefix(12))"
                }.joined(separator: ","),
                "tasks": taskLines.joined(separator: ","),
                "diffs": diffLines.joined(separator: " || ")
            ],
            runId: "dedup-debug"
        )

        print("[DEDUP] === transfer_plan tasks=\(tasks.count) ===")
        for line in diffLines {
            print("[DEDUP]   \(line)")
        }
        for line in taskLines {
            print("[DEDUP]   task \(line)")
        }
        if illegalSharedTransfers.isEmpty {
            print("[DEDUP] OK: 多拥有者照片未进入传输计划")
        } else {
            print("[DEDUP] BUG: 下列共享照片仍被调度（contentHash 未对齐或注册表未合并）:")
            for task in illegalSharedTransfers {
                print("[DEDUP]   ILLEGAL \(task.sourceDeviceId.prefix(8))->\(task.destinationDeviceId.prefix(8)) ch=\(task.contentHash.prefix(12))")
            }
        }
    }

    private struct ReceivedPhotoVerification {
        let accepted: Bool
        let usedFileHashFallback: Bool
        let computedContentHash: String
        let computedFileHash: String
    }

    private func verifyReceivedPhoto(data: Data, contentHash: String) throws -> ReceivedPhotoVerification {
        let fingerprint = try PhotoFingerprint.compute(from: data)
        if fingerprint.contentHash == contentHash {
            recordPhotoMetadata(contentHash: contentHash, fileHash: fingerprint.fileHash, isLivePhoto: photoIsLiveByHash[contentHash] ?? false)
            return ReceivedPhotoVerification(
                accepted: true,
                usedFileHashFallback: false,
                computedContentHash: fingerprint.contentHash,
                computedFileHash: fingerprint.fileHash
            )
        }

        if let expectedFileHash = photoFileHashByContentHash[contentHash],
           fingerprint.fileHash == expectedFileHash {
            recordPhotoMetadata(contentHash: contentHash, fileHash: fingerprint.fileHash, isLivePhoto: photoIsLiveByHash[contentHash] ?? false)
            return ReceivedPhotoVerification(
                accepted: true,
                usedFileHashFallback: true,
                computedContentHash: fingerprint.contentHash,
                computedFileHash: fingerprint.fileHash
            )
        }

        return ReceivedPhotoVerification(
            accepted: false,
            usedFileHashFallback: false,
            computedContentHash: fingerprint.contentHash,
            computedFileHash: fingerprint.fileHash
        )
    }

    func updateIdentity(name: String, avatarId: Int) {
        identity.userName = name
        identity.avatarId = avatarId
        identity.save()
    }
}
