// BouncingDot.swift -- Single bouncing dot for typing indicator
import SwiftUI

struct BouncingDot: View {
    let index: Int
    @State private var bouncing = false

    var body: some View {
        Circle()
            .frame(width: 7, height: 7)
            .foregroundStyle(SwiftBuddyTheme.textSecondary)
            .offset(y: bouncing ? -5 : 0)
            .animation(
                .easeInOut(duration: 0.45)
                    .repeatForever(autoreverses: true)
                    .delay(Double(index) * 0.14),
                value: bouncing
            )
            .onAppear { bouncing = true }
    }
}
