import XCTest
@testable import OpenUsage

/// The launch account pass end to end: observer outcomes → account registry records → the per-card
/// identity map consumed by the snapshot cache stamp and the bare-id resolver.
@MainActor
final class ProviderAccountAssemblyTests: XCTestCase {
    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "OpenUsageTests.ProviderAccountAssembly.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testResolvedFamiliesFeedIdentityKeysAndTheRegistry() async throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                // Claude resolved at the default home; Codex has credentials that name no account.
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1", "emailAddress": "dev@example.com"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens": {"access_token": "at-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = await ProviderAccountAssembly.make(observer: observer, accountsStore: store)

        XCTAssertEqual(assembly.identityKeysByCard, ["claude": "acct-1"])
        // The registry recorded the resolved account under the bare id, holding the default badge.
        let record = try XCTUnwrap(store.defaultBadgeHolder(family: "claude"))
        XCTAssertEqual(record.id, "claude")
        XCTAssertEqual(record.label, "dev@example.com")
        XCTAssertEqual(record.sources.map(\.kind), [.defaultHome])
        // An unresolved family claims no account: no record, no identity key.
        XCTAssertNil(store.defaultBadgeHolder(family: "codex"))
    }

    /// A family whose home facts aren't readable this launch (first Finder/Dock launch racing a
    /// slow shell) is left out of the pass entirely: not observed, not reconciled — while a family
    /// whose home override is already in the process environment still resolves.
    func testFamiliesOutsideThePassAreNeitherObservedNorReconciled() async {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                "/Users/dev/.claude.json": #"{"oauthAccount": {"accountUuid": "ACCT-1"}}"#,
                "/Users/dev/.codex/auth.json": #"{"tokens": {"access_token": "at-1", "account_id": "CODEX-1"}}"#,
            ]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = await ProviderAccountAssembly.make(observer: observer, accountsStore: store, families: ["codex"])

        XCTAssertEqual(assembly.identityKeysByCard, ["codex": "codex-1"])
        XCTAssertNil(store.defaultBadgeHolder(family: "claude"), "an out-of-pass family must not be reconciled")
    }

    func testCodexHomeOverrideStillFindsSavedStandardHomeAccount() async throws {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let personal = try XCTUnwrap(CodexAccountIdentity(accountID: "personal-workspace", email: "personal@example.com"))
        let lexicon = try XCTUnwrap(CodexAccountIdentity(accountID: "lexicon-workspace", email: "lexicon@example.com"))
        store.reconcile(with: [
            .init(family: "codex", identityKey: personal.key, label: personal.email, sources: []),
            .init(family: "codex", identityKey: lexicon.key, label: lexicon.email, sources: [])
        ])
        func credential(accountID: String, email: String) -> String {
            let payload = Data(#"{"email":"\#(email)"}"#.utf8).base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
            let idToken = "header.\(payload).signature"
            return #"{"tokens":{"access_token":"access","id_token":"\#(idToken)","account_id":"\#(accountID)"}}"#
        }
        let environment = FakeEnvironment(["CODEX_HOME": "/Users/dev/.codex-lexicon"])
        let files = FakeFiles([
            "/Users/dev/.codex-lexicon/auth.json":
                credential(accountID: lexicon.accountID, email: "lexicon@example.com"),
            "/Users/dev/.codex/auth.json":
                credential(accountID: personal.accountID, email: "personal@example.com")
        ])
        let observer = DefaultAccountObserver(
            environment: environment, files: files, keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = await ProviderAccountAssembly.make(
            observer: observer, accountsStore: store, families: ["codex"]
        )

        XCTAssertEqual(assembly.codexCards.count, 2)
        let personalCard = try XCTUnwrap(assembly.codexCards.first { $0.identity == personal })
        XCTAssertTrue(personalCard.authHomes.contains("/Users/dev/.codex"))
        let personalRecord = try XCTUnwrap(store.records.first { $0.identityKey == personal.key })
        XCTAssertEqual(personalRecord.sources.compactMap(\.anchor), ["/Users/dev/.codex"])
        let personalAuth = CodexAuthStore(
            environment: environment, files: files, keychain: FakeKeychain(nil),
            expectedIdentity: personalCard.identity, additionalAuthHomes: personalCard.authHomes
        )
        XCTAssertEqual(personalAuth.loadAuthCandidates().count, 1)
    }

    func testNothingObservedLeavesRegistryAndKeysEmpty() async {
        let defaults = makeScratchDefaults()
        let store = ProviderAccountsStore(defaults: defaults)
        let observer = DefaultAccountObserver(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: FakeKeychain(nil),
            homeDirectory: { URL(fileURLWithPath: "/Users/dev") }
        )

        let assembly = await ProviderAccountAssembly.make(observer: observer, accountsStore: store)

        XCTAssertTrue(assembly.identityKeysByCard.isEmpty)
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(defaults.data(forKey: ProviderAccountsStore.storageKey), "no observations, no write")
    }
}
