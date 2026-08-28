import Foundation

/// DAG-based Transfer Graph - 保证无循环依赖
final class TransferGraph: @unchecked Sendable {
    private var tasks: [String: TransferTask] = [:]
    private var adjacency: [String: Set<String>] = [:] // transferId -> dependent transferIds
    private let lock = NSLock()

    func addTask(_ task: TransferTask) throws {
        lock.lock()
        defer { lock.unlock() }

        if wouldCreateCycle(task: task) {
            throw TransferSchedulerError.cycleDetected
        }

        tasks[task.transferId] = task
        for depId in task.dependencyTransferIds {
            adjacency[depId, default: []].insert(task.transferId)
        }
    }

    func removeTask(_ transferId: String) {
        lock.lock()
        defer { lock.unlock() }
        tasks.removeValue(forKey: transferId)
        adjacency.removeValue(forKey: transferId)
        for key in adjacency.keys {
            adjacency[key]?.remove(transferId)
        }
    }

    func readyTasks(for deviceId: String, role: TaskRole) -> [TransferTask] {
        lock.lock()
        defer { lock.unlock() }

        return tasks.values.filter { task in
            guard task.state == .pending || task.state == .scheduled || task.state == .rescheduled else { return false }
            guard dependenciesMet(task) else { return false }

            switch role {
            case .source:
                return task.sourceDeviceId == deviceId
            case .destination:
                return task.destinationDeviceId == deviceId
            }
        }
    }

    func updateState(_ transferId: String, state: TransferState) {
        lock.lock()
        defer { lock.unlock() }
        tasks[transferId]?.state = state
    }

    func allTasks() -> [TransferTask] {
        lock.lock()
        defer { lock.unlock() }
        return Array(tasks.values)
    }

    func reset() {
        lock.lock()
        tasks.removeAll()
        adjacency.removeAll()
        lock.unlock()
    }

    enum TaskRole {
        case source
        case destination
    }

    private func dependenciesMet(_ task: TransferTask) -> Bool {
        task.dependencyTransferIds.allSatisfy { depId in
            tasks[depId]?.state == .completed || tasks[depId]?.state == .verified
        }
    }

    private func wouldCreateCycle(task: TransferTask) -> Bool {
        var visited = Set<String>()
        var stack = task.dependencyTransferIds

        while let current = stack.popLast() {
            if current == task.transferId { return true }
            if visited.contains(current) { continue }
            visited.insert(current)
            if let existing = tasks[current] {
                stack.append(contentsOf: existing.dependencyTransferIds)
            }
        }
        return false
    }
}

enum TransferSchedulerError: Error {
    case cycleDetected
    case noAvailableSource
}

/// 中心化 Transfer Scheduler
final class TransferScheduler: @unchecked Sendable {
    private let graph = TransferGraph()
    private let registry: GlobalPhotoRegistry
    private var bandwidthEstimates: [String: Double] = [:] // deviceId -> MB/s
    private var activeUploads: [String: Int] = [:]
    private var activeDownloads: [String: Int] = [:]
    private let lock = NSLock()

    init(registry: GlobalPhotoRegistry) {
        self.registry = registry
    }

    func updateBandwidth(deviceId: String, mbps: Double) {
        lock.lock()
        bandwidthEstimates[deviceId] = mbps
        lock.unlock()
    }

    /// 为所有成员生成传输计划
    func generatePlan(members: [String]) -> [TransferTask] {
        lock.lock()
        defer { lock.unlock() }

        graph.reset()
        var allTasks: [TransferTask] = []
        var scheduledKeys: Set<String> = []

        for memberId in members {
            let (required, _) = registry.computeDiff(for: memberId)
            for contentHash in required {
                let key = "\(memberId):\(contentHash)"
                guard !scheduledKeys.contains(key) else { continue }

                let sources = registry.availableSources(for: contentHash)
                    .filter { $0 != memberId }

                guard let bestSource = selectBestSource(
                    sources: sources,
                    destination: memberId
                ) else { continue }

                let entry = registry.allEntries().first { $0.contentHash == contentHash }
                let task = TransferTask(
                    transferId: UUID().uuidString,
                    contentHash: contentHash,
                    sourceDeviceId: bestSource,
                    destinationDeviceId: memberId,
                    photoSize: entry?.size ?? 0,
                    state: .pending,
                    version: 1,
                    dependencyTransferIds: [],
                    bytesTransferred: 0
                )

                if (try? graph.addTask(task)) != nil {
                    allTasks.append(task)
                    scheduledKeys.insert(key)
                }
            }
        }

        // 添加 relay 任务：如果 A→B 已完成，B 可作为 H1 的中继源
        addRelayTasks(members: members, existingTasks: &allTasks)

        return allTasks
    }

