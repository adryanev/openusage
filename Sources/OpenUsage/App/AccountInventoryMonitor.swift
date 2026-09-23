import Foundation

@MainActor
final class AccountInventoryMonitor {
    private let accountsStore: ProviderAccountsStore
    private var current: ProviderAccountAssembly
    private let discover: @MainActor () async -> ProviderAccountAssembly
    var onChange: (() -> Void)?

    init(
        accountsStore: ProviderAccountsStore,
        current: ProviderAccountAssembly,
        discover: (@MainActor () async -> ProviderAccountAssembly)? = nil
    ) {
        self.accountsStore = accountsStore
        self.current = current
        self.discover = discover ?? {
            await ProviderAccountAssembly.make(
                accountsStore: accountsStore, waitsForLoginShell: true
            )
        }
    }

    func requestReload() {
        onChange?()
    }

    func detectChange() async {
        let observed = await discover()
        var previousClaude = current.claudeCards.sorted { $0.id < $1.id }
        var nextClaude = observed.claudeCards.sorted { $0.id < $1.id }
        var previousCodex = current.codexCards.sorted { $0.id < $1.id }
        var nextCodex = observed.codexCards.sorted { $0.id < $1.id }
        for index in previousClaude.indices { previousClaude[index].displayName = "" }
        for index in nextClaude.indices { nextClaude[index].displayName = "" }
        for index in previousCodex.indices { previousCodex[index].displayName = "" }
        for index in nextCodex.indices { nextCodex[index].displayName = "" }
        let needsReload = observed.identityKeysByCard != current.identityKeysByCard
            || previousClaude != nextClaude
            || previousCodex != nextCodex
        current = observed
        guard needsReload else { return }
        AppLog.info(.config, "account inventory changed; rebuilding provider cards")
        onChange?()
    }
}
