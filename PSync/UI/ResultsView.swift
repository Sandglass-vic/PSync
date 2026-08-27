import SwiftUI

struct ResultsView: View {
    @ObservedObject var session: SessionManager
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            membersHeader

            transferSummary

            Picker("", selection: $selectedTab) {
                Text("我的照片").tag(0)
                Text("已收到").tag(1)
            }
            .pickerStyle(.segmented)
            .padding()

            TabView(selection: $selectedTab) {
                myPhotosTab.tag(0)
                receivedPhotosTab.tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
        .navigationTitle("共享结果")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var membersHeader: some View {
        VStack(spacing: 12) {
            Text("共享成员")
                .font(.headline)
            HStack(spacing: 16) {
                ForEach(session.sessionState.members) { member in
                    VStack(spacing: 4) {
                        AvatarView(avatarId: member.avatarId, size: 48, confirmed: true)
                        Text(member.userName)
                            .font(.caption)
                    }
                }
            }
        }
        .padding()
    }

    private var transferSummary: some View {
        HStack {
            VStack {
                Text("\(session.sessionState.photosToReceive)")
                    .font(.title.bold())
                Text("应收到")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack {
                Text("\(session.sessionState.photosReceived)")
                    .font(.title.bold())
                    .foregroundStyle(.green)
                Text("已收到")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color.gray.opacity(0.08))
    }

    private var myPhotosTab: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100))], spacing: 8) {
                ForEach(session.sessionState.localPhotos) { photo in
                    PhotoThumbnailView(thumbnailData: photo.thumbnailData)
                }
            }
            .padding()
        }
    }

    private var receivedPhotosTab: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(session.sessionState.receivedPhotos) { photo in
                    HStack(spacing: 12) {
                        PhotoThumbnailView(thumbnailData: photo.thumbnailData)
                        VStack(alignment: .leading) {
                            Text("来自 \(photo.sourceUserName)")
                                .font(.subheadline)
                        }
                        Spacer()
                    }
                }
            }
            .padding()
        }
    }
}
