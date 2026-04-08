// AvatarView.swift -- Pulsing avatar ring for AI messages
import SwiftUI

struct AvatarView: View {
    var isGenerating: Bool = false
    var size: CGFloat = 30

    @State private var pulse: Bool = false

    var body: some View {
        ZStack {
            // Outer glow ring when generating
            if isGenerating {
                Circle()
                    .stroke(SwiftChatTheme.accent.opacity(pulse ? 0.55 : 0.15), lineWidth: 2)
                    .frame(width: size + 8, height: size + 8)
                    .scaleEffect(pulse ? 1.12 : 1.0)
                    .animation(
                        .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                        value: pulse
                    )
            }

            // Avatar circle
            Circle()
                .fill(SwiftChatTheme.avatarGradient)
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: "bolt.fill")
                        .font(.system(size: size * 0.40, weight: .semibold))
                        .foregroundStyle(.white)
                )
        }
        .onAppear { if isGenerating { pulse = true } }
        .onChange(of: isGenerating) { _, gen in
            pulse = gen
        }
    }
}
