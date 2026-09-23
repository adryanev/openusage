import Foundation

@MainActor
final class AccountInventoryMonitor {
    private let accountsStore: ProviderAccountsStore
    private var current: ProviderAccountAssembly
    var onChange: (() -> Void)?

    init(accountsStore: ProviderAccountsStore, current: ProviderAccountAssembly) {
        self.accountsStore = accountsStore
        self.current = current
    }

    func requestReload() {
        onChange?()
    }

    func detectChange() async {
        let observed = await ProviderAccountAssembly.make(
            accountsStore: accountsStore, waitsForLoginShell: true
        )
        guard observed.identityKeysByCard != current.identityKeysByCard
            || observed.claudeCards != current.claudeCards
            || observed.codexCards != current.codexCards
        else { return }
        current = observed
        AppLog.info(.config, "account inventory changed; rebuilding provider cards")
        onChange?()
    }
}
