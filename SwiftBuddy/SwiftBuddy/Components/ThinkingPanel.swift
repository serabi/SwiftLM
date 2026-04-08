// ThinkingPanel.swift -- Expandable thinking/reasoning panel for streaming
import SwiftUI

struct ThinkingPanel: View {
    let text: String
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header toggle
            Button {
                withAnimation(SwiftBuddyTheme.spring) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.filled.head.profile")
                        .font(.caption)
                        .foregroundStyle(SwiftBuddyTheme.accentSecondary)
                    Text("Thinking...")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(SwiftBuddyTheme.accentSecondary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(SwiftBuddyTheme.textTertiary)
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
                        .foregroundStyle(SwiftBuddyTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .frame(maxHeight: 160)
            }
        }
        .background(SwiftBuddyTheme.thinkingGradient)
        .clipShape(RoundedRectangle(cornerRadius: SwiftBuddyTheme.radiusMedium))
        .overlay(
            RoundedRectangle(cornerRadius: SwiftBuddyTheme.radiusMedium)
                .strokeBorder(SwiftBuddyTheme.accentSecondary.opacity(0.20), lineWidth: 1)
        )
    }
}