    /// 非协调者收到广播计划后，写入本地调度图，否则 nextTasks 永远为空
    func loadPlan(_ tasks: [TransferTask]) {
        lock.lock()
        defer { lock.unlock() }
        graph.reset()
        for task in tasks {
            try? graph.addTask(task)
        }
    }

    func adoptTask(_ task: TransferTask) {
        lock.lock()
        defer { lock.unlock() }
        try? graph.addTask(task)
    }

    func rescheduleFailedTask(_ task: TransferTask, members: [String]) -> TransferTask? {
        let sources = registry.availableSources(for: task.contentHash)
            .filter { $0 != task.destinationDeviceId && $0 != task.sourceDeviceId }

        guard let newSource = selectBestSource(sources: sources, destination: task.destinationDeviceId) else {
            return nil
        }

        graph.removeTask(task.transferId)
        var newTask = task
        newTask = TransferTask(
            transferId: UUID().uuidString,
            contentHash: task.contentHash,
            sourceDeviceId: newSource,
            destinationDeviceId: task.destinationDeviceId,
            photoSize: task.photoSize,
            state: .rescheduled,
            version: task.version + 1,
            dependencyTransferIds: task.dependencyTransferIds,
            bytesTransferred: 0
        )
        try? graph.addTask(newTask)
        return newTask
    }

    func nextTasks(for deviceId: String, role: TransferGraph.TaskRole, limit: Int) -> [TransferTask] {
        let ready = graph.readyTasks(for: deviceId, role: role)
        return Array(ready.prefix(limit))
    }

    func updateTaskState(_ transferId: String, state: TransferState) {
        graph.updateState(transferId, state: state)
    }

    func markCompleted(_ transferId: String, contentHash: String, deviceId: String) {
        graph.updateState(transferId, state: .completed)
        registry.markCompleted(contentHash: contentHash, for: deviceId)
    }

    func markFailed(_ transferId: String) {
        graph.updateState(transferId, state: .failed)
    }

    func reset() {
        graph.reset()
        lock.lock()
        bandwidthEstimates.removeAll()
        activeUploads.removeAll()
        activeDownloads.removeAll()
        lock.unlock()
    }

    private func selectBestSource(sources: [String], destination: String) -> String? {
        guard !sources.isEmpty else { return nil }

        return sources.max { a, b in
            let scoreA = sourceScore(source: a, destination: destination)
            let scoreB = sourceScore(source: b, destination: destination)
            return scoreA < scoreB
        }
    }

    private func sourceScore(source: String, destination: String) -> Double {
        let bandwidth = bandwidthEstimates[source] ?? 50.0
        let uploadLoad = Double(activeUploads[source] ?? 0)
        let downloadLoad = Double(activeDownloads[destination] ?? 0)
        return bandwidth / (1.0 + uploadLoad + downloadLoad * 0.5)
    }

    private func addRelayTasks(members: [String], existingTasks: inout [TransferTask]) {
        // 当中间节点已拥有照片时，允许 relay: A → B → C
        for memberId in members {
            let (required, _) = registry.computeDiff(for: memberId)
            for contentHash in required {
                if existingTasks.contains(where: {
                    $0.destinationDeviceId == memberId && $0.contentHash == contentHash
                }) {
                    continue
                }

                let directSources = registry.availableSources(for: contentHash)
                let relayCandidates = members.filter { candidate in
                    candidate != memberId &&
                    !directSources.contains(candidate) &&
                    registry.allEntries().contains(where: {
                        $0.contentHash == contentHash && $0.owners.contains(candidate)
                    })
                }

                for relay in relayCandidates {
                    // relay 节点需要先收到照片
                    let prereqTask = existingTasks.first {
                        $0.contentHash == contentHash && $0.destinationDeviceId == relay
                    }
                    if let prereq = prereqTask {
                        let relayTask = TransferTask(
                            transferId: UUID().uuidString,
                            contentHash: contentHash,
                            sourceDeviceId: relay,
                            destinationDeviceId: memberId,
                            photoSize: prereq.photoSize,
                            state: .pending,
                            version: 1,
                            dependencyTransferIds: [prereq.transferId],
                            bytesTransferred: 0
                        )
                        if (try? graph.addTask(relayTask)) != nil {
                            existingTasks.append(relayTask)
                        }
                    }
                }
            }
        }
    }
}
