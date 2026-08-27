可以把这些要求直接提升为 **Prompt 中最核心的“网络架构 + 去重 + 中心调度”设计约束**。尤其建议不要让 AI 自己随意选择 MultipeerConnectivity，因为你明确要求未来 Android 跨平台；应该要求它把**发现层、控制层、数据传输层、调度层解耦**。

下面是整合后的版本：

请帮我从零构建一个 **iOS App**，实现 **2～多人面对面、本地照片互传与共享**。当前最大参与人数为 **8 人**，但架构必须支持未来扩展。

整个系统需要从一开始就考虑 **iOS / Android 跨平台兼容性**。不要使用只能在 Apple 生态内工作的通信协议作为核心网络架构。iOS 当前可以使用原生 API 实现，但**网络协议、消息格式、Session 管理、照片 Meta-data、传输调度等核心逻辑必须与平台解耦**，保证未来可以实现 Android Client，并与 iOS 设备直接互传。

---

# **一、总体架构要求**

系统采用分层设计：

```text
                    ┌──────────────────────┐
                    │   Application Layer  │
                    │   UI / Photo Album   │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │   Sharing Session    │
                    │  State / Membership  │
                    └──────────┬───────────┘
                               │
              ┌────────────────▼────────────────┐
              │       Control / Metadata        │
              │ Discovery / Session / Metadata  │
              │ Security / Scheduling / State   │
              └────────────────┬────────────────┘
                               │
                    ┌──────────▼───────────┐
                    │  Transport Layer    │
                    │ TCP / QUIC / ...    │
                    └──────────┬───────────┘
                               │
                    ┌──────────▼───────────┐
                    │   Local Network      │
                    │ Wi-Fi / Wi-Fi Direct │
                    │ / Hotspot / etc.     │
                    └──────────────────────┘
```

请明确区分：

1. **设备发现（Discovery）**
2. **Session 建立**
3. **控制消息传输**
4. **照片 Meta-data 同步**
5. **照片数据传输**
6. **传输调度**
7. **状态恢复与异常处理**

核心协议尽可能采用跨平台标准，例如：

- UDP / multicast / broadcast：设备发现
- QUIC：控制消息和照片传输（加密）
- JSON / Protobuf：控制协议
- SHA-256 / SHA-1 等标准 hash：照片指纹

不要将核心逻辑绑定到 `MultipeerConnectivity` 等 Apple-only 技术。

如果 iOS 端使用 Bonjour / Network.framework 等系统能力进行发现或通信，请将其封装在平台适配层中，同时设计一个 Android 对应实现，使两端最终遵循相同的应用层协议。

---

# **二、附近成员发现**

这是系统的重要性能要求。

### **目标**

用户点击“开始共享”后，应当能够在 **3 秒以内发现周围可参与共享的设备**。

需要设计明确的 Discovery Protocol，而不是简单调用系统 API。

建议设计：

```text
Device
  ↓
Periodic Discovery Advertisement
  ↓
Nearby devices receive advertisement
  ↓
加入码匹配
  ↓
建立 Control Connection
  ↓
Exchange DeviceInfo
  ↓
加入 Sharing Session
```

每台设备周期性发送轻量级 Discovery Advertisement，例如：

```text
{
    protocol_version,
    device_id,
    display_name,
    avatar_id,
    session_id,
    join_code,
    capabilities,
    control_port
}
```

要求：

- Discovery Advertisement 尽可能小。
- 周期性广播。
- 支持 UDP Broadcast / Multicast。
- 对不同网络环境提供 fallback。
- 发现过程目标 **P95 ≤ 3 秒**。
- 避免等待过长的扫描周期。
- 设备重复收到 Advertisement 时需要去重。
- Advertisement 必须包含协议版本，便于未来协议升级。

需要详细设计：

- Advertisement 周期。
- Discovery timeout。
- 重试策略。
- Broadcast / Multicast 地址。
- IPv4 / IPv6。
- 同一设备如何去重。
- NAT / AP isolation 等情况下怎么办。
- iOS / Android 在不同 Wi-Fi 网络环境下如何发现。
- 手机热点场景如何工作。
- 无路由器情况下是否支持 Wi-Fi Direct / Local-only network。
- App 在前台 / 后台时的限制以及对应 fallback。

请解释为什么选择最终方案，并说明如何保证 **3 秒以内发现附近成员**。

---

# **三、加入码与 Session**

主页提供：

- 4 位加入码输入框。
- 开始共享按钮。

加入码用于快速定位目标 Sharing Session。

发现设备之后：

```text
Join Code Match
      ↓
Session Discovery
      ↓
Control Connection
      ↓
Membership Handshake
      ↓
加入共享群组
```

