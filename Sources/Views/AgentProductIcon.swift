import SwiftUI

/// Product marks used wherever an agent is identified. This keeps the
/// comparison matrix legible without relying on ambiguous SF Symbols.
struct AgentProductIcon: View {
    let agent: Agent
    var size: CGFloat = 16

    private var assetName: String? {
        switch agent.id.split(separator: ":", maxSplits: 1).first {
        case "claude-code": "AgentClaude"
        case "codex": "AgentCodex"
        case "gemini-cli": "AgentGemini"
        case "opencode": "AgentOpenCode"
        default: nil
        }
    }

    var body: some View {
        Group {
            if let assetName {
                Image(assetName)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: agent.symbol)
                    .foregroundStyle(agent.color)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(agent.name)
    }
}
