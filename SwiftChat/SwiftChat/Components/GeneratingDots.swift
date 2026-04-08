// GeneratingDots.swift -- Animated three-dot generating indicator
import SwiftUI

struct GeneratingDots: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle()
                    .frame(width: 5, height: 5)
                    .foregroundStyle(SwiftChatTheme.accent)
                    .scaleEffect(phase == i ? 1.5 : 0.8)
                    .opacity(phase == i ? 1.0 : 0.45)
                    .animation(
                        .easeInOut(duration: 0.45).repeatForever().delay(Double(i) * 0.18),
                        value: phase
                    )
            }
        }
        .onAppear { withAnimation { phase = 1 } }
    }
}
