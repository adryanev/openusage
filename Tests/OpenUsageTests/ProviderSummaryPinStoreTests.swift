import XCTest
@testable import OpenUsage

@MainActor
final class ProviderSummaryPinStoreTests: XCTestCase {
    func testCombinedUsageVisibilityPersistsWithoutDiscardingPins() throws {
        let suite = "ProviderSummaryPinStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = "codex:summary.Today"

        let store = ProviderSummaryPinStore(defaults: defaults)
        XCTAssertTrue(store.isEnabled(id))
        store.setPinned(true, for: id)
        store.setEnabled(false, for: id)

        let reloaded = ProviderSummaryPinStore(defaults: defaults)
        XCTAssertFalse(reloaded.isEnabled(id))
        XCTAssertTrue(reloaded.isPinned(id))

        reloaded.reset()
        let reset = ProviderSummaryPinStore(defaults: defaults)
        XCTAssertTrue(reset.isEnabled(id))
        XCTAssertFalse(reset.isPinned(id))
    }
}
