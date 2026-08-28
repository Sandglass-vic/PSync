import CoreBluetooth
import Foundation

/// BLE 广播包编解码（紧凑格式，适合低功耗快速发现）
///
/// iOS `CBPeripheralManager` 仅允许 Local Name / Service UUID 等字段，
/// 不允许 Service Data，因此 payload 编码在 Local Name 中（≤31 字节 AD 限制）。
enum BLEAdvertisementCodec {
    static let serviceUUID = CBUUID(string: "7A4B")
    private static let namePrefix = "PS"

    struct Payload: Equatable {
        let joinCode: String
        let deviceFingerprint: Data
        let sessionFingerprint: Data
        let avatarId: Int
    }

    /// Local Name 格式: PS + joinCode(4) + deviceShort(4 hex) + sessionShort(4 hex) + avatar(1)
    static func encodeLocalName(joinCode: String, deviceId: String, sessionId: String, avatarId: Int) -> String {
        let deviceShort = hexPrefix(deviceFingerprint(deviceId), byteCount: 2)
        let sessionShort = hexPrefix(sessionFingerprint(sessionId), byteCount: 2)
        return "\(namePrefix)\(joinCode)\(deviceShort)\(sessionShort)\(avatarId)"
    }

    static func decodeLocalName(_ name: String) -> Payload? {
        guard name.hasPrefix(namePrefix), name.count >= 15 else { return nil }
        let body = String(name.dropFirst(namePrefix.count))
        let joinCode = String(body.prefix(4))
        guard joinCode.count == 4, joinCode.allSatisfy(\.isNumber) else { return nil }
        let deviceShort = String(body.dropFirst(4).prefix(4))
        let sessionShort = String(body.dropFirst(8).prefix(4))
        guard let avatarId = Int(String(body.dropFirst(12).prefix(1))) else { return nil }
        guard let deviceBytes = data(fromHex: deviceShort), let sessionBytes = data(fromHex: sessionShort) else {
            return nil
        }
        var deviceFP = Data(repeating: 0, count: 8)
        deviceFP.replaceSubrange(0..<deviceBytes.count, with: deviceBytes)
        var sessionFP = Data(repeating: 0, count: 4)
        sessionFP.replaceSubrange(0..<sessionBytes.count, with: sessionBytes)
        return Payload(
            joinCode: joinCode,
            deviceFingerprint: deviceFP,
            sessionFingerprint: sessionFP,
            avatarId: avatarId
        )
    }

    static func matchesLocalDevice(_ payload: Payload, deviceId: String) -> Bool {
        payload.deviceFingerprint.prefix(2) == deviceFingerprint(deviceId).prefix(2)
    }

    static func deviceFingerprint(_ deviceId: String) -> Data {
        var hash: UInt64 = 5381
        for byte in deviceId.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return withUnsafeBytes(of: hash.bigEndian) { Data($0) }
    }

    static func sessionFingerprint(_ sessionId: String) -> Data {
        var hash: UInt32 = 2166136261
        for byte in sessionId.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16777619
        }
        return withUnsafeBytes(of: hash.bigEndian) { Data($0) }
    }

    private static func hexPrefix(_ data: Data, byteCount: Int) -> String {
        data.prefix(byteCount).map { String(format: "%02X", $0) }.joined()
    }

    private static func data(fromHex hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }
}
