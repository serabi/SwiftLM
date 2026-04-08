import Foundation

// ── Thinking State Tracker ────────────────────────────────────────────────────

/// Parses the raw token stream from a thinking-capable model and separates
/// <think>…</think> content from the final response content.
/// Matches llama-server's behaviour: thinking tokens → delta.reasoning_content,
/// response tokens → delta.content (content is nil while thinking).
struct ThinkingStateTracker {
    enum Phase { case thinking, responding }
    private(set) var phase: Phase = .responding
    private var buffer = ""  // accumulates chars looking for tag boundaries

    /// Feed the next text fragment. Returns (reasoningContent, responseContent)
    /// where either value may be empty but never both non-empty simultaneously.
    mutating func process(_ text: String) -> (reasoning: String, content: String) {
        buffer += text
        var reasoning = ""
        var content = ""

        while !buffer.isEmpty {
            switch phase {
            case .responding:
                let startRange = buffer.range(of: "<thinking>") ?? buffer.range(of: "<think>")
                if let range = startRange {
                    // Flush text before the tag as response content
                    content += String(buffer[buffer.startIndex..<range.lowerBound])
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    phase = .thinking
                } else if buffer.hasSuffix("<") || buffer.hasSuffix("<t") || buffer.hasSuffix("<th") ||
                          buffer.hasSuffix("<thi") || buffer.hasSuffix("<thin") || buffer.hasSuffix("<think") ||
                          buffer.hasSuffix("<thinki") || buffer.hasSuffix("<thinkin") || buffer.hasSuffix("<thinking") {
                    // Partial tag — hold in buffer until we know more
                    return (reasoning, content)
                } else {
                    content += buffer
                    buffer = ""
                }
            case .thinking:
                let endRange = buffer.range(of: "</thinking>") ?? buffer.range(of: "</think>")
                if let range = endRange {
                    // Flush reasoning before the closing tag
                    reasoning += String(buffer[buffer.startIndex..<range.lowerBound])
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    phase = .responding
                } else if isSuffixOfClosingTag(buffer) {
                    // Partial closing tag — hold in buffer
                    return (reasoning, content)
                } else {
                    reasoning += buffer
                    buffer = ""
                }
            }
        }
        return (reasoning, content)
    }

    private func isSuffixOfClosingTag(_ s: String) -> Bool {
        let tags = ["</think>", "</thinking>"]
        for tag in tags {
            for len in stride(from: min(s.count, tag.count), through: 1, by: -1) {
                let tagPrefix = String(tag.prefix(len))
                if s.hasSuffix(tagPrefix) { return true }
            }
        }
        return false
    }
}

/// Returns (thinkingContent, remainingContent) or (nil, original) if no block found.
func extractThinkingBlock(from text: String) -> (String?, String) {
    let startTag = text.range(of: "<thinking>") ?? text.range(of: "<think>")
    let endTag = text.range(of: "</thinking>") ?? text.range(of: "</think>")

    guard let startRange = startTag, let endRange = endTag else {
        // If there's an unclosed <think> or <thinking> block (still thinking when stopped)
        if let startRange = startTag {
            let thinking = String(text[startRange.upperBound...])
            return (thinking.isEmpty ? nil : thinking, "")
        }
        return (nil, text)
    }
    let thinking = String(text[startRange.upperBound..<endRange.lowerBound])
    let remaining = String(text[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    return (thinking.isEmpty ? nil : thinking, remaining)
}
