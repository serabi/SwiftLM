// Theme.swift — SwiftChat design system
// Single source of truth for colors, gradients, radii, and animations.
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — Color Tokens
// ─────────────────────────────────────────────────────────────────────────────

public enum SwiftChatTheme {

    // ── Background layers ─────────────────────────────────────────────────────
    /// Deep navy-black canvas — the app's primary background.
    public static let background = Color(hue: 0.67, saturation: 0.20, brightness: 0.07)
    /// Slightly elevated surface for cards and panels.
    public static let surface = Color(hue: 0.67, saturation: 0.18, brightness: 0.12)
    /// Second elevation — dialogs, popovers.
    public static let surfaceElevated = Color(hue: 0.67, saturation: 0.15, brightness: 0.17)
    /// Subtle divider / separator.
    public static let divider = Color.white.opacity(0.08)

    // ── Brand accents ─────────────────────────────────────────────────────────
    /// Primary accent — vivid indigo.
    public static let accent = Color(hue: 0.70, saturation: 0.90, brightness: 0.95)
    /// Secondary accent — electric violet.
    public static let accentSecondary = Color(hue: 0.76, saturation: 0.85, brightness: 0.95)
    /// Cyan highlight — used in avatars and MoE badges.
    public static let cyan = Color(hue: 0.54, saturation: 0.80, brightness: 0.95)

    // ── Semantic ──────────────────────────────────────────────────────────────
    public static let success = Color(hue: 0.40, saturation: 0.70, brightness: 0.80)
    public static let warning = Color(hue: 0.10, saturation: 0.85, brightness: 0.95)
    public static let error   = Color(hue: 0.02, saturation: 0.80, brightness: 0.90)

    // ── Text ──────────────────────────────────────────────────────────────────
    public static let textPrimary   = Color.white
    public static let textSecondary = Color.white.opacity(0.60)
    public static let textTertiary  = Color.white.opacity(0.35)

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: — Gradients
    // ─────────────────────────────────────────────────────────────────────────

    /// User message bubble fill.
    public static let userBubbleGradient = LinearGradient(
        colors: [
            Color(hue: 0.70, saturation: 0.80, brightness: 0.90),
            Color(hue: 0.76, saturation: 0.82, brightness: 0.88)
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// AI avatar ring gradient.
    public static let avatarGradient = LinearGradient(
        colors: [
            Color(hue: 0.70, saturation: 0.85, brightness: 0.95),
            Color(hue: 0.54, saturation: 0.80, brightness: 0.95)
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// Hero card gradient (active model card).
    public static let heroGradient = LinearGradient(
        colors: [
            Color(hue: 0.70, saturation: 0.75, brightness: 0.30),
            Color(hue: 0.76, saturation: 0.80, brightness: 0.22)
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    /// Thinking panel tint.
    public static let thinkingGradient = LinearGradient(
        colors: [
            Color(hue: 0.76, saturation: 0.40, brightness: 0.18),
            Color(hue: 0.72, saturation: 0.35, brightness: 0.16)
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: — Corner Radii
    // ─────────────────────────────────────────────────────────────────────────

    public static let radiusSmall:  CGFloat = 8
    public static let radiusMedium: CGFloat = 14
    public static let radiusLarge:  CGFloat = 20
    public static let radiusXL:     CGFloat = 28

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: — Animation
    // ─────────────────────────────────────────────────────────────────────────

    public static let spring     = Animation.spring(response: 0.4, dampingFraction: 0.75)
    public static let quickSpring = Animation.spring(response: 0.25, dampingFraction: 0.80)

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: — Shadows
    // ─────────────────────────────────────────────────────────────────────────

    public struct ShadowStyle {
        let color: Color
        let radius: CGFloat
        let x: CGFloat
        let y: CGFloat
    }

    public static let shadowCard = ShadowStyle(
        color: Color.black.opacity(0.35), radius: 12, x: 0, y: 6
    )
    public static let shadowBubble = ShadowStyle(
        color: Color.black.opacity(0.20), radius: 4, x: 0, y: 2
    )
    public static let shadowGlow = ShadowStyle(
        color: Color(hue: 0.70, saturation: 0.80, brightness: 0.90).opacity(0.45),
        radius: 16, x: 0, y: 0
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: — View Modifiers
// ─────────────────────────────────────────────────────────────────────────────

extension View {
    /// Apply a glowing indigo ring — used on focused input and hero cards.
    func glowRing(color: Color = SwiftChatTheme.accent, radius: CGFloat = 8, active: Bool = true) -> some View {
        self.shadow(color: active ? color.opacity(0.55) : .clear, radius: radius)
    }

    /// Glassmorphic card surface.
    func glassCard(cornerRadius: CGFloat = SwiftChatTheme.radiusMedium) -> some View {
        self
            .background(.ultraThinMaterial)
            .background(SwiftChatTheme.surface.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
            )
    }
}

