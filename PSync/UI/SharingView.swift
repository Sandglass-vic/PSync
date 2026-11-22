import SwiftUI

struct SharingView: View {
    @ObservedObject var session: SessionManager

    private var shouldShowTransferProgress: Bool {
        switch session.sessionState.phase {
        case .syncingMetadata, .transferring, .awaitingGroupSync, .completed:
            return true
        default:
            return false
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            phaseIndicator

            if let joinCode = session.sessionState.joinCode {
                SessionCodeBanner(title: "加入码", code: joinCode, tracking: 8)
            }

            if let securityCode = session.sessionState.securityCode,
               session.sessionState.members.count > 1 {
                SessionCodeBanner(title: "群组安全码", code: securityCode, tracking: 6)
            }

            membersSection

            Spacer()

            actionButtons
        }
        .padding()
        .navigationTitle("PSync面对面共享")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    session.cancelSharing()
                    // 由 HomeView 监听 isSharing/phase 收起，避免只退到安全码页
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .accessibilityLabel("返回主页")
            }
        }
        .navigationDestination(isPresented: Binding(
            get: { shouldShowTransferProgress },
            set: { _ in }
        )) {
            TransferProgressView(session: session)
        }
        // 不在 onDisappear 里自动 cancel：navigationDestination 推出传输页时
        // SharingView 也会 disappear，误取消会导致「点了确认却进不去/被踢回」
    }

    @ViewBuilder
    private var phaseIndicator: some View {
        HStack {
            ProgressView()
                .opacity(isLoading ? 1 : 0)
            Text(phaseText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var isLoading: Bool {
        switch session.sessionState.phase {
        case .discovering, .syncingMetadata:
            return true
        default:
            return false
        }
    }

    private var phaseText: String {
        switch session.sessionState.phase {
        case .idle: return "准备中"
        case .discovering: return "正在发现附近设备..."
        case .waitingConfirmation: return "等待所有成员确认"
        case .syncingMetadata: return "同步照片信息..."
        case .transferring: return "传输中..."
        case .awaitingGroupSync: return "等待全员同步..."
        case .completed: return "共享完成"
        case .failed(let msg): return "失败: \(msg)"
        }
    }

    private var membersSection: some View {
        Group {
            if !session.sessionState.members.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 28) {
                        ForEach(session.sessionState.members) { member in
                            MemberAvatarTile(member: member)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 8)
                }
            }
        }
        .frame(minHeight: 96)
        .animation(nil, value: session.sessionState.members.map { "\($0.deviceId):\($0.confirmed)" })
    }

    private var localConfirmed: Bool {
        session.sessionState.members.first { $0.deviceId == session.identity.deviceId }?.confirmed == true
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch session.sessionState.phase {
        case .waitingConfirmation where !localConfirmed:
            Button {
                session.confirmSharing()
            } label: {
                PSyncPrimaryButtonLabel(title: "确认共享")
            }
            .buttonStyle(.plain)
        case .waitingConfirmation, .syncingMetadata:
            Button {
                session.unconfirmSharing()
            } label: {
                PSyncPrimaryButtonLabel(title: "取消共享")
            }
            .buttonStyle(.plain)
        default:
            EmptyView()
        }
    }
}

private struct SessionCodeBanner: View {
    let title: String
    let code: String
    let tracking: CGFloat

    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(code)
                .font(.system(size: 36, weight: .bold, design: .monospaced))
                .tracking(tracking)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
