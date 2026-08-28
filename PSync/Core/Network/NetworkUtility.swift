import Darwin
import Foundation

struct NetworkInterfaceInfo: Sendable {
    let name: String
    let address: String
    let netmask: String
    let broadcastAddress: String
}

enum NetworkUtility {
    /// 获取首选 Wi-Fi 网络接口（优先 RFC1918 私有地址）
    static func primaryInterface() -> NetworkInterfaceInfo? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var candidates: [NetworkInterfaceInfo] = []

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard let addrPointer = interface.ifa_addr,
                  addrPointer.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            guard isCandidateInterface(name) else { continue }

            guard let address = ipv4String(from: addrPointer) else { continue }
            guard address != "127.0.0.1" else { continue }

            let netmask: String
            if let maskPointer = interface.ifa_netmask,
               let parsed = ipv4String(from: maskPointer) {
                netmask = parsed
            } else {
                netmask = "255.255.255.0"
            }

            let broadcast = computeBroadcast(ip: address, netmask: netmask)
            candidates.append(NetworkInterfaceInfo(
                name: name,
                address: address,
                netmask: netmask,
                broadcastAddress: broadcast
            ))
        }

        if let en0Private = candidates.first(where: { $0.name == "en0" && isPrivateIPv4($0.address) }) {
            return en0Private
        }
        if let en0 = candidates.first(where: { $0.name == "en0" }) {
            return en0
        }
        if let privateIf = candidates.first(where: { isPrivateIPv4($0.address) }) {
            return privateIf
        }
        return candidates.first
    }

    /// 获取本机 Wi-Fi IPv4 地址
    static func localWiFiAddress() -> String {
        primaryInterface()?.address ?? "127.0.0.1"
    }

    /// 是否为本机回环地址（不能用于跨设备传输）
    static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "127.0.0.1"
            || normalized == "::1"
            || normalized == "localhost"
            || normalized.hasPrefix("127.")
    }

    /// 是否可作为 P2P 传输目标地址
    static func isUsableTransferHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized == "bonjour" { return false }
        if isLoopbackHost(normalized) { return false }
        return true
    }

    private static func isCandidateInterface(_ name: String) -> Bool {
        if name == "en0" { return true }
        if name.hasPrefix("utun") || name.hasPrefix("lo") || name.hasPrefix("pdp_ip") { return false }
        return name.hasPrefix("en")
    }

    private static func isPrivateIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch parts[0] {
        case 10:
            return true
        case 172:
            return (16...31).contains(parts[1])
        case 192:
            return parts[1] == 168
        default:
            return false
        }
    }

    private static func ipv4String(from addr: UnsafePointer<sockaddr>) -> String? {
        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            addr,
            socklen_t(addr.pointee.sa_len),
            &hostname,
            socklen_t(hostname.count),
            nil,
            0,
            NI_NUMERICHOST
        )
        guard result == 0 else { return nil }
        return String(cString: hostname)
    }

    private static func computeBroadcast(ip: String, netmask: String) -> String {
        let ipParts = ip.split(separator: ".").compactMap { Int($0) }
        let maskParts = netmask.split(separator: ".").compactMap { Int($0) }
        guard ipParts.count == 4, maskParts.count == 4 else { return "255.255.255.255" }
        return (0..<4)
            .map { String(ipParts[$0] | (~maskParts[$0] & 0xFF)) }
            .joined(separator: ".")
    }
}
