import XCTest
@testable import OpenUsage

@MainActor
final class ProviderAccountsStoreTests: XCTestCase {
    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.ProviderAccounts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func defaultHomeObservation(
        family: String,
        identityKey: String,
        label: String? = nil,
        anchor: String = "/Users/dev/.claude"
    ) -> ProviderAccountsStore.AccountObservation {
        ProviderAccountsStore.AccountObservation(
            family: family,
            identityKey: identityKey,
            label: label,
            sources: [ProviderAccountSource(kind: .defaultHome, anchor: anchor, holdsDefaultSource: true)]
        )
    }

    func testFirstAccountOfAFamilyGetsTheBareID() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())

        let records = store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "a@example.com"),
        ])

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].id, "claude", "the migration-killing rule: the first account IS the existing card")
        XCTAssertEqual(records[0].identityKey, "acct-a")
        XCTAssertEqual(records[0].label, "a@example.com")
        XCTAssertTrue(records[0].sources.contains(where: \.holdsDefaultSource))
    }

    func testSwappedDefaultMintsAHashIDAndTakesTheBadge() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a")])

        let records = store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-b")])

        XCTAssertEqual(records.count, 2, "the swapped-out account's record survives")
        let old = records.first { $0.identityKey == "acct-a" }
        let new = records.first { $0.identityKey == "acct-b" }
        XCTAssertEqual(old?.id, "claude", "the original keeps its minted id")
        XCTAssertEqual(new?.id, ProviderAccountID.make(family: "claude", identityKey: "acct-b"))
        XCTAssertEqual(store.defaultBadgeHolder(family: "claude")?.identityKey, "acct-b")
        XCTAssertEqual(old?.sources.contains(where: \.holdsDefaultSource), false, "the badge is exclusive per family")
    }

    func testUnobservedFamilyIsLeftUntouched() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        store.reconcile(with: [defaultHomeObservation(family: "codex", identityKey: "acct-c")])

        // A launch that could not observe codex (logged out, unreadable identity) reports nothing.
        let records = store.reconcile(with: [])

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(store.defaultBadgeHolder(family: "codex")?.identityKey, "acct-c")
    }

    func testReconcileUpdatesLabelButKeepsItWhenObservationHasNone() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "a@example.com")])

        var records = store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a")])
        XCTAssertEqual(records[0].label, "a@example.com", "a label-less observation must not erase the known label")

        records = store.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "a@new.example.com"),
        ])
        XCTAssertEqual(records[0].label, "a@new.example.com")
    }

    func testTombstonedRecordIsNeverResurrected() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "old")])
        // Simulate a future "Remove Account…" by tombstoning the persisted record directly.
        var records = store.records
        records[0].removedTombstone = true
        defaults.set(try! JSONEncoder().encode(records), forKey: ProviderAccountsStore.storageKey)

        let reloaded = ProviderAccountsStore(defaults: defaults)
        let after = reloaded.reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "new"),
        ])

        XCTAssertEqual(after.count, 1)
        XCTAssertEqual(after[0].label, "old", "a tombstoned account ignores rescan observations")
        XCTAssertNil(reloaded.defaultBadgeHolder(family: "claude"), "a tombstoned record never answers the badge")
    }

    func testRecordsPersistAcrossInstances() {
        let defaults = makeScratchDefaults()
        ProviderAccountsStore(defaults: defaults).reconcile(with: [
            defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "a@example.com"),
            defaultHomeObservation(family: "codex", identityKey: "acct-c", anchor: "/Users/dev/.codex"),
        ])

        let reloaded = ProviderAccountsStore(defaults: defaults)

        XCTAssertEqual(reloaded.records.count, 2)
        XCTAssertEqual(reloaded.defaultBadgeHolder(family: "claude")?.label, "a@example.com")
        XCTAssertEqual(reloaded.defaultBadgeHolder(family: "codex")?.sources.first?.anchor, "/Users/dev/.codex")
    }

    func testUndecodableRegistryStartsFresh() {
        let defaults = makeScratchDefaults()
        defaults.set(Data("not json".utf8), forKey: ProviderAccountsStore.storageKey)

        XCTAssertTrue(ProviderAccountsStore(defaults: defaults).records.isEmpty)
    }

    func testFamilyHelperSplitsCardIDs() {
        XCTAssertEqual(ProviderAccountID.family(of: "claude"), "claude")
        XCTAssertEqual(ProviderAccountID.family(of: "claude@ab12cd34"), "claude")
    }

    func testSelectedProfilesAndAliasPersistWithoutChangingAccountIdentity() {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        store.reconcile(with: [defaultHomeObservation(family: "claude", identityKey: "acct-a", label: "a@example.com")])
        let profile = SelectedAccountProfile(family: "claude", path: "/Users/dev/.claude-work",
                                             keychainLiteral: "~/.claude-work")

        XCTAssertTrue(store.addSelectedProfile(profile))
        XCTAssertFalse(store.addSelectedProfile(profile))
        store.setAlias("Work", for: "claude")

        let reloaded = ProviderAccountsStore(defaults: defaults)
        XCTAssertEqual(reloaded.selectedProfiles, [profile])
        XCTAssertEqual(reloaded.records.first?.alias, "Work")
        XCTAssertEqual(reloaded.records.first?.identityKey, "acct-a")
    }

    func testRemovingOneSelectedSourcePreservesOtherSourcesAndAccount() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        let profile = SelectedAccountProfile(family: "claude", path: "/Users/dev/.claude-work",
                                             keychainLiteral: nil)
        store.addSelectedProfile(profile)
        store.reconcile(with: [ProviderAccountsStore.AccountObservation(
            family: "claude", identityKey: "acct-a", label: nil,
            sources: [
                ProviderAccountSource(kind: .defaultHome, anchor: "/Users/dev/.claude", holdsDefaultSource: true),
                ProviderAccountSource(kind: .selectedHome, anchor: profile.path, holdsDefaultSource: false),
            ]
        )])

        store.removeSelectedProfile(family: "claude", path: profile.path)

        XCTAssertTrue(store.selectedProfiles.isEmpty)
        XCTAssertEqual(store.records[0].sources.map(\.kind), [.defaultHome])
        XCTAssertFalse(store.records[0].removedTombstone)
    }

    func testRemovedAccountStaysTombstonedUntilExplicitAddAgain() {
        let store = ProviderAccountsStore(defaults: makeScratchDefaults())
        store.reconcile(with: [defaultHomeObservation(family: "codex", identityKey: "acct-a")])
        store.removeAccount(id: "codex")
        store.reconcile(with: [defaultHomeObservation(family: "codex", identityKey: "acct-a", label: "new")])

        XCTAssertTrue(store.records[0].removedTombstone)
        XCTAssertNil(store.records[0].label)
        store.addAgain(id: "codex")
        XCTAssertFalse(store.records[0].removedTombstone)
    }
}
