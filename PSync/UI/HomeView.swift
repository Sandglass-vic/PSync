import PhotosUI
import SwiftUI

struct HomeView: View {
    @ObservedObject var session: SessionManager
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var navigateToSharing = false
    @FocusState private var isJoinCodeFocused: Bool

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
                    matching: .any(of: [.images, .livePhotos]),
                    photoLibrary: .shared()
                ) {
                    PSyncPhotoPickerButtonLabel(
                        title: session.selectedPhotos.isEmpty
                            ? "选择照片"
                            : "已选择 \(session.selectedPhotos.count) 张照片",
                        systemImage: session.selectedPhotos.isEmpty ? "photo.badge.plus" : "checkmark.circle.fill",
                        hasSelection: !session.selectedPhotos.isEmpty
                    )
                }
                .buttonStyle(.plain)
                .onChange(of: selectedItems) { _, newItems in
                    Task {
                        await session.processSelectedImages(newItems)
                    }
                }

                HStack {
                    Text("加入码")
                        .font(.headline)
                    Spacer()
                    JoinCodeInputView(code: $session.joinCodeInput, isFocused: $isJoinCodeFocused)
                }

                Button {
                    Task {
                        await session.startSharing()
                        if session.isSharing {
                            navigateToSharing = true
                        }
                    }
                } label: {
                    PSyncPrimaryButtonLabel(
                        title: "开始共享",
                        isEnabled: isJoinCodeValid
                    )
                }
                .buttonStyle(.plain)
                .disabled(!isJoinCodeValid)

                Spacer()
            }
            .padding()
            .navigationDestination(isPresented: $navigateToSharing) {
                SharingView(session: session)
            }
            .onChange(of: session.shouldPopSharingUI) { _, shouldPop in
                guard shouldPop else { return }
                navigateToSharing = false
                // 仅在会话已清空选图时同步清空 PhotosPicker；发现页返回应保留勾选
                if session.selectedPhotos.isEmpty {
                    selectedItems = []
                }
                session.acknowledgeSharingUIPopped()
            }
            .onChange(of: session.selectedPhotos.count) { _, count in
                // 会话清空选图后，同步清空 PhotosPicker 勾选状态
                if count == 0, !selectedItems.isEmpty {
                    selectedItems = []
                }
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
            .dismissKeyboardOnTapOutside(excluding: "join_code_input", isFocused: $isJoinCodeFocused)
            .onAppear {
                SimulatorScenarioRunner.attach(to: session)
            }
            .onChange(of: session.isSharing) { _, sharing in
                if sharing {
                    navigateToSharing = true
                }
            }
        }
    }

    private var isJoinCodeValid: Bool {
        JoinCodeGenerator.isValid(session.joinCodeInput)
    }
}

struct JoinCodeInputView: View {
    @Binding var code: String
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .focused($isFocused)
                .opacity(0)
                .frame(width: 1, height: 1)

            HStack(spacing: 8) {
                ForEach(0..<4, id: \.self) { index in
                    Text(digit(at: index))
                        .frame(width: 44, height: 52)
                        .font(.title2.bold())
                        .background(Color.gray.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { isFocused = true }
        }
        .accessibilityIdentifier("join_code_input")
        .onChange(of: code) { _, newValue in
            let filtered = String(newValue.filter(\.isNumber).prefix(4))
            if filtered != newValue { code = filtered }
        }
    }

    private func digit(at index: Int) -> String {
        guard index < code.count else { return "" }
        return String(code[code.index(code.startIndex, offsetBy: index)])
    }
}
