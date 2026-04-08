// ModelState+UI.swift -- SwiftUI presentation helpers for ModelState
import SwiftUI

extension ModelState {
    var canSend: Bool {
        if case .ready = self { return true }
        return false
    }

    var statusColor: Color {
        switch self {
        case .idle:                       return SwiftBuddyTheme.textTertiary
        case .loading, .downloading:      return SwiftBuddyTheme.warning
        case .ready:                      return SwiftBuddyTheme.success
        case .generating:                 return SwiftBuddyTheme.accent
        case .error:                      return SwiftBuddyTheme.error
        }
    }

    var shortLabel: String {
        switch self {
        case .idle:                        return "No model"
        case .loading:                     return "Loading..."
        case .downloading(let p, _):       return "\(Int(p * 100))% downloading"
        case .ready(let modelId):          return modelId.components(separatedBy: "/").last ?? modelId
        case .generating:                  return "Generating"
        case .error:                       return "Error"
        }
    }
}
