import XCTest
@testable import OpenUsage

final class ProviderAccountSummaryTests: XCTestCase {
    func testCountsQuotaAvailabilityAndAddsOnlyCompatibleValues() throws {
        let snapshots = [
            "claude": snapshot("claude", session: 40, weekly: 100, today: 2, tokens: 100),
            "claude@second": snapshot("claude@second", session: 100, weekly: 20, today: 3, tokens: 200),
        ]
        let result = try XCTUnwrap(ProviderAccountSummary.make(
            family: "claude", accountIDs: ["claude", "claude@second"], snapshots: snapshots
        ))
        XCTAssertEqual(values(result.line(label: "Session Available"))?.first?.number, 1)
        XCTAssertEqual(values(result.line(label: "Weekly Available"))?.first?.number, 1)
        XCTAssertEqual(values(result.line(label: "Today"))?.map(\.number), [5, 300])
        XCTAssertNil(result.warning)
    }

    func testMissingOrFailedAccountMarksPartialResult() throws {
        let result = try XCTUnwrap(ProviderAccountSummary.make(
            family: "claude", accountIDs: ["claude", "claude@second"],
            snapshots: ["claude": snapshot("claude", session: 40, weekly: 50, today: 2, tokens: 100)],
            errors: ["claude@second": "Login expired"]
        ))
        XCTAssertNotNil(result.warning)
        XCTAssertEqual(values(result.line(label: "Today"))?.first?.number, 2)
    }

    func testAddsComparableDollarPoolsWithoutCombiningResetTimes() throws {
        var first = snapshot("claude", session: 20, weekly: 30, today: 1, tokens: 10)
        var second = snapshot("claude@second", session: 40, weekly: 50, today: 2, tokens: 20)
        first.lines.append(.progress(label: "Extra Usage", used: 2, limit: 10, format: .dollars,
                                     resetsAt: Date(timeIntervalSince1970: 100), periodDurationMs: 2_592_000_000))
        second.lines.append(.progress(label: "Extra Usage", used: 3, limit: 20, format: .dollars,
                                      resetsAt: Date(timeIntervalSince1970: 200), periodDurationMs: 2_592_000_000))
        let summary = try XCTUnwrap(ProviderAccountSummary.make(
            family: "claude", accountIDs: [first.providerID, second.providerID],
            snapshots: [first.providerID: first, second.providerID: second]
        ))
        guard case .progress(_, let used, let limit, _, let reset, _, _)? = summary.line(label: "Extra Usage")
        else { return XCTFail("Missing comparable dollar total") }
        XCTAssertEqual(used, 5)
        XCTAssertEqual(limit, 30)
        XCTAssertNil(reset)
    }

    func testCodexSummaryShowsCombinedUnattributedSpendOnlyOnce() throws {
        let first = snapshot("codex", session: 20, weekly: 30, today: 2, tokens: 10)
        let second = snapshot("codex@second", session: 40, weekly: 50, today: 3, tokens: 20)
        let shared: [MetricLine] = [
            .values(label: "Today", values: [MetricValue(number: 4, kind: .dollars)]),
            .values(label: "Last 30 Days", values: [MetricValue(number: 12, kind: .dollars)]),
        ]
        let summary = try XCTUnwrap(ProviderAccountSummary.make(
            family: "codex", accountIDs: [first.providerID, second.providerID],
            snapshots: [first.providerID: first, second.providerID: second],
            sharedSpendLines: shared
        ))
        XCTAssertEqual(values(summary.line(label: "Today"))?.first?.number, 4)
        XCTAssertEqual(values(summary.line(label: "Last 30 Days"))?.first?.number, 12)
        XCTAssertTrue(summary.warning?.contains("combined") == true)
    }

    func testCodexCombinedHistoryStaysVisibleWithOneEnabledAccount() throws {
        let account = ProviderSnapshot(providerID: "codex", displayName: "Codex", lines: [
            .progress(label: "Weekly", used: 30, limit: 100, format: .percent)
        ])
        let shared: [MetricLine] = [
            .values(label: "Today", values: [MetricValue(number: 4, kind: .dollars)]),
        ]
        let summary = try XCTUnwrap(ProviderAccountSummary.make(
            family: "codex", accountIDs: [account.providerID],
            snapshots: [account.providerID: account], sharedSpendLines: shared
        ))
        XCTAssertEqual(values(summary.line(label: "Today"))?.first?.number, 4)
        XCTAssertNil(ProviderAccountSummary.make(
            family: "codex", accountIDs: [account.providerID], snapshots: [account.providerID: account]
        ))
    }

    private func values(_ line: MetricLine?) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _)? = line else { return nil }
        return values
    }

    private func snapshot(_ id: String, session: Double, weekly: Double,
                          today: Double, tokens: Double) -> ProviderSnapshot {
        let spending = [MetricValue(number: today, kind: .dollars),
                        MetricValue(number: tokens, kind: .count, label: "tokens")]
        return ProviderSnapshot(providerID: id, displayName: id, lines: [
            .progress(label: "Session", used: session, limit: 100, format: .percent),
            .progress(label: "Weekly", used: weekly, limit: 100, format: .percent),
            .values(label: "Today", values: spending),
            .values(label: "Last 30 Days", values: spending),
        ])
    }
}
