import Foundation

struct CodexAccountCard: Equatable, Sendable {
    let id: String
    let identity: CodexAccountIdentity
    var displayName: String
    let authHomes: [String]
    let logHomes: [String]
    let allowsUnattributedHistory: Bool
}

extension ProviderAccountAssembly {
    static func makeCodexCards(
        observer: DefaultAccountObserver, accountsStore: ProviderAccountsStore
    ) async -> [CodexAccountCard] {
        let swaps = CodexSwapAccount.discover(
            environment: observer.environment, files: observer.files, home: observer.homeDirectory()
        )
        guard !swaps.isEmpty || accountsStore.selectedProfiles.contains(where: { $0.family == "codex" })
            || accountsStore.records.contains(where: {
            $0.family == "codex" && !$0.removedTombstone
        }) else {
            accountsStore.reconcile(with: [], scannedFamilies: ["codex"])
            return []
        }
        let home = observer.homeDirectory().path
        func expanded(_ path: String) -> String {
            path.hasPrefix("~/") ? home + String(path.dropFirst()) : path
        }
        let auth = CodexAuthStore(environment: observer.environment, files: observer.files,
                                  keychain: observer.keychain)
        let defaultPaths = auth.authPaths().map(expanded)
        let mainPaths = swaps.map { $0.mainHome + "/auth.json" }
        var observations: [ProviderAccountsStore.AccountObservation] = []
        var identities: [CodexAccountIdentity] = []
        var labels: [String: String] = [:]
        func observe(_ identity: CodexAccountIdentity, label: String, source: ProviderAccountSource) {
            accountsStore.upgradeCodexIdentity(identity)
            if let index = observations.firstIndex(where: { $0.identityKey == identity.key }) {
                if !observations[index].sources.contains(source) { observations[index].sources.append(source) }
            } else {
                identities.append(identity)
                observations.append(.init(family: "codex", identityKey: identity.key,
                                          label: identity.email, sources: [source]))
            }
            labels[identity.key] = label
        }
        var seenPaths = Set<String>()
        for path in defaultPaths + mainPaths where seenPaths.insert(path).inserted {
            guard let state = auth.loadAuth(at: path), state.hasUsableAccessToken,
                  let identity = CodexAccountIdentity(auth: state.auth) else { continue }
            let workspace = identity.accountID.isEmpty ? "Unknown" : String(identity.accountID.prefix(8))
            observe(identity, label: "Codex: Workspace \(workspace) (\(identity.email ?? identity.accountID))",
                    source: .init(kind: .defaultHome, anchor: URL(fileURLWithPath: path).deletingLastPathComponent().path,
                                  holdsDefaultSource: observations.isEmpty))
        }
        // Keychain can hold a different default login with no auth.json or saved Swap slot.
        // Discover it before saved slots so it retains the default card on a first launch.
        if let state = await loadOffMainActor({ auth.loadKeychainAuth() }), state.hasUsableAccessToken,
           let identity = CodexAccountIdentity(auth: state.auth) {
            let workspace = identity.accountID.isEmpty ? "Unknown" : String(identity.accountID.prefix(8))
            observe(identity, label: "Codex: Workspace \(workspace) (\(identity.email ?? identity.accountID))",
                    source: .init(kind: .defaultHome, anchor: nil, holdsDefaultSource: observations.isEmpty))
        }
        let selectedDiscovery = SelectedAccountProfileDiscovery(
            environment: observer.environment, files: observer.files,
            keychain: observer.keychain, homeDirectory: observer.homeDirectory
        )
        for profile in accountsStore.selectedProfiles where profile.family == "codex" {
            do {
                let finding = try selectedDiscovery.find(family: "codex", path: profile.path)
                guard let identity = finding.codexIdentity else { continue }
                let workspace = String(identity.accountID.prefix(8))
                observe(identity, label: "Codex: Workspace \(workspace) (\(identity.email ?? identity.accountID))",
                        source: .init(kind: .selectedHome, anchor: finding.profile.path,
                                      holdsDefaultSource: false))
            } catch {
                AppLog.warn(.config, "selected Codex profile unavailable: \(error.localizedDescription)")
            }
        }
        for swap in swaps {
            observe(swap.identity, label: swap.displayName,
                    source: .init(kind: .codexSwap, anchor: swap.home, holdsDefaultSource: false))
        }
        let records = accountsStore.reconcile(with: observations, scannedFamilies: ["codex"])
        let allowsUnattributed = records.count { $0.family == "codex" && !$0.removedTombstone } == 1
        let logHomes = Array(Set(swaps.flatMap { [$0.mainHome, $0.home] }
            + accountsStore.selectedProfiles.filter { $0.family == "codex" }.map(\.path))).sorted()
        // Registry order is persistent; observation order follows the current default login.
        // Even an uncustomized layout must keep its cards in place after a switch and relaunch.
        return records.compactMap { record in
            guard record.family == "codex", !record.removedTombstone else { return nil }
            let components = record.identityKey.split(separator: "|", omittingEmptySubsequences: false)
            guard let identity = identities.first(where: { $0.key == record.identityKey })
                ?? CodexAccountIdentity(
                    accountID: components.first.map(String.init),
                    email: components.count > 1 ? String(components[1]) : nil
                ) else { return nil }
            let observed = observations.contains { $0.identityKey == identity.key }
            let matching = swaps.filter { $0.identity == identity }
            let observedHomes = observations.first { $0.identityKey == identity.key }?.sources.compactMap(\.anchor) ?? []
            return CodexAccountCard(id: record.id, identity: identity,
                displayName: record.alias.map { "Codex: \($0)" }
                    ?? labels[identity.key] ?? "Codex: \(record.label ?? "Account")",
                authHomes: Array(Set(observedHomes + matching.flatMap { [$0.mainHome, $0.home] })).sorted(),
                logHomes: logHomes, allowsUnattributedHistory: allowsUnattributed && observed)
        }
    }
}
