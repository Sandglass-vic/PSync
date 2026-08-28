import Foundation
import Network

/// Bonjour + AWDL 设备发现（Network.framework，与 Psync-old 一致）
final class BonjourDiscoveryService: @unchecked Sendable {
    typealias DiscoveryHandler = (DiscoveryAdvertisementPayload, NWEndpoint) -> Void

    private let queue = DispatchQueue(label: "com.psync.bonjour.discovery", qos: .userInitiated)
    private var browser: NWBrowser?
    private var joinCode: String?
    private var localDeviceId: String?
    private var onDiscovered: DiscoveryHandler?
    private let deduplicator = DeviceDeduplicator()

    func startBrowsing(
        joinCode: String,
        localDeviceId: String,
        onDiscovered: @escaping DiscoveryHandler
    ) {
        stop()
        self.joinCode = joinCode
        self.localDeviceId = localDeviceId
        self.onDiscovered = onDiscovered

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        parameters.allowLocalEndpointReuse = true

        // `.bonjour` 不会带上 TXT；必须用 `.bonjourWithTXTRecord` 才能读到加入码等字段
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: ProtocolConstants.bonjourServiceType, domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[Bonjour] browser ready")
            case .failed(let error):
                print("[Bonjour] browser failed: \(error)")
            case .waiting(let error):
                print("[Bonjour] browser waiting: \(error)")
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, changes in
            print("[Bonjour] results=\(results.count) changes=\(changes.count)")
            self?.handleResults(results)
        }
        browser.start(queue: queue)
        self.browser = browser
        print("[Bonjour] browsing for join code \(joinCode)")
    }

    func stop() {
        browser?.cancel()
        browser = nil
        joinCode = nil
        localDeviceId = nil
        onDiscovered = nil
        deduplicator.reset()
    }

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        guard let joinCode, let localDeviceId, let onDiscovered else { return }

        for result in results {
            guard case .service(let name, let type, let domain, _) = result.endpoint else {
                print("[Bonjour] skip non-service endpoint: \(result.endpoint)")
                continue
            }
            print("[Bonjour] seen service name=\(name) type=\(type) domain=\(domain) meta=\(metadataDescription(result.metadata))")

            guard let peer = parsePeer(
                name: name,
                metadata: result.metadata,
                expectedJoinCode: joinCode,
                localDeviceId: localDeviceId
            ) else { continue }

            guard deduplicator.shouldProcess(deviceId: peer.deviceId, sessionId: peer.sessionId) else { continue }

            let advertisement = DiscoveryAdvertisementPayload(
                protocolVersion: ProtocolConstants.protocolVersion,
                deviceId: peer.deviceId,
                displayName: peer.displayName,
                avatarId: peer.avatarId,
                sessionId: peer.sessionId,
                joinCode: joinCode,
                networkEndpoint: "bonjour",
                capabilities: ["photo_share", "relay"],
                controlPort: 0
            )

            print("[Bonjour] found peer \(peer.deviceId.prefix(8)) name=\(peer.displayName)")
            onDiscovered(advertisement, result.endpoint)
        }
    }

    private struct PeerInfo {
        let deviceId: String
        let sessionId: String
        let displayName: String
        let avatarId: Int
    }

    private func parsePeer(
        name: String,
        metadata: NWBrowser.Result.Metadata,
        expectedJoinCode: String,
        localDeviceId: String
    ) -> PeerInfo? {
        // 优先 TXT；没有 TXT 时从服务名解析（PSync-{code}-{devicePrefix}）
        if case .bonjour(let txt) = metadata {
            let dict = txt.dictionary
            let code = dict["code"] ?? BonjourAdvertisement.joinCode(fromServiceName: name)
            guard code == expectedJoinCode else {
                print("[Bonjour] code mismatch txt=\(dict["code"] ?? "-") name=\(name)")
                return nil
            }
            let deviceId = dict["did"] ?? BonjourAdvertisement.deviceIdHint(fromServiceName: name) ?? ""
            guard !deviceId.isEmpty else {
                print("[Bonjour] missing device id for \(name)")
                return nil
            }
            // 服务名里只有 8 位前缀时，用前缀排除自己
            if deviceId == localDeviceId || localDeviceId.hasPrefix(deviceId) || deviceId.hasPrefix(String(localDeviceId.prefix(8))) {
                return nil
            }
            return PeerInfo(
                deviceId: deviceId,
                sessionId: dict["sid"] ?? "",
                displayName: dict["name"] ?? "用户",
                avatarId: Int(dict["av"] ?? "0") ?? 0
            )
        }

        guard let parsed = BonjourAdvertisement.parseServiceName(name),
              parsed.joinCode == expectedJoinCode else {
            print("[Bonjour] no TXT and cannot parse service name=\(name)")
            return nil
        }
        if localDeviceId.hasPrefix(parsed.devicePrefix) || parsed.devicePrefix == String(localDeviceId.prefix(8)) {
            return nil
        }
        // 无完整 deviceId 时用前缀占位；后续 join 握手会交换完整身份
        let placeholderId = "bonjour-\(parsed.devicePrefix)"
        return PeerInfo(
            deviceId: placeholderId,
            sessionId: "",
            displayName: "用户",
            avatarId: 0
        )
    }

    private func metadataDescription(_ metadata: NWBrowser.Result.Metadata) -> String {
        switch metadata {
        case .bonjour(let txt):
            return "txt\(txt.dictionary)"
        case .none:
            return "none"
        @unknown default:
            return "unknown"
        }
    }
}

enum BonjourAdvertisement {
    /// 服务名带上加入码，即使 TXT 不可用也能匹配：PSync-1111-DDE088E3
    static func serviceName(deviceId: String, joinCode: String) -> String {
        "PSync-\(joinCode)-\(deviceId.prefix(8))"
    }

    static func joinCode(fromServiceName name: String) -> String? {
        parseServiceName(name)?.joinCode
    }

    static func deviceIdHint(fromServiceName name: String) -> String? {
        parseServiceName(name)?.devicePrefix
    }

    static func parseServiceName(_ name: String) -> (joinCode: String, devicePrefix: String)? {
        let parts = name.split(separator: "-")
        // PSync-{code}-{prefix}
        guard parts.count >= 3, parts[0] == "PSync" else { return nil }
        let code = String(parts[1])
        guard code.count == 4, code.allSatisfy(\.isNumber) else { return nil }
        return (code, String(parts[2]))
    }

    static func txtRecord(
        deviceId: String,
        joinCode: String,
        sessionId: String,
        displayName: String,
        avatarId: Int
    ) -> NWTXTRecord {
        var txt = NWTXTRecord()
        txt["v"] = "1"
        txt["code"] = joinCode
        txt["did"] = deviceId
        txt["sid"] = sessionId
        txt["name"] = String(displayName.prefix(32))
        txt["av"] = String(avatarId)
        return txt
    }
}
