# PSync

2～8 人面对面本地照片互传 iOS 应用。

## 构建与运行

### 要求
- Xcode 16+（iOS 17.0+）
- 两台或以上 iOS 设备（或模拟器 + 真机）用于测试互传

### 打开项目
```bash
open PSync.xcodeproj
```

### 命令行构建
```bash
xcodebuild -project PSync.xcodeproj -scheme PSync \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

### 运行测试
```bash
xcodebuild -project PSync.xcodeproj -scheme PSync \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

## 使用说明

1. **主页**：选择照片 → 输入 4 位加入码（或留空创建新共享）→ 开始共享
2. **面对面共享**：查看成员列表和安全码 → 所有成员确认后开始传输
3. **共享结果**：查看传输进度和收到的照片

## 架构

详见 [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

## 手动配置

- 在 Xcode 中设置 **Development Team**（Signing & Capabilities）
- 真机测试需在同一 Wi-Fi 网络下
- 首次运行需授权照片库和本地网络访问
