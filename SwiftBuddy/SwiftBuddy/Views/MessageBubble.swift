// MessageBubble.swift — Premium chat message bubbles (iOS + macOS)
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Static Message Bubble
// ─────────────────────────────────────────────────────────────────────────────

struct MessageBubble: View {
    let message: ChatMessage
    @State private var showTimestamp = false
    @EnvironmentObject private var engine: InferenceEngine

    var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser { Spacer(minLength: 52) }

            if !isUser {
                AvatarView(
                    isGenerating: false,
                    size: 30
                )
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                if isUser {
                    userBubble
                } else {
                    assistantBubble
                }

                if showTimestamp {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundStyle(SwiftBuddyTheme.textTertiary)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .onTapGesture {
                withAnimation(SwiftBuddyTheme.quickSpring) {
                    showTimestamp.toggle()
                }
            }

            if !isUser { Spacer(minLength: 52) }
        }
    }

    // MARK: — User Bubble

    private var userBubble: some View {
        Text(message.content)
            .font(.system(.body, design: .default))
            .textSelection(.enabled)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(SwiftBuddyTheme.userBubbleGradient)
            .clipShape(UserBubbleShape())
            .shadow(
                color: SwiftBuddyTheme.accent.opacity(0.30),
                radius: 6, x: 0, y: 3
            )
    }

    // MARK: — Assistant Bubble

    private var assistantBubble: some View {
        Text(message.content)
            .font(.system(.body, design: .default))
            .textSelection(.enabled)
            .foregroundStyle(SwiftBuddyTheme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .background(SwiftBuddyTheme.surface.opacity(0.80))
            .clipShape(AssistantBubbleShape())
            .overlay(
                AssistantBubbleShape()
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(
                color: SwiftBuddyTheme.shadowBubble.color,
                radius: SwiftBuddyTheme.shadowBubble.radius,
                x: SwiftBuddyTheme.shadowBubble.x,
                y: SwiftBuddyTheme.shadowBubble.y
            )
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Live Streaming Bubble
// ─────────────────────────────────────────────────────────────────────────────

struct StreamingBubble: View {
    let text: String
    let thinkingText: String?

    @EnvironmentObject private var engine: InferenceEngine
    @State private var thinkingExpanded = true

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            AvatarView(isGenerating: true, size: 30)

            VStack(alignment: .leading, spacing: 6) {
                // ── Thinking section ─────────────────────────────────────────
                if let thinking = thinkingText, !thinking.isEmpty {
                    ThinkingPanel(text: thinking, isExpanded: $thinkingExpanded)
                }

                // ── Response text ────────────────────────────────────────────
                if !text.isEmpty {
                    streamingText
                } else if thinkingText == nil || thinkingText?.isEmpty == true {
                    // Show typing indicator only when there's no content at all
                    typingDots
                }
            }

            Spacer(minLength: 52)
        }
    }

    private var streamingText: some View {
        // Inline blinking cursor via attributed string approach
        HStack(alignment: .bottom, spacing: 0) {
            Text(text)
                .font(.system(.body, design: .default))
                .foregroundStyle(SwiftBuddyTheme.textPrimary)
                .textSelection(.enabled)
            BlinkingCursor()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .background(SwiftBuddyTheme.surface.opacity(0.80))
        .clipShape(AssistantBubbleShape())
        .overlay(
            AssistantBubbleShape()
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(
            color: SwiftBuddyTheme.shadowBubble.color,
            radius: SwiftBuddyTheme.shadowBubble.radius,
            x: SwiftBuddyTheme.shadowBubble.x,
            y: SwiftBuddyTheme.shadowBubble.y
        )
    }

    private var typingDots: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                BouncingDot(index: i)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .background(SwiftBuddyTheme.surface.opacity(0.80))
        .clipShape(AssistantBubbleShape())
        .overlay(
            AssistantBubbleShape()
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }
}