每个设备拥有：

```text
DeviceID
UserName
Avatar
SessionID
JoinCode
NetworkEndpoint
Capabilities
```

不要使用设备名称作为唯一 ID。

---

# **四、共享中心（Coordinator）**

多人照片共享采用**中心化控制 + 分布式数据传输**架构。

需要从当前共享成员中选择一个 **Coordinator / Center**。

Coordinator 不一定负责实际传输所有照片。

它主要负责维护：

1. Group membership
2. 全局 Photo Metadata
3. 每个成员拥有的照片集合
4. 每个成员需要收到的照片集合
5. 当前传输任务
6. Transfer dependency
7. 网络状态
8. 带宽估计
9. 传输调度
10. 故障恢复

Coordinator 可以是：

- 默认由创建 Session 的设备担任。
- 如果中心退出，需要重新选举 Coordinator。
- 需要设计简单的 Coordinator election / failover 机制。

中心设备不应成为所有照片数据的必经路径。

**照片数据可以 P2P 直接传输。**

---

# **五、照片 Meta-data 与去重**

这是系统的核心逻辑。

用户选择照片之后，首先不要立即传输照片。

每个设备在本地计算照片指纹：

```text
Photo
 ├── PhotoID
 ├── ContentHash
 ├── Size
 ├── Metadata
 └── Owner
```

其中最重要的是：

```text
ContentHash
```

要求能够判断**像素内容完全一致的照片**。

如果两个人拥有同一张照片：

```text
A: photo hash = H1
B: photo hash = H1
```

系统应该认为这是同一张照片，而不是两张照片。

因此需要设计：

- Hash 算法。
- Hash 计算时机。
- 是否需要读取完整照片。
- 大照片 Hash 的性能优化。
- Hash collision 如何处理。
- Live Photo / HEIC / JPEG / PNG 等格式如何处理。
- “像素一致”与“文件完全一致”的区别。

如果系统目标是判断**照片像素是否一致**，不能简单依赖文件名、文件大小或文件 SHA 来作为唯一依据，需要明确设计 Photo Content Fingerprint。

---

# **六、中心化 Photo Metadata**

Coordinator 维护全局 Photo Metadata：

```text
PhotoHash
    │
    ├── Owner A
    ├── Owner B
    └── Owner C
```

例如：

```text
H1 → [A, C]
H2 → [B]
H3 → [A, B, C]
H4 → [C]
```

这意味着：

- H1 有两个可能源头。
- H2 只有 B 可以提供。
- H3 所有人都有，不需要传输。
- H4 只有 C 可以提供。

中心需要维护：

```text
PhotoHash
Owners[]
Size
TransferStatus
RequiredBy[]
AvailableSources[]
```

同时需要支持 metadata 增量更新。

---

# **七、差分计算**

照片选择完成之后，各设备向 Coordinator 上传自己的 Photo Metadata。

Coordinator 汇总：

```text
Global Photo Set
```

然后针对每一个用户计算：

```text
PhotosToReceive(user)
```

定义：

```text
PhotosToReceive(A)
    = GlobalPhotos - PhotosOwnedBy(A)
```

但需要注意：

**不是所有 GlobalPhotos 都必须从某个特定用户重新传输。**

例如：

```text
A owns: H1 H2
B owns: H2 H3
C owns: H3 H4
```

那么：

```text
A needs: H3 H4
B needs: H1 H4
C needs: H1 H2
```

中心同时维护每张照片的：

```text
AvailableSources
```

例如：

```text
H1 → [A]
H2 → [A, B]
H3 → [B, C]
H4 → [C]
```

每个用户最终获得：

```text
RequiredPhotos
    +
CandidateSources
```

---

# **八、中心化传输调度**

不要简单实现：

```text
A → B
A → C
B → A
...
```

而需要设计一个**中心化 Transfer Scheduler**。

Coordinator 根据：

- 源设备
- 目标设备
- 照片大小
- 可用带宽
- 当前连接
- 网络拓扑
- 设备 CPU / IO 能力
- 当前发送 / 接收任务
- 是否存在多个源
- 是否可以转发

动态生成 Transfer Plan。

---

# **九、允许 P2P 转发**

照片不一定只能从原始 Owner 传输。

允许：

```text
A → B → C
```

例如：

```text
H1 only owned by A

A → B
B → C
```

当 B 已经收到 H1 后：

```text
A → B → C
```

可能比：

```text
A → C
```

更高效。

因此需要把整个传输过程建模为：

```text
Photo propagation graph
```

其中：

