import XCTest
@testable import OpenUsage

@MainActor
final class AccountInventoryMonitorTests: XCTestCase {
    func testAliasOnlyChangeKeepsTheOpenPanelController() async {
        let identity = CodexAccountIdentity(accountID: "workspace-1", email: "user@example.test")!
        func assembly(name: String, authHomes: [String] = ["/tmp/codex"]) -> ProviderAccountAssembly {
            ProviderAccountAssembly(
                identityKeysByCard: ["codex": identity.key],
                claudeCards: [],
                codexCards: [CodexAccountCard(
                    id: "codex", identity: identity, displayName: name,
                    authHomes: authHomes, logHomes: [], allowsUnattributedHistory: false
                )]
            )
        }

        let defaults = UserDefaults(suiteName: "OpenUsageTests.AccountInventory.\(UUID().uuidString)")!
        let store = ProviderAccountsStore(defaults: defaults)
        let monitor = AccountInventoryMonitor(
            accountsStore: store, current: assembly(name: "Codex: Old"),
            discover: { assembly(name: "Codex: New") }
        )
        var reloads = 0
        monitor.onChange = { reloads += 1 }

        await monitor.detectChange()

        XCTAssertEqual(reloads, 0, "changing an alias must not tear down the open status panel")
    }

    func testReorderingCardsKeepsTheOpenPanelController() async {
        let first = CodexAccountIdentity(accountID: "workspace-1", email: "first@example.test")!
        let second = CodexAccountIdentity(accountID: "workspace-2", email: "second@example.test")!
        func card(_ id: String, _ identity: CodexAccountIdentity) -> CodexAccountCard {
            CodexAccountCard(id: id, identity: identity, displayName: id,
                             authHomes: ["/tmp/\(id)"], logHomes: [], allowsUnattributedHistory: false)
        }
        let cards = [card("codex", first), card("codex@second", second)]
        let keys = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0.identity.key) })
        let defaults = UserDefaults(suiteName: "OpenUsageTests.AccountInventory.\(UUID().uuidString)")!
        let store = ProviderAccountsStore(defaults: defaults)
        let monitor = AccountInventoryMonitor(
            accountsStore: store,
            current: ProviderAccountAssembly(identityKeysByCard: keys, claudeCards: [], codexCards: cards),
            discover: { ProviderAccountAssembly(identityKeysByCard: keys, claudeCards: [],
                                                 codexCards: Array(cards.reversed())) }
        )
        var reloads = 0
        monitor.onChange = { reloads += 1 }

        await monitor.detectChange()

        XCTAssertEqual(reloads, 0)
    }

    func testAuthSourceChangeStillReloadsAccountCards() async {
        let identity = CodexAccountIdentity(accountID: "workspace-1", email: "user@example.test")!
        func assembly(home: String) -> ProviderAccountAssembly {
            ProviderAccountAssembly(
                identityKeysByCard: ["codex": identity.key],
                claudeCards: [],
                codexCards: [CodexAccountCard(
                    id: "codex", identity: identity, displayName: "Codex",
                    authHomes: [home], logHomes: [], allowsUnattributedHistory: false
                )]
            )
        }

        let defaults = UserDefaults(suiteName: "OpenUsageTests.AccountInventory.\(UUID().uuidString)")!
        let store = ProviderAccountsStore(defaults: defaults)
        let monitor = AccountInventoryMonitor(
            accountsStore: store, current: assembly(home: "/tmp/old"),
            discover: { assembly(home: "/tmp/new") }
        )
        var reloads = 0
        monitor.onChange = { reloads += 1 }

        await monitor.detectChange()

        XCTAssertEqual(reloads, 1)
    }
}
