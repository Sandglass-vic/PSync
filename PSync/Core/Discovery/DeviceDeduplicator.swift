import Foundation

/// 设备发现去重器：同一 device_id 在 TTL 内只处理一次
final class DeviceDeduplicator: @unchecked Sendable {
    private var lastSeen: [String: Date] = [:]
    private let lock = NSLock()
    private let ttl: TimeInterval

    init(ttl: TimeInterval = ProtocolConstants.discoveryDedupeTTL) {
        self.ttl = ttl
    }

    func shouldProcess(deviceId: String, sessionId: String) -> Bool {
        let key = "\(deviceId):\(sessionId)"
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        if let last = lastSeen[key], now.timeIntervalSince(last) < ttl {
            return false
        }
        lastSeen[key] = now
        pruneExpired(before: now)
        return true
    }

    func reset() {
        lock.lock()
        lastSeen.removeAll()
        lock.unlock()
    }

    private func pruneExpired(before now: Date) {
        lastSeen = lastSeen.filter { now.timeIntervalSince($0.value) < ttl * 2 }
    }
}

enum JoinCodeGenerator {
    static func generate() -> String {
        String(format: "%04d", Int.random(in: 0...9999))
    }

    static func isValid(_ code: String) -> Bool {
        code.count == ProtocolConstants.joinCodeLength && code.allSatisfy(\.isNumber)
    }
}

enum SecurityCodeGenerator {
    static func generate(memberDeviceIds: [String], sessionId: String) -> String {
        let sorted = memberDeviceIds.sorted().joined(separator: ":")
        let input = "\(sessionId):\(sorted)"
        let hash = input.utf8.reduce(into: UInt64(0)) { acc, byte in
            acc = acc &* 31 &+ UInt64(byte)
        }
        return String(format: "%06d", hash % 1_000_000)
    }
}