```text
Node = Device
Edge = Possible transfer
```

中心负责选择最优路径。

---

# **十、多个 Source 动态选择**

如果：

```text
H1 → [A, B, C]
```

而 D 需要 H1，则：

```text
A → D
B → D
C → D
```

都是候选路径。

Scheduler 应根据实时网络状态选择最优 Source。

例如：

```text
A → D : 20 MB/s
B → D : 80 MB/s
C → D : 30 MB/s
```

优先：

```text
B → D
```

但如果 B 当前正在向其他设备传输大量数据，则可能选择 A 或 C。

因此调度应该是**动态的**，而不是在共享开始时一次性静态确定。

---

# **十一、最大化整体带宽**

目标不是简单最大化单条连接速度，而是：

**最大化整个共享 Session 的 Aggregate Throughput，同时避免设备、网络链路和 IO 过载。**

需要考虑：

```text
Device upload bandwidth
Device download bandwidth
Wi-Fi link capacity
CPU
Disk IO
Concurrent connections
Photo size
Source availability
```

例如：

```text
        A
      /   \
     B     C
      \   /
        D
```

如果 A 同时向 B、C、D 发送数据导致 A 成为瓶颈，则应该允许：

```text
A → B
B → C
C → D
```

或者：

```text
A → B
A → C
C → D
```

由 Scheduler 根据实时 bandwidth estimate 决定。

---

# **十二、避免死锁和传输环路**

由于允许转发，必须重点防止：

```text
A → B → C → A
```

这样的循环。

每个 Photo Transfer Task 必须维护：

```text
PhotoHash
Source
Destination
TransferID
State
Version
Dependency
```

并且整个系统需要保证：

- 不产生循环依赖。
- 不产生无限转发。
- 同一照片不会重复传输。
- 同一个目标不会重复接收同一照片。
- Transfer task 可以取消。
- Transfer task 可以重新调度。
- 源设备掉线后能够切换 Source。
- 中间节点掉线后能够重新计算路径。

可以考虑使用：

**DAG-based Transfer Graph**

保证：

```text
TransferGraph = DAG
```

而不是任意 Graph。

---

# **十三、Transfer State Machine**

每个照片传输任务需要具有明确状态：

```text
PENDING
   ↓
SCHEDULED
   ↓
TRANSFERRING
   ↓
VERIFIED
   ↓
COMPLETED
```

异常：

```text
TRANSFERRING
      ↓
    FAILED
      ↓
 RESCHEDULED
      ↓
 TRANSFERRING
```

需要区分：

- source unavailable
- destination unavailable
- connection timeout
- hash mismatch
- insufficient storage
- user cancelled
- session cancelled

照片传输完成后，接收端重新验证 ContentHash。

只有：

```text
received_hash == expected_hash
```

才能标记：

```text
VERIFIED
```

---

# **十四、并发传输**

需要设计合理的 concurrency control。

例如每台设备：

```text
MaxUploadConnections
MaxDownloadConnections
```

Coordinator 根据实时状态调整。

避免：

```text
8 devices
×
multiple connections
```

造成 Wi-Fi 网络拥塞。

同时避免：

```text
某一设备成为 bottleneck
```

需要说明：

- 最大并发连接数。
- 如何动态调整。
- 如何进行 bandwidth estimation。
- 如何避免 head-of-line blocking。
- TCP 与 QUIC 的选择。
- 大文件是否 chunked transfer。
- 是否支持断点续传。

---

# **十五、协议设计**

请定义完整的跨平台 Application Protocol。

至少包括：

### **Discovery**

```text
DISCOVER
ADVERTISEMENT
```

### **Session**

```text
JOIN_REQUEST
JOIN_ACCEPT
JOIN_LEAVE
MEMBERSHIP_UPDATE
```

### **Security**

```text
SECURITY_CODE
SECURITY_CONFIRM
SECURITY_STATUS
```

### **Metadata**

```text
PHOTO_MANIFEST
PHOTO_MANIFEST_DIFF
PHOTO_METADATA_UPDATE
```

### **Scheduling**

```text
TRANSFER_REQUEST
TRANSFER_PLAN
TRANSFER_ASSIGN
TRANSFER_CANCEL
TRANSFER_REASSIGN
```

### **Transfer**

```text
TRANSFER_START
TRANSFER_CHUNK
TRANSFER_COMPLETE
TRANSFER_VERIFY
TRANSFER_FAILED
```

### **Session**

```text
SESSION_COMPLETE
SESSION_FAILED
SESSION_CANCEL
```

协议需要包含：

```text
protocol_version
message_type
session_id
device_id
sequence_number
timestamp
payload
```

