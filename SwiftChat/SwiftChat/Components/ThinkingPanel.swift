// ThinkingPanel.swift -- Expandable thinking/reasoning panel for streaming
import SwiftUI

struct ThinkingPanel: View {
    let text: String
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header toggle
            Button {
                withAnimation(SwiftChatTheme.spring) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.filled.head.profile")
                        .font(.caption)
                        .foregroundStyle(SwiftChatTheme.accentSecondary)
                    Text("Thinking...")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SwiftChatTheme.accentSecondary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(SwiftChatTheme.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)

            // Expandable content
            if isExpanded {
                ScrollView {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(SwiftChatTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 160)
            }
        }
        .background(SwiftChatTheme.thinkingGradient)
        .clipShape(RoundedRectangle(cornerRadius: SwiftChatTheme.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: SwiftChatTheme.radiusMedium)
                .strokeBorder(SwiftChatTheme.accentSecondary.opacity(0.20), lineWidth: 1)
        )
    }
}
