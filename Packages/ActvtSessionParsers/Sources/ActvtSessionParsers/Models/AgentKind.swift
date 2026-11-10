//
//  AgentKind.swift
//  Actvt
//

import Foundation

/// Identifies which agent CLI produced a session.
///
/// New providers are added by adding a case here and registering an
/// `AgentSessionSource` conformer with `AgentSessionRegistry`.
public enum AgentKind: String, Codable, Sendable, Hashable, CaseIterable {
    case claudeCode
    case codexCLI
    case cursor
    case pi

    /// Human-readable name for UI surfaces.
    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codexCLI:   return "Codex CLI"
        case .cursor:     return "Cursor"
        case .pi:         return "Pi"
        }
    }

    /// Short name for the assistant's speaker label inside a transcript turn.
    public var assistantRoleLabel: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codexCLI:   return "Codex"
        case .cursor:     return "Cursor"
        case .pi:         return "Pi"
        }
    }

    /// SF Symbol used as the agent badge when no brand logo asset is available.
    public var iconSystemName: String {
        switch self {
        case .claudeCode: return "sparkles"
        case .codexCLI:   return "chevron.left.forwardslash.chevron.right"
        case .cursor:     return "cursorarrow.rays"
        case .pi:         return "function"
        }
    }

    /// Asset-catalog name of the agent's brand logo, when one exists. Rendered
    /// in place of `iconSystemName`; `nil` falls back to the SF Symbol.
    public var iconAssetName: String? {
        switch self {
        case .claudeCode: return "ClaudeLogo"
        case .codexCLI:   return "CodexLogo"
        case .cursor:     return nil
        case .pi:         return "PiLogo"
        }
    }

    /// Whether the logo asset carries its own brand colors (rendered as-is) or
    /// is a monochrome mark that should tint with the surrounding foreground.
    public var iconRendersInOriginalColor: Bool {
        switch self {
        case .claudeCode: return true   // full-color Claude mark
        case .codexCLI:   return true   // full-color Codex mark
        case .cursor:     return false
        case .pi:         return false   // monochrome mark from pi.dev/press-kit, tints as a template
        }
    }
}
