import Foundation

/// 全局 Photo Metadata 注册表与差分计算
final class GlobalPhotoRegistry: @unchecked Sendable {
    private var entries: [String: GlobalPhotoEntry] = [:]
    private let lock = NSLock()

    func reset() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }

    func ingestManifest(from deviceId: String, photos: [PhotoMetadataPayload]) {
        lock.lock()
        defer { lock.unlock() }

        for photo in photos {
            if var entry = entries[photo.contentHash] {
                entry.owners.insert(deviceId)
                entry.availableSources.insert(deviceId)
                entries[photo.contentHash] = entry
            } else {
                entries[photo.contentHash] = GlobalPhotoEntry(
                    contentHash: photo.contentHash,
                    owners: [deviceId],
                    size: photo.size,
                    transferStatus: .pending,
                    requiredBy: [],
                    availableSources: [deviceId]
                )
            }
        }
    }

    func computeDiff(for deviceId: String) -> (required: [String], owned: [String]) {
        lock.lock()
        defer { lock.unlock() }

        var owned: [String] = []
        var required: [String] = []

        for (hash, entry) in entries {
            if entry.owners.contains(deviceId) {
                owned.append(hash)
            } else {
                required.append(hash)
            }
        }

        return (required, owned)
    }

    func availableSources(for contentHash: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries[contentHash]?.availableSources ?? [])
    }

    func allEntries() -> [GlobalPhotoEntry] {
        lock.lock()
        defer { lock.unlock() }
        return Array(entries.values)
    }

    /// 真机调试：contentHash → 拥有者列表
    func debugOwnerMap() -> [String: [String]] {
        lock.lock()
        defer { lock.unlock() }
        var map: [String: [String]] = [:]
        for (hash, entry) in entries {
            map[hash] = entry.owners.sorted()
        }
        return map
    }

    func markCompleted(contentHash: String, for deviceId: String) {
        lock.lock()
        defer { lock.unlock() }
        if var entry = entries[contentHash] {
            entry.owners.insert(deviceId)
            entry.availableSources.insert(deviceId)
            entry.transferStatus = .completed
            entries[contentHash] = entry
        }
    }

    func updateTransferStatus(_ contentHash: String, status: TransferState) {
        lock.lock()
        defer { lock.unlock() }
        if var entry = entries[contentHash] {
            entry.transferStatus = status
            entries[contentHash] = entry
        }
    }
}

/// 差分计算器
enum DiffCalculator {
    static func photosToReceive(
        globalHashes: Set<String>,
        ownedHashes: Set<String>
    ) -> Set<String> {
        globalHashes.subtracting(ownedHashes)
    }

    static func availableSources(
        contentHash: String,
        registry: GlobalPhotoRegistry,
        excluding deviceId: String
    ) -> [String] {
        registry.availableSources(for: contentHash).filter { $0 != deviceId }
    }
}
