// BlinkingCursor.swift -- Inline blinking cursor for streaming text
import SwiftUI

struct BlinkingCursor: View {
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .frame(width: 2.5, height: 17)
            .foregroundStyle(SwiftBuddyTheme.accent)
            .opacity(visible ? 1 : 0)
            .animation(
                .easeInOut(duration: 0.52).repeatForever(autoreverses: true),
                value: visible
            )
            .onAppear { visible = false }
            .padding(.leading, 1)
            .padding(.bottom, 1)
    }
}
