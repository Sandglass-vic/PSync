import SwiftUI

struct AvatarView: View {
    let avatarId: Int
    let size: CGFloat
    var confirmed: Bool = false

    private let colors: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .indigo, .mint
    ]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(colors[avatarId % colors.count].gradient)
                .frame(width: size, height: size)
                .overlay {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.4))
                        .foregroundStyle(.white)
                }

            if confirmed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: size * 0.3))
                    .foregroundStyle(.green)
                    .background(Circle().fill(.white).padding(2))
                    .offset(x: size * 0.1, y: -size * 0.1)
            }
        }
    }
}

struct MemberRow: View {
    let member: SharingMember

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(avatarId: member.avatarId, size: 48, confirmed: member.confirmed)
            VStack(alignment: .leading, spacing: 2) {
                Text(member.userName)
                    .font(.headline)
                if member.isCoordinator {
                    Text("协调者")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(member.confirmed ? "已确认" : "未确认")
                .font(.caption)
                .foregroundStyle(member.confirmed ? .green : .secondary)
        }
    }
}

struct PhotoThumbnailView: View {
    let thumbnailData: Data?

    var body: some View {
        Group {
            if let data = thumbnailData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: 80, height: 80)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
