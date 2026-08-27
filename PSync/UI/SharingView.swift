import SwiftUI

struct SharingView: View {
    @ObservedObject var session: SessionManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            phaseIndicator

            if let joinCode = session.sessionState.joinCode {
                VStack(spacing: 4) {
                    Text("加入码")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(joinCode)
                        .font(.system(size: 36, weight: .bold, design: .monospaced))
                        .tracking(8)
                }
                .padding()
                .background(Color.blue.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            if let securityCode = session.sessionState.securityCode {
                VStack(spacing: 4) {
                    Text("群组安全码")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(securityCode)
                        .font(.title2.bold().monospaced())
                }
            }

            membersSection

            if session.sessionState.phase == .transferring {
                transferProgress
            }

            Spacer()

            actionButtons
        }
        .padding()
        .navigationTitle("面对面共享")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $session.showResults) {
            ResultsView(session: session)
        }
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
        case .discovering, .syncingMetadata, .transferring:
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
        case .completed: return "共享完成"
        case .failed(let msg): return "失败: \(msg)"
        }
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("共享成员 (\(session.sessionState.members.count))")
                .font(.headline)

            if session.sessionState.members.isEmpty {
                Text("正在搜索附近设备...")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                ForEach(session.sessionState.members) { member in
                    MemberRow(member: member)
                }
            }
        }
    }

    private var transferProgress: some View {
        VStack(spacing: 8) {
            ProgressView(value: progressValue)
            HStack {
                Text("我应收到：\(session.sessionState.photosToReceive) 张")
                Spacer()
                Text("已收到：\(session.sessionState.photosReceived) 张")
            }
            .font(.subheadline)
        }
        .padding()
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var progressValue: Double {
        guard session.sessionState.photosToReceive > 0 else { return 0 }
        return Double(session.sessionState.photosReceived) / Double(session.sessionState.photosToReceive)
    }

    @ViewBuilder
    private var actionButtons: some View {
        if session.sessionState.phase == .waitingConfirmation {
            Button {
                session.confirmSharing()
            } label: {
                Text("确认共享")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }

        Button(role: .destructive) {
            session.cancelSharing()
            dismiss()
        } label: {
            Text("取消共享")
                .frame(maxWidth: .infinity)
                .padding()
        }
    }
}
