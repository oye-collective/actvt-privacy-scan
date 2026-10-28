//
//  AgentSessionRegistry.swift
//  Actvt
//

import Foundation
#if canImport(os)
import os.log
#endif

/// Holds the set of registered `AgentSessionSource` providers and exposes
/// them as a flat list. Construction is the one place where provider order
/// is defined — listing/fan-out preserves that order so the UI is stable.
///
/// The registry is `Sendable` and has no mutable state after construction.
/// Adding a new provider at runtime is intentionally NOT supported — call
/// sites are static, the registry is built once at app launch.
public struct AgentSessionRegistry: Sendable {

    public let providers: [any AgentSessionSource]

    public init(providers: [any AgentSessionSource]) {
        self.providers = providers
    }

    /// Default registry. Providers slot in here as their sources are written;
    /// order defines listing/fan-out order in the UI.
    ///
    /// `extraClaudeRoots` are user-configured `projects` directories from
    /// Settings, for setups the automatic `~/.claude-*` discovery can't see
    /// (a `CLAUDE_CONFIG_DIR` pointed somewhere else entirely).
    public static func makeDefault(extraClaudeRoots: [URL] = []) -> AgentSessionRegistry {
        AgentSessionRegistry(providers: [
            ClaudeCodeSessionSource(extraRoots: extraClaudeRoots),
            CodexSessionSource(),
            PiSessionSource(),
        ])
    }

    /// Per-provider availability check. Used by the store to skip
    /// uninstalled agents quietly.
    public func availableProviders() async -> [any AgentSessionSource] {
        var available: [any AgentSessionSource] = []
        for provider in providers where await provider.isAvailable {
            available.append(provider)
        }
        return available
    }

    /// Find a provider by kind. Returns the first match; provider kinds are
    /// expected to be unique within a registry.
    public func provider(for kind: AgentKind) -> (any AgentSessionSource)? {
        providers.first { $0.kind == kind }
    }
}
