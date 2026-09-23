import XCTest
@testable import OpenUsage

@MainActor
final class LayoutBootstrapTests: XCTestCase {
    func testFreshInstallUsesCurrentDefaults() {
        let (persistence, _) = makePersistence("Fresh")

        let state = LayoutBootstrap.load(
            registry: .mock,
            persistence: persistence,
            defaults: makeDefaultSet()
        )

        XCTAssertEqual(state.placed.map(\.descriptorID), ["claude.session", "claude.weekly"])
        XCTAssertEqual(state.pinnedMetricIDs, ["claude.session"])
        XCTAssertEqual(state.expandedMetricIDs, ["claude.weekly"])
        XCTAssertEqual(state.seededDefaultsToPersist, ["claude.session", "claude.weekly"])
        XCTAssertTrue(state.shouldPersistExpanded)
        XCTAssertTrue(state.shouldPersistExpandOnEnable)
        XCTAssertFalse(state.shouldPersistPlaced)
    }

    func testExistingLayoutUsesLegacyBaselineWithoutRestoringRemovedMetric() {
        let (persistence, _) = makePersistence("ExistingBaseline")
        persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])

        let state = LayoutBootstrap.load(
            registry: .mock,
            persistence: persistence,
            defaults: makeDefaultSet()
        )

        XCTAssertEqual(state.placed.map(\.descriptorID), ["claude.session"])
        XCTAssertFalse(state.expandedMetricIDs.contains("claude.weekly"))
        XCTAssertFalse(state.shouldPersistExpanded)
        XCTAssertTrue(state.shouldPersistExpandOnEnable)
        XCTAssertFalse(state.shouldPersistPlaced)
        XCTAssertEqual(state.seededDefaultsToPersist, ["claude.session", "claude.weekly"])
    }

    func testPreviouslySeededMetricStaysOffWhenUserDisabledIt() {
        let (persistence, _) = makePersistence("UserDisabled")
        persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])
        persistence.saveSeededDefaults(["claude.session", "claude.weekly"])

        let state = LayoutBootstrap.load(
            registry: .mock,
            persistence: persistence,
            defaults: makeDefaultSet()
        )

        XCTAssertEqual(state.placed.map(\.descriptorID), ["claude.session"])
        XCTAssertFalse(state.shouldPersistPlaced)
        XCTAssertNil(state.seededDefaultsToPersist)
    }

    func testLegacyClaudePinsFollowFirstDiscoveredAccountButSavedEmptyPinsStayEmpty() {
        let registry = WidgetRegistry.from([
            ClaudeProvider(provider: ClaudeProvider.makeProvider(id: "claude@first", displayName: "Claude: First")),
            ClaudeProvider(provider: ClaudeProvider.makeProvider(id: "claude@second", displayName: "Claude: Second"))
        ])
        let (persistence, _) = makePersistence("AccountPins")
        let defaults = LayoutDefaultSet(
            metricIDs: [], migrationBaselineMetricIDs: [],
            pinnedMetricIDs: ["claude.session", "claude.weekly"], expandedMetricIDs: []
        )

        let initial = LayoutBootstrap.load(registry: registry, persistence: persistence, defaults: defaults)
        XCTAssertEqual(initial.pinnedMetricIDs, ["claude@first.session", "claude@first.weekly"])

        persistence.savePins([])
        let userUnpinned = LayoutBootstrap.load(registry: registry, persistence: persistence, defaults: defaults)
        XCTAssertTrue(userUnpinned.pinnedMetricIDs.isEmpty)
    }

    func testDefaultAndSavedBasePinsFollowFirstEnabledAccount() {
        let registry = WidgetRegistry.from([
            ClaudeProvider(),
            ClaudeProvider(provider: ClaudeProvider.makeProvider(id: "claude@first", displayName: "Claude: First"))
        ])
        let (persistence, _) = makePersistence("DisabledBasePins")
        let defaults = LayoutDefaultSet(
            metricIDs: [], migrationBaselineMetricIDs: [],
            pinnedMetricIDs: ["claude.session"], expandedMetricIDs: []
        )
        let enabled: (String) -> Bool = { $0 != "claude" }

        let initial = LayoutBootstrap.load(
            registry: registry, persistence: persistence, defaults: defaults,
            isProviderEnabled: enabled
        )
        XCTAssertEqual(initial.pinnedMetricIDs, ["claude@first.session"])

        persistence.savePins(["claude.session"])
        let explicit = LayoutBootstrap.load(
            registry: registry, persistence: persistence, defaults: defaults,
            isProviderEnabled: enabled
        )
        XCTAssertEqual(explicit.pinnedMetricIDs, ["claude@first.session"])
    }

    private func makeDefaultSet() -> LayoutDefaultSet {
        LayoutDefaultSet(
            metricIDs: ["claude.session", "claude.weekly"],
            migrationBaselineMetricIDs: ["claude.session", "claude.weekly"],
            pinnedMetricIDs: ["claude.session"],
            expandedMetricIDs: ["claude.weekly"]
        )
    }

    private func makePersistence(_ name: String) -> (LayoutPersistence, UserDefaults) {
        let suite = "OpenUsageTests.LayoutBootstrap.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (LayoutPersistence(defaults: defaults, storageKey: "layout"), defaults)
    }
}
