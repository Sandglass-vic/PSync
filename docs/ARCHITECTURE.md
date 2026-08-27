# PSync 系统架构文档

## 1. 系统架构图

```text
                    ┌──────────────────────┐
                    │   Application Layer  │
                    │  SwiftUI UI Views    │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │   Sharing Session    │
                    │   SessionManager     │
                    └──────────┬───────────┘
                               │
              ┌────────────────▼────────────────┐
              │       Control / Metadata        │
              │ CoordinatorService / Scheduler  │
              │ GlobalPhotoRegistry / Protocol  │
              └────────────────┬────────────────┘
                               │
                    ┌──────────▼───────────┐
                    │  Transport Layer    │
                    │ ControlChannel(TCP) │
                    │ TransferChannel(TCP)│
                    │ DiscoveryService(UDP)│
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │   Local Network      │
                    │ Wi-Fi / Hotspot      │
                    └──────────────────────┘
```

## 2. 跨平台网络架构

| 层级 | iOS 实现 | Android 未来实现 |
|------|---------|-----------------|
| Discovery | Network.framework UDP | DatagramSocket |
| Control | TCP + JSON | TCP + JSON (相同协议) |
| Transfer | TCP chunked | TCP chunked (相同协议) |
| Photo Hash | CoreGraphics + CryptoKit | Bitmap + MessageDigest |

核心协议与消息格式完全平台无关，使用 JSON + 标准 Hash。

## 3. Discovery Protocol

- **广播**: UDP 255.255.255.255:9876，周期 500ms
- **组播 Fallback**: 239.255.77.88:9877
- **Payload**: JSON DiscoveryAdvertisement (protocol_version, device_id, join_code, control_port...)
- **去重**: DeviceDeduplicator，TTL 2 秒
- **3 秒目标**: 500ms 广播周期 × 最多 6 次 = 3 秒内 P95 发现

## 4. Session / Coordinator

- 创建 Session 的设备担任 Coordinator
- Coordinator 维护 GlobalPhotoRegistry + TransferScheduler
- Failover: Coordinator 离线时，deviceId 字典序最小的成员接任

## 5. Photo Content Fingerprint

- 缩放到 16×16 灰度图
- SHA-256(pixel bytes) = contentHash
- SHA-256(file bytes) = fileHash（传输验证用）
- 像素一致 → contentHash 相同，文件格式/压缩不同也能去重

## 6. 差分计算

```
PhotosToReceive(A) = GlobalPhotos - PhotosOwnedBy(A)
AvailableSources(H) = {devices that own H}
```

## 7. Transfer DAG

- TransferGraph 维护任务依赖
- 添加任务前检测循环依赖
- 支持 Relay: A→B→C，B 收到后作为 C 的源

## 8. Transfer Scheduler

- 动态选择最优 Source（带宽估计 - 负载惩罚）
- 最大并发: 3 upload + 3 download per device
- Failed task 自动 reschedule 到其他 Source

## 9. Application Protocol

完整消息类型见 `ProtocolConstants.swift` 和 `ProtocolMessage.swift`。

传输选择:
- **UDP**: Discovery（轻量、广播）
- **TCP**: Control + Photo Transfer（可靠、跨平台一致）
- **QUIC**: 未来优化方向（当前使用 TCP 保证兼容性）

## 10. 性能测试指标

| 指标 | 目标 | 测试方法 |
|------|------|---------|
| Discovery P95 | ≤ 3s | DeviceDeduplicatorTests + 实机日志 |
| Join Session | ≤ 1s | TCP 直连 + join_accept |
| 去重 | 本地完成 | PhotoFingerprintTests |
| DAG 无环 | 100% | TransferSchedulerTests |

## 11. 项目结构

```
PSync/
├── App/PSyncApp.swift
├── UI/ (HomeView, SharingView, ResultsView, SettingsView)
├── Core/
│   ├── Protocol/
│   ├── Models/
│   ├── Discovery/
│   ├── Network/
│   ├── Coordinator/
│   ├── Photo/
│   └── Session/
PSyncTests/
docs/ARCHITECTURE.md
```
