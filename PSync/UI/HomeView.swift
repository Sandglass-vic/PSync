import PhotosUI
import SwiftUI

struct HomeView: View {
    @ObservedObject var session: SessionManager
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var navigateToSharing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 60))
                        .foregroundStyle(.blue)

                    Text("PSync")
                        .font(.largeTitle.bold())

                    Text("面对面本地照片互传")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                PhotosPicker(
                    selection: $selectedItems,
                    maxSelectionCount: 100,
                    matching: .images
                ) {
                    Label("选择照片", systemImage: "photo.badge.plus")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .onChange(of: selectedItems) { _, newItems in
                    Task {
                        await session.processSelectedImages(newItems)
                    }
                }

                if !session.selectedPhotos.isEmpty {
                    Text("已选择 \(session.selectedPhotos.count) 张照片")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("加入码")
                        .font(.headline)
                    Spacer()
                    JoinCodeInputView(code: $session.joinCodeInput)
                }
                .padding(.horizontal)

                Text("留空则创建新共享，或输入 4 位加入码加入")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    Task {
                        await session.startSharing()
                        navigateToSharing = true
                    }
                } label: {
                    Text("开始共享")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(session.selectedPhotos.isEmpty ? Color.gray : Color.blue)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .disabled(session.selectedPhotos.isEmpty)
                .padding(.horizontal)

                Spacer()
            }
            .padding()
            .navigationDestination(isPresented: $navigateToSharing) {
                SharingView(session: session)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        session.showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $session.showSettings) {
                SettingsView(session: session)
            }
        }
    }
}

struct JoinCodeInputView: View {
    @Binding var code: String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { index in
                TextField("", text: digitBinding(index: index))
                    .frame(width: 44, height: 52)
                    .multilineTextAlignment(.center)
                    .font(.title2.bold())
                    .keyboardType(.numberPad)
                    .background(Color.gray.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func digitBinding(index: Int) -> Binding<String> {
        Binding(
            get: {
                guard index < code.count else { return "" }
                return String(code[code.index(code.startIndex, offsetBy: index)])
            },
            set: { newValue in
                let filtered = newValue.filter(\.isNumber)
                var chars = Array(code.padding(toLength: 4, withPad: " ", startingAt: 0))
                if filtered.isEmpty {
                    if index < chars.count { chars[index] = " " }
                } else {
                    chars[index] = filtered.last!
                }
                code = String(chars).replacingOccurrences(of: " ", with: "").prefix(4).description
            }
        )
    }
}
