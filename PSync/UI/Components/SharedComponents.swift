import SwiftUI
import UIKit

enum PSyncButtonMetrics {
    static let cornerRadius: CGFloat = 12
}

struct PSyncPhotoPickerButtonLabel: View {
    let title: String
    let systemImage: String
    let hasSelection: Bool

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.headline)
            .psyncActionButtonFrame()
            .background(hasSelection ? Color.green.opacity(0.15) : Color.blue.opacity(0.1))
            .foregroundStyle(hasSelection ? .green : .blue)
            .clipShape(RoundedRectangle(cornerRadius: PSyncButtonMetrics.cornerRadius))
    }
}

struct PSyncPrimaryButtonLabel: View {
    let title: String
    var isEnabled: Bool = true
    var isCompleted: Bool = false

    var body: some View {
        Text(title)
            .font(.headline)
            .psyncActionButtonFrame()
            .background(backgroundColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: PSyncButtonMetrics.cornerRadius))
    }

    private var backgroundColor: Color {
        if isCompleted { return .gray }
        return isEnabled ? .blue : .gray
    }
}

extension View {
    func psyncActionButtonFrame() -> some View {
        frame(maxWidth: .infinity)
            .padding()
    }
}

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

struct MemberAvatarTile: View {
    let member: SharingMember

    var body: some View {
        VStack(spacing: 8) {
            AvatarView(avatarId: member.avatarId, size: 64, confirmed: member.confirmed)
            Text(member.userName)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 72)
        }
    }
}

struct PhotoThumbnailView: View {
    let thumbnailData: Data?
    var sourceLabel: String? = nil
    var isLivePhoto: Bool = false

    var body: some View {
        PhotosGridCell(
            item: GridPhotoItem(
                id: UUID().uuidString,
                thumbnailData: thumbnailData,
                sourceLabel: sourceLabel,
                isLivePhoto: isLivePhoto
            )
        )
    }
}

private final class KeyboardDismissTapHandler: NSObject, UIGestureRecognizerDelegate {
    let excludedIdentifier: String
    var isFocused: () -> Bool
    var dismiss: () -> Void

    private weak var window: UIWindow?
    private var tapGesture: UITapGestureRecognizer?

    init(excludedIdentifier: String, isFocused: @escaping () -> Bool, dismiss: @escaping () -> Void) {
        self.excludedIdentifier = excludedIdentifier
        self.isFocused = isFocused
        self.dismiss = dismiss
    }

    func install() {
        guard tapGesture == nil,
              let window = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene })
                  .flatMap(\.windows)
                  .first(where: \.isKeyWindow) else { return }

        self.window = window
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        window.addGestureRecognizer(tap)
        tapGesture = tap
    }

    func uninstall() {
        if let tapGesture, let window {
            window.removeGestureRecognizer(tapGesture)
        }
        tapGesture = nil
        window = nil
    }

    @objc private func handleTap() {
        dismiss()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard isFocused() else { return false }

        var view: UIView? = touch.view
        while let current = view {
            if current.accessibilityIdentifier == excludedIdentifier {
                return false
            }
            view = current.superview
        }
        return true
    }
}

private struct DismissKeyboardOnTapOutsideModifier: ViewModifier {
    let excludedIdentifier: String
    @FocusState.Binding var isFocused: Bool
    @State private var handler: KeyboardDismissTapHandler?

    func body(content: Content) -> some View {
        content
            .onAppear {
                let tapHandler = KeyboardDismissTapHandler(
                    excludedIdentifier: excludedIdentifier,
                    isFocused: { isFocused },
                    dismiss: { isFocused = false }
                )
                tapHandler.install()
                handler = tapHandler
            }
            .onDisappear {
                handler?.uninstall()
                handler = nil
            }
    }
}

extension View {
    func dismissKeyboardOnTapOutside(excluding identifier: String, isFocused: FocusState<Bool>.Binding) -> some View {
        modifier(DismissKeyboardOnTapOutsideModifier(excludedIdentifier: identifier, isFocused: isFocused))
    }
}