并设计：

- Message ID。
- ACK。
- Retry。
- Timeout。
- Idempotency。
- Version compatibility。

---

# **十六、三个 UI 页面**

## **1. 主页**

包含：

- 选择照片按钮。
- 已选择照片数量。
- 4 位加入码输入框。
- 开始共享按钮。
- 右上角设置。

设置：

- 头像。
- 名称。
- 默认头像自动生成。
- 默认名称使用设备名称。

---

## **2. 面对面共享**

显示：

- 当前加入码。
- 附近已匹配成员。
- 成员头像。
- 成员名称。
- 群组安全码。
- 确认共享按钮。

头像右上角：

```text
未确认 → 灰色
已确认 → 绿色 ✓
```

确认状态实时同步。

如果成员发生加入 / 退出：

- 实时更新成员列表。
- 重新生成安全码。
- 清除已有确认状态。
- 所有人重新确认。

只有：

```text
All Members Confirmed
```

才能进入照片传输。

---

# **十七、共享结果页面**

显示：

### **成员**

成员头像列表。

### **传输进度**

```text
我应收到：32 张
已收到：21 张
```

共享完成后显示横向 Tab：

```text
┌────────────┬────────────┐
│ 我的照片   │ 已收到     │
└────────────┴────────────┘
```

我的照片：

- 本次选择的照片。

已收到：

- 所有收到的照片。
- 预览图。
- 来源用户。

例如：

```text
[Photo]

来自 Alice
```

---

# **十八、失败与退出**

任意步骤：

```text
成员退出
连接失败
发现失败
确认失败
Metadata 同步失败
照片传输失败
Coordinator 退出
```

都必须能够安全结束或恢复 Session。

如果共享尚未成功：

**保留主页已经选择的照片。**

同时：

- 停止后台任务。
- 取消 Transfer Task。
- 释放连接。
- 清理临时缓存。
- 清理当前 Session 状态。

共享完全成功后：

- 显示结果页面。
- 清除主页照片选择。
- 重置 Session。
- 准备下一次共享。

---

# **十九、重点性能目标**

请把以下指标作为设计目标：


| **指标**          | **目标**         |
| --------------- | -------------- |
| 附近设备发现          | ≤ 3 秒          |
| 加入 Session      | ≤ 1 秒          |
| Metadata 同步     | 尽可能低延迟         |
| 照片去重            | 本地完成           |
| 照片传输            | P2P            |
| 中心              | 只负责控制，不承担所有数据流 |
| 多源照片            | 支持             |
| P2P Relay       | 支持             |
| 动态调度            | 支持             |
| 断点续传            | 支持             |
| Source Failover | 支持             |
| Transfer DAG    | 不允许循环          |
| 最大成员            | 当前 8，可扩展       |


---

# **二十、请最终输出**

请不要只给出 UI Demo，而是按照一个**可实际运行、可扩展、未来支持 Android 的产品架构**进行实现。

最终请提供：

1. **完整系统架构图**
2. iOS / Android 跨平台网络架构
3. Discovery Protocol
4. 为什么能够做到 3 秒内发现附近设备
5. Session / Coordinator 架构
6. Coordinator Failover 方案
7. Photo Content Fingerprint 方案
8. Global Photo Metadata 数据结构
9. Photo Deduplication 算法
10. 每个用户的差分照片计算方法
11. Source Candidate 计算方法
12. Transfer Graph / DAG 设计
13. 中心化 Transfer Scheduler
14. 多 Source 选择算法
15. Relay / Forwarding 算法
16. Aggregate Bandwidth 最大化策略
17. Deadlock / Loop Prevention
18. Transfer State Machine
19. 完整 Application Protocol
20. TCP / QUIC / UDP 的具体选择及原因
21. iOS 实现方式
22. Android 未来实现方式
23. Swift / SwiftUI 项目代码结构
24. 核心数据模型
25. 核心代码实现
26. 异常恢复机制
27. 性能测试方案
28. 3 秒 Discovery、多人传输和调度的测试指标

**特别要求：**

不要为了快速实现而选择 Apple-only 的通信方案作为核心协议。必须优先保证**协议和架构的跨平台性**。

同时，不要把照片全部发送到 Coordinator。Coordinator 只维护 **Metadata + Scheduling State**，照片数据应该尽可能通过 **P2P direct transfer / relay** 完成。

整个系统的核心目标是：

**在面对面多人共享场景下，通过快速设备发现、中心化 Metadata 去重、差分计算、多源选择、P2P Relay 和中心化动态调度，在保证无死锁、无重复传输的前提下，最大化整个共享群组的有效带宽和传输效率。**