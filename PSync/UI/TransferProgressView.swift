import SwiftUI

struct TransferProgressView: View {
    @ObservedObject var session: SessionManager

    private var isLocallyDone: Bool {
        GroupExitPolicy.isLocalTransferFinished(session.sessionState.phase)
    }

    private var isGroupSettled: Bool {
        GroupExitPolicy.isGroupSettled(
            phase: session.sessionState.phase,
            isTransferNetworkActive: session.isTransferNetworkActive
        )
    }

    private var progressValue: Double {
        let total = max(session.sessionState.photosToReceive, 1)
        return min(Double(session.sessionState.photosReceived) / Double(total), 1)
    }

    var body: some View {
        Group {
            if isLocallyDone {
                VStack(spacing: 0) {
                    compactCompletionBanner
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 4)

                    PhotoResultsContent(session: session)
                }
            } else {
                ScrollView {
                    VStack(spacing: 28) {
                        progressSection
                            .padding(.top, 32)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle("PSync照片传输")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    session.cancelSharing()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .accessibilityLabel("返回主页")
            }
        }
    }

    @ViewBuilder
    private var compactCompletionBanner: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: isGroupSettled ? "checkmark.circle.fill" : "clock.badge.checkmark")
                    .font(.title2)
                    .foregroundStyle(isGroupSettled ? .green : .orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isGroupSettled ? "全部完成" : "本机收发完成")
                        .font(.headline)
                    Text("\(session.sessionState.photosReceived) / \(session.sessionState.photosToReceive) 张")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            if !isGroupSettled {
                Text("等待其他成员完成（\(session.completedMemberCount)/\(session.sessionState.members.count)），全员同步后再一起退出。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if session.sessionState.photosReceived > 0 {
                Text("照片已写入系统「照片」的「PSync」相簿，可在下方预览。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isLocallyDone, session.sessionState.photosReceived > 0 {
                Button {
                    PhotoLibraryImporter.openSystemPhotosHome()
                } label: {
                    Label("打开照片", systemImage: "photo.on.rectangle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.blue.opacity(0.12))
                        .foregroundStyle(.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                .accessibilityLabel("打开系统照片")
            }
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .stroke(Color.blue.opacity(0.12), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: progressValue)
                    .stroke(Color.blue, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.35), value: progressValue)

                VStack(spacing: 4) {
                    Text("\(session.sessionState.photosReceived)")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("/ \(session.sessionState.photosToReceive) 张")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 160, height: 160)

            Text(session.sessionState.photosToReceive == 0 ? "正在发送照片…" : "正在接收照片…")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}
