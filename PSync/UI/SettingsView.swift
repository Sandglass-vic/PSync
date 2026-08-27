import SwiftUI

struct SettingsView: View {
    @ObservedObject var session: SessionManager
    @Environment(\.dismiss) private var dismiss
    @State private var userName: String = ""
    @State private var avatarId: Int = 0

    var body: some View {
        NavigationStack {
            Form {
                Section("个人信息") {
                    HStack {
                        Text("头像")
                        Spacer()
                        AvatarPickerView(selectedId: $avatarId)
                    }

                    TextField("名称", text: $userName)
                }

                Section {
                    Text("默认名称使用设备名称，头像可自定义选择。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        session.updateIdentity(name: userName, avatarId: avatarId)
                        dismiss()
                    }
                }
            }
            .onAppear {
                userName = session.identity.userName
                avatarId = session.identity.avatarId
            }
        }
    }
}

struct AvatarPickerView: View {
    @Binding var selectedId: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<8, id: \.self) { id in
                AvatarView(avatarId: id, size: 36)
                    .overlay {
                        if selectedId == id {
                            Circle().stroke(Color.blue, lineWidth: 2)
                        }
                    }
                    .onTapGesture { selectedId = id }
            }
        }
    }
}
